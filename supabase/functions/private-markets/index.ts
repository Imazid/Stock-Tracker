import { AI_LIMITS, type AiProxyDeps } from "../_shared/ai/proxy.ts";
import { authenticatedUserId, errorResponse, jsonResponse, readJson, serviceClient } from "../_shared/secure/edge.ts";
import { fromBase64, fromUtf8, timingSafeEqual, utf8 } from "../_shared/secure/encoding.ts";
import { open, parseKeyring, seal, type SealedSecret } from "../_shared/secure/envelope.ts";
import { buildResearch, type Evidence, ResearchError } from "../_shared/private-markets/research.ts";
import { currentStatus, type Discoverable, interpretDiscovery, matchDiscovery } from "../_shared/private-markets/discovery.ts";
import { ApnsSender, pushEnvironment, type PushEnvironment, validDeviceToken } from "../_shared/private-markets/apns.ts";
import { advancellCompany, type IssuerNotice, IssuerNewsError, readIssuerNews } from "../_shared/private-markets/issuer-news.ts";

const uuid = /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i;
const publicDealFields = "id,provider,category,status,minimum,eligibility,jurisdictions,source_url,offer_document_url,verified_at," +
  "round:funding_rounds!inner(id,stage,raised,target,valuation,valuation_method,currency,announced_on,closes_at,source_url,verified_at,traction," +
  "company:private_companies!inner(id,name,sector,country,location,description,logo_url,founders,investors,source_url,verified_at)," +
  "share_classes(name,rights,source_url))";

