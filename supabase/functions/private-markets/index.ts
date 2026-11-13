import { AI_LIMITS } from "../_shared/ai/proxy.ts";
import { authenticatedUserId, errorResponse, jsonResponse, readJson, serviceClient } from "../_shared/secure/edge.ts";
import { open, parseKeyring, seal, type SealedSecret } from "../_shared/secure/envelope.ts";
import { buildResearch, type Evidence, ResearchError } from "../_shared/private-markets/research.ts";

const uuid = /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i;
const publicDealFields = "id,provider,category,status,minimum,eligibility,jurisdictions,source_url,offer_document_url,verified_at," +
  "round:funding_rounds!inner(id,stage,raised,target,valuation,valuation_method,currency,closes_at,source_url,verified_at,traction," +
  "company:private_companies!inner(id,name,sector,country,location,description,logo_url,founders,investors,source_url,verified_at)," +
  "share_classes(name,rights,source_url))";

type CatalogDeal = {
  source_url: string;
  provider: string;
  category: string;
  status: string;
  minimum: number | null;
  eligibility: string;
  jurisdictions: string[];
  round: {
    stage: string;
    raised: number | null;
    target: number | null;
    valuation: number | null;
    valuation_method: string | null;
    currency: string;
    traction: string | null;
    company: { name: string; description: string | null; country: string; sector: string };
    share_classes: { name: string; rights: string }[];
  };
};

function dealEvidence(deal: CatalogDeal): string {
  const { round } = deal;
  const { company, currency } = round;
  const money = (label: string, value: number | null) => value === null ? undefined : `${label}: ${currency} ${value}`;
  return [
    `Company: ${company.name}`,
    `Sector: ${company.sector}; country: ${company.country}`,
    `Round: ${round.stage}; status: ${deal.status}`,
    `Provider: ${deal.provider}; category: ${deal.category}`,
    money("Minimum", deal.minimum), money("Raised", round.raised), money("Target", round.target),
    money("Valuation", round.valuation),
    round.valuation_method && `Valuation method: ${round.valuation_method}`,
    `Eligibility: ${deal.eligibility}; jurisdictions: ${deal.jurisdictions.join(", ")}`,
    company.description, round.traction,
    ...round.share_classes.map((item) => `${item.name}: ${item.rights}`),
  ].filter(Boolean).join("\n").slice(0, 2_800);
}

const context = (kind: string, userId: string, id: string) => `private_${kind}:${userId}:${id}`;
const keys = () => parseKeyring(Deno.env.get("CREDENTIAL_KEKS"), Deno.env.get("CREDENTIAL_ACTIVE_KEK"));
const fail = (status: number, code: string, message: string) => { throw new ResearchError(status, code, message); };

Deno.serve(async (req) => {
  if (req.method !== "POST") return errorResponse(405, "METHOD_NOT_ALLOWED", "Use POST.");
  try {
    const admin = serviceClient();
    // The existing Auth service validates the session. Every service-role owner read
    // and write below derives the user ID from that session.
    let body: Record<string, unknown>;
    try {
      const raw = await readJson(req, 24_000);
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error();
      body = raw as Record<string, unknown>;
    } catch {
      return errorResponse(400, "INVALID_REQUEST", "Send a JSON object under 24 KB.");
    }

    if (body.action === "catalog") {
      const { data, error } = await admin.from("investment_opportunities").select(publicDealFields)
        .eq("published", true).eq("round.published", true).eq("round.company.published", true)
        .eq("round.share_classes.published", true).order("verified_at", { ascending: false }).order("id").range(0, 499);
      if (error) throw error;
      return jsonResponse(200, { deals: data });
    }
    const userId = await authenticatedUserId(req, admin);
    if (!userId) return errorResponse(401, "UNAUTHENTICATED", "Sign in first.");

    const audit = async (action: string, subject?: string) => {
      const { error } = await admin.from("investment_audit_logs").insert({ user_id: userId, action, subject_id: subject });
      if (error) throw error;
    };
    switch (body.action) {
      case "updates": {
        const ids = body.company_ids;
        if (!Array.isArray(ids) || ids.length > 100 || ids.some((id) => typeof id !== "string" || !uuid.test(id))) {
          return errorResponse(400, "INVALID_REQUEST", "Send up to 100 watched company IDs.");
        }
        if (!ids.length) return jsonResponse(200, { updates: [] });
        const { data, error } = await admin.from("corporate_actions")
          .select("id,title,significance,source_url,published_at,company:private_companies!inner(name)")
          .eq("published", true).eq("company.published", true).lte("published_at", new Date().toISOString())
          .in("company_id", ids).order("published_at", { ascending: false }).limit(100);
        if (error) throw error;
        return jsonResponse(200, { updates: data });
      }
      case "profile": {
        const { data, error } = await admin.from("investor_profiles").select("country,declared_class").eq("user_id", userId).maybeSingle();
        if (error) throw error;
        return jsonResponse(200, { profile: data });
      }
      case "save_profile": {
        if (typeof body.country !== "string" || !/^[A-Z]{2}$/.test(body.country) ||
          typeof body.declared_class !== "string" || !["unknown", "retail", "wholesale"].includes(body.declared_class)) {
          return errorResponse(400, "INVALID_PROFILE", "Enter a two-letter country code and select a classification.");
        }
        const { error } = await admin.from("investor_profiles").upsert({
          user_id: userId, country: body.country, declared_class: body.declared_class,
        });
        if (error) throw error;
        return jsonResponse(200, {});
      }
      case "confirmed_holdings": {
        const { data, error } = await admin.from("private_holdings")
          .select("id,name,asset_class,currency,units,settled_amount,confirmed_at,commitment:investment_commitments!inner(provider,provider_reference,status)")
          .eq("user_id", userId).eq("commitment.status", "confirmed").not("confirmed_at", "is", null)
          .order("confirmed_at", { ascending: false }).limit(100);
        if (error) throw error;
        return jsonResponse(200, { holdings: data });
      }
      case "applications": {
        const { data, error } = await admin.from("investment_commitments")
          .select("id,status,requested_amount,currency,provider,provider_reference,confirmed_at,cooling_off_ends_at,acknowledged_at")
          .eq("user_id", userId).order("acknowledged_at", { ascending: false }).limit(100);
        if (error) throw error;
        return jsonResponse(200, { applications: data });
      }
      case "handoff": {
        if (typeof body.opportunity_id !== "string" || !uuid.test(body.opportunity_id) ||
          typeof body.amount !== "string" || !/^\d{1,16}(?:\.\d{1,4})?$/.test(body.amount) ||
          typeof body.document_url !== "string" || body.acknowledged !== true) {
          return errorResponse(400, "INVALID_REQUEST", "Review the offer document and acknowledge the risks first.");
        }
        const { data, error } = await admin.rpc("prepare_private_handoff", {
          p_user: userId, p_opportunity: body.opportunity_id, p_amount: body.amount, p_document_url: body.document_url,
        }).single();
        if (error) {
          const status = { "42501": 403, "22023": 422, "23505": 409 }[error.code];
          if (status) return errorResponse(status, "HANDOFF_UNAVAILABLE", error.message);
          throw error;
        }
        return jsonResponse(200, data);
      }
      case "save_document": {
        const { title, excerpt } = body;
        if (typeof title !== "string" || !title.trim() || title.length > 160 ||
          typeof excerpt !== "string" || excerpt.trim().length < 40 || excerpt.length > 4_500 ||
          body.authorized !== true) {
          return errorResponse(400, "INVALID_DOCUMENT", "Provide a title and a permitted text excerpt of 40–4,500 characters.");
        }
        const id = crypto.randomUUID();
        const encrypted = await seal(await keys(), excerpt.trim(), context("document", userId, id));
        const { error } = await admin.from("deal_documents").insert({ id, title: title.trim(), user_id: userId, sealed: encrypted });
        if (error) throw error;
        await audit("document_saved", id);
        return jsonResponse(201, { id, title: title.trim() });
      }
      case "document": {
        if (typeof body.id !== "string" || !uuid.test(body.id)) return errorResponse(400, "INVALID_REQUEST", "Invalid document.");
        const { data, error } = await admin.from("deal_documents").select("sealed")
          .eq("user_id", userId).eq("id", body.id).maybeSingle();
        if (error) throw error;
        if (!data) return errorResponse(404, "NOT_FOUND", "Excerpt unavailable.");
        const excerpt = await open(await keys(), data.sealed as SealedSecret, context("document", userId, body.id));
        return jsonResponse(200, { excerpt });
      }
      case "documents":
      case "reports": {
        const table = body.action === "documents" ? "deal_documents" : "research_reports";
        const { data, error } = await admin.from(table).select("id,title,created_at")
          .eq("user_id", userId).order("created_at", { ascending: false }).limit(100);
        if (error) throw error;
        return jsonResponse(200, { items: data });
      }
      case "delete_document":
      case "delete_report": {
        if (typeof body.id !== "string" || !uuid.test(body.id)) return errorResponse(400, "INVALID_REQUEST", "Invalid item.");
        const table = body.action === "delete_document" ? "deal_documents" : "research_reports";
        const { data, error } = await admin.from(table).delete().eq("user_id", userId).eq("id", body.id).select("id").maybeSingle();
        if (error) throw error;
        if (data) await audit(body.action, body.id);
        return jsonResponse(200, {});
      }
      case "report": {
        if (typeof body.id !== "string" || !uuid.test(body.id)) return errorResponse(400, "INVALID_REQUEST", "Invalid report.");
        const { data, error } = await admin.from("research_reports").select("sealed").eq("user_id", userId).eq("id", body.id).maybeSingle();
        if (error) throw error;
        if (!data) return errorResponse(404, "NOT_FOUND", "Report unavailable.");
        const plaintext = await open(await keys(), data.sealed as SealedSecret, context("report", userId, body.id));
        return jsonResponse(200, JSON.parse(plaintext));
      }
      case "research_status": {
        if (typeof body.id !== "string" || !uuid.test(body.id)) return errorResponse(400, "INVALID_REQUEST", "Invalid research run.");
        const { data, error } = await admin.from("agent_analysis_runs").select("status,created_at,failure_code,failure_message")
          .eq("id", body.id).eq("user_id", userId).maybeSingle();
        if (error) throw error;
        if (!data) return errorResponse(404, "NOT_FOUND", "Research run unavailable.");
        const expired = data.status === "running" && Date.now() - Date.parse(data.created_at) > 180_000;
        return jsonResponse(200, { status: expired ? "failed" : data.status,
          failure_code: data.failure_code, failure_message: data.failure_message });
      }
      case "research": {
        const { document_ids: ids, opportunity_ids: dealIDs, question, mode } = body;
        if (!Array.isArray(ids) || !Array.isArray(dealIDs) || ids.length + dealIDs.length < 1 ||
          ids.length + dealIDs.length > 3 || [...ids, ...dealIDs].some((id) => typeof id !== "string" || !uuid.test(id)) ||
          new Set(ids).size !== ids.length || new Set(dealIDs).size !== dealIDs.length ||
          typeof question !== "string" || !question.trim() || question.length > 1_000 ||
          (mode !== "question" && mode !== "committee")) {
          return errorResponse(400, "INVALID_RESEARCH", "Select one to three sources and enter a research question.");
        }
        const documentProvider = Deno.env.get("PRIVATE_MARKETS_DOCUMENT_AI_PROVIDER");
        const approvedProvider = documentProvider === "gemini" || documentProvider === "openai";
        if (ids.length && (body.ai_consent !== true || Deno.env.get("PRIVATE_MARKETS_DOCUMENT_AI_ENABLED") !== "true" ||
          !approvedProvider)) {
          return errorResponse(403, "DOCUMENT_AI_DISABLED", "Document analysis requires consent and an approved AI processing configuration.");
        }
        const keyring = await keys();
        const evidence: Evidence[] = [];
        const sources: { id: string; title: string; url?: string }[] = [];
        if (ids.length) {
          const { data, error } = await admin.from("deal_documents").select("id,title,sealed")
            .eq("user_id", userId).in("id", ids);
          if (error) throw error;
          if (data.length !== ids.length) return errorResponse(404, "NOT_FOUND", "One or more documents are unavailable.");
          for (const doc of data) {
            const id = `D${sources.length + 1}`;
            const excerpt = await open(keyring, doc.sealed as SealedSecret, context("document", userId, doc.id));
            // Bound the serialized size as well (quotes and line breaks can expand).
            if (JSON.stringify(excerpt).length > 7_000) fail(422, "EXCERPT_TOO_LONG", "Use a shorter document excerpt.");
            evidence.push({ id, title: doc.title, text: excerpt });
            sources.push({ id, title: doc.title });
          }
        }
        if (dealIDs.length) {
          const { data, error } = await admin.from("investment_opportunities").select(publicDealFields)
            .eq("published", true).eq("round.published", true).eq("round.company.published", true)
            .eq("round.share_classes.published", true).in("id", dealIDs).returns<CatalogDeal[]>();
          if (error) throw error;
          if (data.length !== dealIDs.length) return errorResponse(404, "NOT_FOUND", "One or more published opportunities are unavailable.");
          for (const deal of data) {
            const id = `O${sources.length + 1}`;
            const company = deal.round.company.name;
            evidence.push({ id, title: company, text: dealEvidence(deal) });
            sources.push({ id, title: company, url: deal.source_url });
          }
        }
        const runId = crypto.randomUUID();
        const run = await admin.from("agent_analysis_runs").insert({ id: runId, user_id: userId, status: "running" });
        if (run.error) throw run.error;
        const research = async () => {
          try {
            await audit(ids.length ? "document_ai_consent" : "public_research_started", runId);
            const limit = Number.parseInt(Deno.env.get("AI_DAILY_LIMIT") ?? "", 10);
            const report = await buildResearch(userId, question, evidence, mode, {
              config: {
                geminiKey: (ids.length === 0 && !Deno.env.get("OPENAI_API_KEY")) ||
                    (ids.length > 0 && documentProvider === "gemini") ? Deno.env.get("GEMINI_API_KEY") : undefined,
                openAIKey: ids.length === 0 || documentProvider === "openai" ? Deno.env.get("OPENAI_API_KEY") : undefined,
                dailyLimit: Number.isFinite(limit) && limit >= 0 ? limit : AI_LIMITS.defaultDailyLimit,
                timeoutMs: mode === "committee" ? 22_000 : 10_000,
              },
              quota: {
                async consume(uid, ceiling) {
                  const { data, error } = await admin.rpc("consume_ai_quota", { p_user_id: uid, p_limit: ceiling }).single();
                  if (error) {
                    console.error("private research quota", error.code);
                    throw new ResearchError(503, "RESEARCH_QUOTA_FAILED", "Research quota could not be checked (" + error.code + ").");
                  }
                  const row = data as { allowed: boolean; used: number };
                  return { allowed: row.allowed, used: row.used };
                },
              },
              fetch,
            });
            const payload = { ...report, id: runId, sources, question, created_at: new Date().toISOString() };
            const sealed = await seal(keyring, JSON.stringify(payload), context("report", userId, runId));
            const result = await admin.rpc("finish_private_research", {
              p_user: userId, p_run: runId, p_title: question.trim().slice(0, 160), p_sealed: sealed,
            });
            if (result.error) {
              console.error("private research persistence", result.error.code);
              throw new ResearchError(503, "RESEARCH_SAVE_FAILED", "Research could not be saved (" + result.error.code + ").");
            }
            return payload;
          } catch (error) {
            await admin.from("agent_analysis_runs").update({
              status: "failed",
              failure_code: error instanceof ResearchError ? error.code : "RESEARCH_UNAVAILABLE",
              failure_message: error instanceof ResearchError ? error.message : "The research run could not finish.",
            }).eq("id", runId).eq("user_id", userId).eq("status", "running");
            throw error;
          }
        };
        const edgeRuntime = (globalThis as typeof globalThis & {
          EdgeRuntime?: { waitUntil(task: Promise<unknown>): void };
        }).EdgeRuntime;
        if (mode === "committee" && body.background === true && edgeRuntime) {
          edgeRuntime.waitUntil(research().catch((error) => {
            console.error("private committee failed", error instanceof ResearchError ? error.message : "unexpected error");
          }));
          return jsonResponse(202, { id: runId, status: "running" });
        }
        return jsonResponse(200, await research());
      }
      default:
        return errorResponse(400, "INVALID_ACTION", "Unknown Private Markets action.");
    }
  } catch (error) {
    if (error instanceof ResearchError) return errorResponse(error.status, error.code, error.message);
    console.error("private-markets operation failed",
      error instanceof Error ? error.name : (error as { code?: string } | null)?.code ?? "database error");
    return errorResponse(503, "PRIVATE_MARKETS_UNAVAILABLE", "Private Markets is temporarily unavailable. Try again.");
  }
});