type CatalogDeal = {
  source_url: string;
  provider: string;
  category: string;
  status: string;
  verified_at: string;
  minimum: number | null;
  eligibility: string;
  jurisdictions: string[];
  round: {
    stage: string;
    announced_on: string | null;
    closes_at: string | null;
    verified_at: string;
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
    `Round: ${round.stage}; status: ${currentStatus(deal)}`,
    round.announced_on && `Round announcement date: ${round.announced_on}`,
    `Source verified: ${deal.verified_at}`,
    round.closes_at && `Published deadline: ${round.closes_at}`,
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
const researchStatusFields = "id,status,created_at,failure_code,failure_message";
const researchTimeoutMs = 180_000;

function researchStatus(row: { status: string; created_at: string; failure_code: unknown; failure_message: unknown }) {
  const expired = row.status === "running" && Date.now() - Date.parse(row.created_at) > researchTimeoutMs;
  return expired
    ? { ...row, status: "failed", failure_code: "RESEARCH_TIMED_OUT", failure_message: "The research run timed out." }
    : row;
}

function aiDependencies(admin: ReturnType<typeof serviceClient>, documentProvider?: "openai" | "gemini"): AiProxyDeps {
  const openAIKey = Deno.env.get("OPENAI_API_KEY");
  const limit = Number.parseInt(Deno.env.get("AI_DAILY_LIMIT") ?? "", 10);
  return {
    config: {
      geminiKey: documentProvider === "gemini" || (!documentProvider && !openAIKey) ? Deno.env.get("GEMINI_API_KEY") : undefined,
      openAIKey: documentProvider !== "gemini" ? openAIKey : undefined,
      dailyLimit: Number.isFinite(limit) && limit >= 0 ? limit : AI_LIMITS.defaultDailyLimit,
      timeoutMs: 10_000,
    },
    quota: {
      async consume(uid, ceiling) {
        const { data, error } = await admin.rpc("consume_ai_quota", { p_user_id: uid, p_limit: ceiling }).single();
        if (error) {
          console.error("private research quota", error.code);
          throw new ResearchError(503, "RESEARCH_QUOTA_FAILED", "Research quota could not be checked.");
        }
        const row = data as { allowed: boolean; used: number };
        return { allowed: row.allowed, used: row.used };
      },
    },
    fetch,
  };
}

function catalogue(admin: ReturnType<typeof serviceClient>) {
  return admin.from("investment_opportunities").select(publicDealFields)
    .eq("published", true).eq("round.published", true).eq("round.company.published", true)
    .eq("round.share_classes.published", true).order("verified_at", { ascending: false }).order("id");
}

type Announcement = { title: string; significance: string; published_at: string; source_url: string; company: { name: string } };

function announcementEvidence(item: Announcement, id: string): Evidence {
  const title = item.company.name + ": " + item.title;
  const summary = [
    "Company: " + item.company.name, "Announcement: " + item.title,
    "Published: " + item.published_at, item.significance,
  ].join("\n");
  return { id, title, text: summary.slice(0, 2_800) };
}

type DigestJob = {
  job_id: string;
  owner_id: string;
  lease: string;
  sources: { id: string; company: string; title: string; summary: string; published_at: string; url: string }[];
};

function schedulerAuthorized(req: Request) {
  const secret = Deno.env.get("PRIVATE_MARKET_DIGEST_SECRET");
  const supplied = req.headers.get("x-scheduler-secret");
  return !!secret && !!supplied && timingSafeEqual(utf8(supplied), utf8(secret));
}

async function scheduledDigests(admin: ReturnType<typeof serviceClient>) {
  const keyring = await keys();
  const { data, error } = await admin.rpc("claim_private_market_digests");
  if (error) throw error;
  if (!Array.isArray(data)) throw new Error("Invalid scheduled research response");
  const jobs = data as DigestJob[];
  const question = "Summarise recent published announcements and identify what still needs verification.";
  const results = await Promise.allSettled(jobs.map(async (job) => {
    const evidence = job.sources.map((source, index) => announcementEvidence({
      company: { name: source.company }, title: source.title, significance: source.summary,
      published_at: source.published_at, source_url: source.url,
    }, "O" + (index + 1)));
    const report = await buildResearch(job.owner_id, question, evidence, "digest", aiDependencies(admin));
    const sources = evidence.map(({ id, title }, index) => ({ id, title, url: job.sources[index].url }));
    const payload = { ...report, id: job.job_id, sources, question, created_at: new Date().toISOString() };
    const sealed = await seal(keyring, JSON.stringify(payload), context("report", job.owner_id, job.job_id));
    const result = await admin.rpc("finish_private_market_digest", {
      p_job: job.job_id, p_lease: job.lease, p_sources: job.sources, p_sealed: sealed,
    });
    if (result.error) throw result.error;
    return result.data === true;
  }));
  for (const result of results) {
    if (result.status === "rejected") {
      const reason = result.reason;
      console.error("private scheduled research failed", reason instanceof ResearchError ? reason.code : reason?.code ?? "UNKNOWN");
    }
  }
  return jsonResponse(200, {
    claimed: jobs.length,
    saved: results.filter((result) => result.status === "fulfilled" && result.value).length,
    failed: results.filter((result) => result.status === "rejected").length,
  });
}

function apnsConfig(environment: PushEnvironment) {
  const prefix = "PRIVATE_MARKET_APNS_" + environment.toUpperCase();
  const team = Deno.env.get(prefix + "_TEAM_ID");
  const keyId = Deno.env.get(prefix + "_KEY_ID");
  const privateKey = Deno.env.get(prefix + "_PRIVATE_KEY");
  return team && keyId && privateKey ? { team, keyId, privateKey, environment } : undefined;
}

const senders = new Map<PushEnvironment, ApnsSender>();

async function scheduledPush(admin: ReturnType<typeof serviceClient>) {
  const environments = (["sandbox", "production"] as const).filter((environment) => {
    const config = apnsConfig(environment);
    if (!config) return false;
    if (!senders.has(environment)) senders.set(environment, new ApnsSender(config, fetch));
    return true;
  });
  if (!environments.length) return jsonResponse(200, { accepted: 0, configured: false });
  const keyring = await keys();
  const { data, error } = await admin.rpc("claim_private_market_push", { p_environments: environments });
  if (error) throw error;
  if (!Array.isArray(data)) throw new Error("Invalid push claims");
  const jobs = data as {
    owner_id: string; installation_id: string; lease: string; push_environment: PushEnvironment; envelope: SealedSecret;
  }[];
  const results = await Promise.allSettled(jobs.map(async (job) => {
    const fields = { p_user: job.owner_id, p_device: job.installation_id, p_lease: job.lease };
    const token = await open(keyring, job.envelope, context("push", job.owner_id, job.installation_id));
    const current = await admin.rpc("private_market_push_is_current", fields);
    if (current.error) throw current.error;
    if (!current.data) return false;
    const sender = senders.get(job.push_environment);
    if (!sender) return false;
    const result = await sender.send(token, job.lease);
    const saved = await admin.rpc("finish_private_market_push", { ...fields, p_result: result });
    if (saved.error) throw saved.error;
    return result === "accepted";
  }));
  const accepted = results.filter((result) => result.status === "fulfilled" && result.value).length;
  const failed = results.filter((result) => result.status === "rejected").length;
  if (failed) console.warn("private push delivery errors", failed);
  return jsonResponse(200, { accepted, attempted: jobs.length, failed, configured: true });
}

function sessionId(req: Request): string | null {
  // Called only after Auth validates this bearer JWT. The RPC also checks that
  // the referenced session is active and belongs to the verified user.
  try {
    const encoded = req.headers.get("Authorization")?.split(".")[1];
    const id = encoded && JSON.parse(fromUtf8(fromBase64(encoded))).session_id;
    return typeof id === "string" && uuid.test(id) ? id : null;
  } catch { return null; }
}

async function scheduledIssuerNews(admin: ReturnType<typeof serviceClient>) {
  const { data, error } = await admin.rpc("claim_private_issuer_news");
  if (error) throw error;
  if (!Array.isArray(data)) throw new Error("Invalid issuer newsroom claim");
  const [job] = data as { company: string; token: string; etag: string | null }[];
  if (!job) return jsonResponse(200, { checked: false, written: 0 });
  if (job.company !== advancellCompany) throw new Error("Unknown newsroom");

  let notices: IssuerNotice[] = [];
  let etag = job.etag;
  let failure: string | null = null;
  let delay: number | null = null;
  try {
    const result = await readIssuerNews(etag);
    notices = result.notices;
    etag = result.etag;
    if (result.failures) failure = "NEWSROOM_PARTIAL";
  } catch (error) {
    failure = error instanceof IssuerNewsError ? error.code : "NEWSROOM_UNREACHABLE";
    delay = error instanceof IssuerNewsError ? error.retryAfterSeconds ?? null : null;
  }
  const result = await admin.rpc("finish_private_issuer_news", {
    p_company: job.company, p_token: job.token, p_etag: etag, p_notices: notices,
    p_error: failure, p_retry_seconds: delay,
  });
  if (result.error) throw result.error;
  return jsonResponse(failure && notices.length === 0 ? 503 : 200, { checked: true, written: result.data, failure });
}

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

    if (body.action === "scheduled_digest" || body.action === "scheduled_push" || body.action === "scheduled_issuer_news") {
      if (!schedulerAuthorized(req)) return errorResponse(401, "UNAUTHENTICATED", "Scheduler authorization required.");
      if (body.action === "scheduled_digest") return await scheduledDigests(admin);
      if (body.action === "scheduled_push") return await scheduledPush(admin);
      return await scheduledIssuerNews(admin);
    }
    if (body.action === "catalog") {
      const { data, error } = await catalogue(admin).range(0, 499);
      if (error) throw error;
      return jsonResponse(200, { deals: data });
    }
    const userId = await authenticatedUserId(req, admin);
    if (!userId) return errorResponse(401, "UNAUTHENTICATED", "Sign in first.");
    // PostgreSQL UUIDs are case-insensitive. The encryption context is case-sensitive.
    for (const key of ["id", "opportunity_id"]) {
      const value = body[key];
      if (typeof value === "string" && uuid.test(value)) body[key] = value.toLowerCase();
    }

    const audit = async (action: string, subject?: string) => {
      const { error } = await admin.from("investment_audit_logs").insert({ user_id: userId, action, subject_id: subject });
      if (error) throw error;
    };
    switch (body.action) {
      case "monitor_push": {
        const { device_id: device, environment, token } = body;
        if (typeof device !== "string" || !uuid.test(device) ||
          (environment !== undefined && environment !== null && !pushEnvironment(environment)) ||
          (token !== null && (!validDeviceToken(token) || !pushEnvironment(environment)))) {
          return errorResponse(400, "INVALID_MONITOR_PUSH", "Send the installation identifier and a valid device token.");
        }
        const session = sessionId(req);
        const configured = pushEnvironment(environment) && !!apnsConfig(environment);
        const enabled = token !== null && configured && session !== null;
        const normalized = validDeviceToken(token) ? token.toLowerCase() : "";
        const digest = enabled ? await crypto.subtle.digest("SHA-256", utf8(normalized)) : null;
        const hash = digest && Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
        const sealed = enabled ? await seal(await keys(), normalized, context("push", userId, device.toLowerCase())) : null;
        const { data, error } = await admin.rpc("configure_private_market_push", {
          p_user: userId, p_device: device, p_session: session, p_environment: environment ?? null,
          p_token_hash: hash, p_sealed: sealed,
        });
        if (error) throw error;
        return jsonResponse(200, { registered: data === true });
      }
      case "monitor_settings": {
        const { device_id: device, company_ids: companies, enabled, eligible_opportunities: eligible, digest } = body;
        if (typeof device !== "string" || !uuid.test(device) || typeof enabled !== "boolean" || typeof eligible !== "boolean" ||
          (digest !== undefined && typeof digest !== "boolean") ||
          !Array.isArray(companies) || companies.length > 250 || companies.some((id) => typeof id !== "string" || !uuid.test(id))) {
          return errorResponse(400, "INVALID_MONITOR_SETTINGS", "Send a device identifier and up to 250 company identifiers.");
        }
        const { error } = await admin.rpc("configure_private_monitor", {
          p_user: userId, p_device: device, p_companies: companies, p_enabled: enabled, p_eligible: eligible,
          ...(digest === undefined ? {} : { p_digest: digest }),
        });
        if (error?.code === "22023") return errorResponse(422, "MONITOR_SETTINGS_UNAVAILABLE", error.message);
        if (error) throw error;
        return jsonResponse(200, {});
      }
      case "monitor_inbox": {
        const collected = await admin.rpc("collect_private_market_alerts", { p_user: userId });
        if (collected.error) throw collected.error;
        const { data, error } = await admin.rpc("private_market_alert_inbox", { p_user: userId });
        if (error) throw error;
        return jsonResponse(200, { alerts: data });
      }
      case "discover": {
        const question = body.question;
        if (typeof question !== "string" || !question.trim() || question.length > 600) {
          return errorResponse(400, "INVALID_DISCOVERY", "Enter a search question up to 600 characters.");
        }
        const { data, error } = await catalogue(admin).range(0, 500).returns<Discoverable[]>();
        if (error) throw error;
        const window = data.slice(0, 500);
        const sectors = [...new Set(window.map((deal) => deal.round.company.sector))].slice(0, 60);
        const criteria = await interpretDiscovery(userId, question.trim(), sectors, aiDependencies(admin));
        const deals = matchDiscovery(window, criteria);
        return jsonResponse(200, { criteria, deals: deals.slice(0, 100), matched_count: deals.length, scanned_all: data.length <= 500 });
      }
      case "updates": {
        const ids = body.company_ids;
        if (!Array.isArray(ids) || ids.length > 100 || ids.some((id) => typeof id !== "string" || !uuid.test(id))) {
          return errorResponse(400, "INVALID_REQUEST", "Send up to 100 watched company IDs.");
        }
        if (!ids.length) return jsonResponse(200, { updates: [] });
        const { data, error } = await admin.from("corporate_actions")
          .select("id,title,significance,source_url,source_label,published_at,company:private_companies!inner(name)")
          .eq("published", true).eq("company.published", true).lte("published_at", new Date().toISOString())
          .in("company_id", ids).order("published_at", { ascending: false }).limit(100);
        if (error) throw error;
        const now = new Date();
        const since = new Date(now.getTime() - 86_400_000);
        const { data: rounds, error: roundsError } = await admin.from("investment_opportunities")
          .select("id,status,source_url,verified_at,round:funding_rounds!inner(stage,closes_at,company:private_companies!inner(name))")
          .eq("published", true).eq("round.published", true).eq("round.company.published", true)
          .in("round.company_id", ids).in("status", ["open", "interest"])
          .gte("verified_at", since.toISOString()).lte("verified_at", now.toISOString())
          .gte("round.verified_at", since.toISOString())
          .lte("round.verified_at", now.toISOString())
          .gt("round.closes_at", now.toISOString())
          .order("verified_at", { ascending: false }).limit(100)
          .returns<{ id: string; status: string; source_url: string; verified_at: string;
            round: { stage: string; company: { name: string } } }[]>();
        if (roundsError) throw roundsError;
        const funding = rounds.map((item) => ({
          id: item.id, title: item.round.stage, kind: item.status === "open" ? "open_round" : "interest",
          significance: item.status === "open" ? "The source listed this funding round as open at verification." :
            "The source published an expression of interest.",
          source_url: item.source_url, published_at: item.verified_at, company: item.round.company,
        }));
        const announcements = data.map((item) => ({ ...item, kind: "announcement" }));
        return jsonResponse(200, {
          updates: [...announcements, ...funding].sort((a, b) => Date.parse(b.published_at) - Date.parse(a.published_at)).slice(0, 100),
        });
      }
      case "profile": {
        const [profile, checks] = await Promise.all([
          admin.from("investor_profiles").select("country,declared_class").eq("user_id", userId).maybeSingle(),
          admin.from("investor_eligibility")
            .select("provider,jurisdiction,verified_class,verified_at,expires_at,accountant_certificate_reviewed_at," +
              "connection:provider_connections!inner(revoked_at)")
            .eq("user_id", userId).eq("connection.user_id", userId)
            .order("provider").order("jurisdiction"),
        ]);
        if (profile.error) throw profile.error;
        if (checks.error) throw checks.error;
        return jsonResponse(200, { profile: profile.data, eligibility: checks.data });
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
        const offset = body.offset ?? 0;
        if (typeof offset !== "number" || !Number.isSafeInteger(offset) || offset < 0 || offset > 10_000) {
          return errorResponse(400, "INVALID_REQUEST", "Invalid portfolio page.");
        }
        const pageSize = 20;
        const { data, error } = await admin.from("private_holdings")
          .select("id,name,asset_class,currency,company_id,units,ownership_percent,committed_amount,settled_amount," +
            "settled_on,settlement_source,confirmed_at,remaining_units,last_disposition_on,disposition_revision_at,exit_source," +
            "commitment:investment_commitments!inner(provider,provider_reference,status)," +
            "marks:valuation_history(id,value,valued_on,source,methodology,provider_event_at)," +
            "calls:capital_calls(id,amount,due_on,settled_on,source)," +
            "distributions(id,amount,received_on,source)," +
            "dispositions:private_holding_dispositions(id,sold_units,net_proceeds,disposed_cost,settled_on,source)")
          .eq("user_id", userId).eq("commitment.user_id", userId).eq("commitment.status", "confirmed")
          .not("confirmed_at", "is", null).not("settled_amount", "is", null)
          .eq("marks.user_id", userId).eq("calls.user_id", userId).eq("distributions.user_id", userId)
          .eq("dispositions.user_id", userId).eq("dispositions.reversed", false)
          .order("id").range(offset, offset + pageSize)
          .order("valued_on", { referencedTable: "marks", ascending: false })
          .order("provider_event_at", { referencedTable: "marks", ascending: false, nullsFirst: false })
          .order("id", { referencedTable: "marks" })
          .order("due_on", { referencedTable: "calls", ascending: false }).order("id", { referencedTable: "calls" })
          .order("received_on", { referencedTable: "distributions", ascending: false })
          .order("id", { referencedTable: "distributions" })
          .order("settled_on", { referencedTable: "dispositions", ascending: false })
          .order("provider_event_at", { referencedTable: "dispositions", ascending: false })
          .order("id", { referencedTable: "dispositions" })
          .limit(101, { referencedTable: "marks" }).limit(101, { referencedTable: "calls" })
          .limit(101, { referencedTable: "distributions" }).limit(101, { referencedTable: "dispositions" });
        if (error) throw error;
        return jsonResponse(200, {
          holdings: data.slice(0, pageSize),
          next_offset: data.length > pageSize ? offset + pageSize : null,
        });
      }
      case "applications": {
        const { data, error } = await admin.from("investment_commitments")
          .select("id,status,requested_amount,currency,provider,provider_reference,confirmed_at,cooling_off_ends_at,acknowledged_at," +
            "provider_received_at,withdrawal_requested_at,withdrawal_declined_at,withdrawn_at,provider_event_at," +
            "offer:investment_opportunities(round:funding_rounds(stage,company:private_companies(name)))")
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
      case "reports":
      case "monitor_digests": {
        const table = body.action === "documents" ? "deal_documents" : "research_reports";
        const list = admin.from(table).select("id,title,created_at")
          .eq("user_id", userId).order("created_at", { ascending: false }).limit(100);
        const { data, error } = await (body.action === "monitor_digests" ? list.eq("kind", "monitor_digest") : list);
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
        const { data, error } = await admin.from("agent_analysis_runs").select(researchStatusFields)
          .eq("id", body.id).eq("user_id", userId).maybeSingle();
        if (error) throw error;
        if (!data) return errorResponse(404, "NOT_FOUND", "Research run unavailable.");
        return jsonResponse(200, researchStatus(data));
      }
      case "research_runs": {
        const since = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
        const { data, error } = await admin.from("agent_analysis_runs").select(researchStatusFields)
          .eq("user_id", userId).neq("status", "complete").gte("created_at", since)
          .order("created_at", { ascending: false }).order("id").limit(20);
        if (error) throw error;
        return jsonResponse(200, { runs: data.map(researchStatus) });
      }
      case "research": {
        const { document_ids: ids, opportunity_ids: dealIDs, announcement_ids: announcementIDs = [], question, mode } = body;
        if (!Array.isArray(ids) || !Array.isArray(dealIDs) || !Array.isArray(announcementIDs)) {
          return errorResponse(400, "INVALID_RESEARCH", "Select one to three sources and enter a research question.");
        }
        const sourceIDs = [...ids, ...dealIDs, ...announcementIDs];
        if (sourceIDs.length < 1 || sourceIDs.length > 3 ||
          sourceIDs.some((id) => typeof id !== "string" || !uuid.test(id)) || new Set(sourceIDs).size !== sourceIDs.length ||
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
        if (announcementIDs.length) {
          const { data, error } = await admin.from("corporate_actions")
            .select("title,significance,published_at,source_url,company:private_companies!inner(name)")
            .eq("published", true).eq("company.published", true).lte("published_at", new Date().toISOString())
            .in("id", announcementIDs).order("published_at", { ascending: false })
            .returns<Announcement[]>();
          if (error) throw error;
          if (data.length !== announcementIDs.length) return errorResponse(404, "NOT_FOUND", "One or more published announcements are unavailable.");
          for (const item of data) {
            const id = `O${sources.length + 1}`;
            const entry = announcementEvidence(item, id);
            evidence.push(entry);
            sources.push({ id, title: entry.title, url: item.source_url });
          }
        }
        const runId = crypto.randomUUID();
        const run = await admin.from("agent_analysis_runs").insert({ id: runId, user_id: userId, status: "running" });
        if (run.error) throw run.error;
        const research = async () => {
          try {
            await audit(ids.length ? "document_ai_consent" : "public_research_started", runId);
            const deps = aiDependencies(admin, ids.length && approvedProvider ? documentProvider : undefined);
            if (mode === "committee") deps.config.timeoutMs = 22_000;
            const report = await buildResearch(userId, question, evidence, mode, deps);
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
