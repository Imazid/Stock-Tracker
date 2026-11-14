import { exportOffset, exportSection, privateExportPage } from "../_shared/private-markets/export.ts";
import { AI_LIMITS, type AiProxyDeps } from "../_shared/ai/proxy.ts";
import { authenticatedUserId, errorResponse, jsonResponse, readJson, serviceClient } from "../_shared/secure/edge.ts";
import { fromBase64, fromUtf8, timingSafeEqual, utf8 } from "../_shared/secure/encoding.ts";
import { open, parseKeyring, seal, type SealedSecret } from "../_shared/secure/envelope.ts";
import { buildResearch, type Evidence, ResearchError } from "../_shared/private-markets/research.ts";
import { currentStatus, type Discoverable, interpretDiscovery, matchDiscovery } from "../_shared/private-markets/discovery.ts";
import { ApnsSender, pushEnvironment, type PushEnvironment, validDeviceToken } from "../_shared/private-markets/apns.ts";
import { advancellCompany, type IssuerNotice, IssuerNewsError, readIssuerNews } from "../_shared/private-markets/issuer-news.ts";
import {
  announcementBaseline, announcementRevision, changedSourceIds, comparePublishedSources, fundingRoundBaseline,
  fundingRoundRevision, type SourceBaseline, sourceChangeEvidence,
} from "../_shared/private-markets/source-revisions.ts";

const uuid = /^[a-f\d]{8}-(?:[a-f\d]{4}-){3}[a-f\d]{12}$/i;
// One web subscription per account, independent of any iPhone installation.
const webMonitorDevice = "4c736341-5e56-4e0d-9466-7438190e4e60";
const activeSessionActions = new Set([
  "web_monitor_preferences", "save_web_monitor", "monitor_inbox", "monitor_digests", "allocation",
]);

const publicDealFields = "id,provider,category,status,minimum,eligibility,jurisdictions,source_url,offer_document_url,verified_at," +
  "round:funding_rounds!inner(id,stage,raised,target,valuation,valuation_method,currency,announced_on,closes_at,source_url,verified_at,traction," +
  "company:private_companies!inner(id,name,sector,country,location,description,logo_url,founders,investors,source_url,verified_at," +
  "financials:private_company_financials(id,period_end_on,period_kind,assurance,currency,revenue,annual_recurring_revenue," +
  "net_profit_loss,operating_cash_flow,cash_and_equivalents,published_on,source_url,verified_at))," +
  "share_classes(name,rights,source_url)," +
  "listing:private_listing_milestones(exchange,symbol,quotation_status,expected_offer_close_on,quotation_on,source_url,verified_at))";

type CompanyFinancials = {
  period_end_on: string;
  period_kind: "financial_year" | "month_snapshot";
  assurance: "audited" | "issuer_reported";
  currency: string;
  revenue: number | null;
  annual_recurring_revenue: number | null;
  net_profit_loss: number | null;
  operating_cash_flow: number | null;
  cash_and_equivalents: number | null;
  published_on: string;
  source_url: string;
};

type CatalogDeal = {
  id: string;
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
    company: { id: string; name: string; description: string | null; country: string; sector: string; financials: CompanyFinancials[] };
    share_classes: { name: string; rights: string }[];
    listing: {
      exchange: string; symbol: string; quotation_status: "proposed" | "anticipated" | "listed" | "withdrawn";
      expected_offer_close_on: string | null; quotation_on: string | null; source_url: string; verified_at: string;
    } | null;
  };
};

type ReportFact = { label: string; value: string };

const amountFormat = new Intl.NumberFormat("en-GB", { maximumFractionDigits: 4 });
function reportedAmount(currency: string, amount: number) {
  return `${currency} ${amountFormat.format(amount)}`;
}

function roundFacts(deal: CatalogDeal): ReportFact[] {
  const round = deal.round;
  const items: [string, number | null][] = [
    ["Minimum investment", deal.minimum], ["Raised", round.raised], ["Raise target", round.target],
    ["Reported valuation", round.valuation],
  ];
  return items.flatMap(([label, amount]) =>
    amount === null ? [] : [{ label, value: reportedAmount(round.currency, amount) }]
  );
}

function dealEvidence(deal: CatalogDeal, facts: ReportFact[]): string {
  const { round } = deal;
  const { company } = round;
  return [
    `Company: ${company.name}`,
    `Sector: ${company.sector}; country: ${company.country}`,
    `Round: ${round.stage}; status: ${currentStatus(deal)}`,
    round.announced_on && `Round announcement date: ${round.announced_on}`,
    `Source verified: ${deal.verified_at}`,
    round.closes_at && `Published deadline: ${round.closes_at}`,
    `Provider: ${deal.provider}; category: ${deal.category}`,
    ...facts.map(({ label, value }) => `${label}: ${value}`),
    round.valuation_method && `Valuation method: ${round.valuation_method}`,
    `Eligibility: ${deal.eligibility}; jurisdictions: ${deal.jurisdictions.join(", ")}`,
    company.description, round.traction,
    ...round.share_classes.map((item) => `${item.name}: ${item.rights}`),
  ].filter(Boolean).join("\n").slice(0, 2_800);
}

const disclosureDate = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });
const disclosureMonth = new Intl.DateTimeFormat("en-GB", { month: "long", year: "numeric", timeZone: "UTC" });

function financialFacts(record: CompanyFinancials): ReportFact[] {
  const period = record.period_kind === "financial_year"
    ? `year ended ${disclosureDate.format(new Date(record.period_end_on))}`
    : `snapshot for ${disclosureMonth.format(new Date(record.period_end_on))}`;
  const assurance = record.assurance === "audited" ? "Audited financial statements" : "Issuer-reported figures";
  const fields: [string, number | null][] = [
    ["Revenue", record.revenue], ["Annual recurring revenue", record.annual_recurring_revenue],
    ["Net profit or loss", record.net_profit_loss], ["Net operating cash flow", record.operating_cash_flow],
    ["Cash and cash equivalents", record.cash_and_equivalents],
  ];
  return fields.flatMap(([label, amount]) => amount === null ? [] : [
    { label: `${assurance}, ${period}: ${label}`, value: reportedAmount(record.currency, amount) },
  ]);
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
  const now = new Date().toISOString();
  return admin.from("investment_opportunities").select(publicDealFields)
    .eq("published", true).eq("round.published", true).eq("round.company.published", true)
    .eq("round.share_classes.published", true)
    .eq("round.listing.published", true).lte("round.listing.verified_at", now)
    .eq("round.company.financials.published", true).lte("round.company.financials.verified_at", now)
    .order("period_end_on", { referencedTable: "round.company.financials", ascending: false })
    .order("period_kind", { referencedTable: "round.company.financials" })
    .limit(6, { referencedTable: "round.company.financials" })
    .order("verified_at", { ascending: false }).order("id");
}

type Announcement = {
  id: string;
  company_id: string;
  title: string;
  significance: string;
  published_at: string;
  source_url: string;
  company_name: string;
};

type PublishedUpdate = Announcement & {
  source_label: string | null;
  round_announced_on: string | null;
  financial_published_on: string | null;
  source_revised_at: string | null;
};

type ReportSource = { id: string; title: string; url?: string };
type ReportFactGroup = { source: string; title: string; entries: ReportFact[] };
type SourceReferences = { document_ids: string[]; opportunity_ids: string[]; announcement_ids: string[]; company_ids: string[];
  revisions?: Record<string, string>; baselines?: Record<string, SourceBaseline> };
type StoredReport = { question: string; source_refs?: SourceReferences } & Record<string, unknown>;

function publicReport({ source_refs, ...report }: StoredReport) {
  return { ...report, refresh_available: source_refs !== undefined };
}

function publishedAnnouncements(admin: ReturnType<typeof serviceClient>) {
  return admin.from("published_private_company_updates")
    .select(`id,title,significance,source_url,source_label,published_at,round_announced_on,
      company_name,company_id,financial_published_on,source_revised_at`);
}

function companyUpdate(item: PublishedUpdate) {
  return { id: item.id, title: item.title, significance: item.significance, source_url: item.source_url,
    source_label: item.source_label, published_at: item.published_at, round_announced_on: item.round_announced_on,
    financial_published_on: item.financial_published_on, revised_at: item.source_revised_at,
    kind: item.financial_published_on ? "financial_disclosure" : item.round_announced_on ? "closed_round" : "announcement",
    company: { name: item.company_name } };
}

function announcementEvidence(item: Pick<Announcement, "company_name" | "title" | "published_at" | "significance">, id: string): Evidence {
  const title = item.company_name + ": " + item.title;
  const summary = [
    "Company: " + item.company_name, "Announcement: " + item.title,
    "Published: " + item.published_at, item.significance,
  ].join("\n");
  return { id, title, text: summary.slice(0, 2_800) };
}

async function savedReport(admin: ReturnType<typeof serviceClient>, userId: string, id: string) {
  const { data, error } = await admin.from("research_reports").select("sealed,created_at")
    .eq("user_id", userId).eq("id", id).maybeSingle();
  if (error) throw error;
  if (!data) throw new ResearchError(404, "NOT_FOUND", "Report unavailable.");
  const plain = await open(await keys(), data.sealed as SealedSecret, context("report", userId, id));
  return { report: JSON.parse(plain) as StoredReport, createdAt: data.created_at as string };
}

async function researchRefresh(admin: ReturnType<typeof serviceClient>, userId: string, id: string) {
  const { report, createdAt } = await savedReport(admin, userId, id);
  const refs = reportSourceReferences(report);
  const [docs, offers, notices] = await Promise.all([
    refs.document_ids.length ? admin.from("deal_documents").select("id,title,created_at").eq("user_id", userId)
      .in("id", refs.document_ids) : Promise.resolve({ data: [], error: null }),
    refs.opportunity_ids.length ? catalogue(admin).in("id", refs.opportunity_ids).returns<CatalogDeal[]>() :
      Promise.resolve({ data: [], error: null }),
    refs.announcement_ids.length ? publishedAnnouncements(admin).in("id", refs.announcement_ids)
      .order("activity_at", { ascending: false }).order("id").returns<PublishedUpdate[]>() :
      Promise.resolve({ data: [], error: null }),
  ]);
  if (docs.error) throw docs.error;
  if (offers.error) throw offers.error;
  if (notices.error) throw notices.error;
  const existing = new Set(refs.announcement_ids);
  const newer = refs.company_ids.length ? await publishedAnnouncements(admin).in("company_id", refs.company_ids)
    .gt("activity_at", createdAt).order("activity_at", { ascending: false }).order("id").limit(12).returns<PublishedUpdate[]>() :
    { data: [], error: null };
  if (newer.error) throw newer.error;
  const [changedDeals, changedAnnouncements] = await Promise.all([
    changedSourceIds(offers.data, refs.revisions, fundingRoundRevision),
    changedSourceIds(notices.data, refs.revisions, announcementRevision),
  ]);
  return {
    question: report.question,
    unavailable_sources: refs.document_ids.length + refs.opportunity_ids.length + refs.announcement_ids.length -
      (docs.data.length + offers.data.length + notices.data.length),
    documents: docs.data,
    deals: offers.data,
    announcements: notices.data.map(companyUpdate),
    newer_announcements: newer.data.filter((item) => !existing.has(item.id)).map(companyUpdate),
    changed_deal_ids: changedDeals,
    changed_announcement_ids: changedAnnouncements,
    revision_tracking_available: refs.revisions !== undefined,
    source_changes: comparePublishedSources(refs.baselines, Object.fromEntries([
      ...offers.data.map((item) => [item.id, fundingRoundBaseline(item)] as const),
      ...notices.data.map((item) => [item.id, announcementBaseline(item)] as const),
    ])),
  };
}

function reportSourceReferences(report: StoredReport): SourceReferences {
  if (!report.source_refs) {
    throw new ResearchError(409, "REPORT_SOURCES_UNAVAILABLE", "This report was saved before source references became available.");
  }
  return report.source_refs;
}

type DigestJob = {
  job_id: string;
  owner_id: string;
  lease: string;
  sources: { id: string; company: string; title: string; summary: string; published_at: string; url: string; is_revision?: boolean }[];
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
  const results = await Promise.allSettled(jobs.map(async (job) => {
    const includesRevision = job.sources.some((source) => source.is_revision === true);
    const question = includesRevision
      ? "Summarise the current published disclosures. Distinguish updated sources from newly included announcements and identify what still needs verification. Describe a specific change only if the source says what changed."
      : "Summarise recent published company disclosures and identify what still needs verification.";
    const evidence = job.sources.map((source, index) => announcementEvidence({
      company_name: source.company, title: source.is_revision ? "Updated source · " + source.title : source.title,
      significance: source.summary,
      published_at: source.published_at,
    }, "O" + (index + 1)));
    const report = await buildResearch(job.owner_id, question, evidence, "digest", aiDependencies(admin));
    const sources = evidence.map(({ id, title }, index) => ({ id, title, url: job.sources[index].url }));
    const announcementIds = job.sources.map((source) => source.id);
    const { data: current, error } = await publishedAnnouncements(admin).in("id", announcementIds);
    if (error) throw error;
    const revisions = Object.fromEntries(await Promise.all(job.sources.map(async (source) => [source.id,
      await announcementRevision({ company_name: source.company, title: source.title, significance: source.summary,
        published_at: source.published_at, source_url: source.url })])));
    const baselines = Object.fromEntries(job.sources.map((source) => [source.id,
      announcementBaseline({ company_name: source.company, title: source.title, significance: source.summary })]));
    const source_refs: SourceReferences = { document_ids: [], opportunity_ids: [], announcement_ids: announcementIds,
      company_ids: [...new Set(current.map((item) => item.company_id as string))], revisions, baselines };
    const payload = { ...report, id: job.job_id, sources, source_refs, question, created_at: new Date().toISOString() };
    const sealed = await seal(keyring, JSON.stringify(payload), context("report", job.owner_id, job.job_id));
    const result = await admin.rpc("finish_private_market_digest", {
      p_job: job.job_id, p_lease: job.lease, p_sources: job.sources, p_sealed: sealed,
    });
    if (result.error) throw result.error;
    return result.data === true;
  }));
  const failureCodes = new Set<string>();
  for (const result of results) {
    if (result.status === "rejected") {
      const code = result.reason?.code;
      const safeCode = typeof code === "string" && /^[A-Z0-9_]{1,48}$/.test(code) ? code : "UNKNOWN";
      failureCodes.add(safeCode);
      console.error("private scheduled research failed", safeCode);
    }
  }
  return jsonResponse(200, {
    claimed: jobs.length,
    saved: results.filter((result) => result.status === "fulfilled" && result.value).length,
    failed: results.filter((result) => result.status === "rejected").length,
    ...(failureCodes.size > 0 ? { failure_codes: [...failureCodes] } : {}),
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
    if (typeof body.action === "string" && activeSessionActions.has(body.action)) {
      const session = sessionId(req);
      if (!session) return errorResponse(401, "UNAUTHENTICATED", "Sign in to view your account records.");
      const { data: active, error } = await admin.rpc("account_deletion_session_active", { p_user: userId, p_session: session });
      if (error) throw error;
      if (active !== true) return errorResponse(401, "UNAUTHENTICATED", "Your session ended. Sign in again.");
    }
    if ((body.action === "discover" || body.action === "research") && body.model_consent !== true) {
      return errorResponse(403, "AI_CONSENT_REQUIRED", "Allow Stock Tracker to send this request to the AI provider.");
    }
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
      case "export_records": {
        const section = exportSection(body.section);
        const offset = exportOffset(body.offset);
        if (!section || offset === null || Object.keys(body).some((key) => !["action", "section", "offset"].includes(key))) {
          return errorResponse(400, "INVALID_EXPORT", "Choose a supported Private Markets export section and page.");
        }
        const session = sessionId(req);
        if (!session) return errorResponse(401, "UNAUTHENTICATED", "Sign in again to export your account records.");
        const active = await admin.rpc("account_deletion_session_active", { p_user: userId, p_session: session });
        if (active.error) throw active.error;
        if (!active.data) return errorResponse(401, "UNAUTHENTICATED", "Your session ended. Sign in again.");
        const page = await privateExportPage(admin, userId, section, offset, async (kind, id, sealed) => {
          const plaintext = await open(await keys(), sealed, context(kind, userId, id));
          return kind === "report" ? publicReport(JSON.parse(plaintext) as StoredReport) : plaintext;
        });
        return jsonResponse(200, page);
      }
      case "web_monitor_preferences":
      case "save_web_monitor": {
        if (body.action === "web_monitor_preferences" && Object.keys(body).length !== 1) {
          return errorResponse(400, "INVALID_MONITOR_SETTINGS", "Choose valid web monitoring preferences.");
        }
        if (body.action === "save_web_monitor") {
          const { enabled, company_ids: companies, eligible_opportunities: eligible, digest_enabled: digest } = body;
          if (Object.keys(body).some((key) => !["action", "enabled", "company_ids", "eligible_opportunities", "digest_enabled"].includes(key)) ||
            typeof enabled !== "boolean" || typeof eligible !== "boolean" || typeof digest !== "boolean" ||
            !Array.isArray(companies) || companies.length > 250 ||
            companies.some((id) => typeof id !== "string" || !uuid.test(id))) {
            return errorResponse(400, "INVALID_MONITOR_SETTINGS", "Choose valid web monitoring preferences.");
          }
          const { error } = await admin.rpc("configure_private_monitor", {
            p_user: userId, p_device: webMonitorDevice, p_enabled: enabled,
            p_companies: enabled ? [...new Set(companies.map((id: string) => id.toLowerCase()))] : [],
            p_eligible: enabled && eligible, p_digest: enabled && digest,
          });
          if (error?.code === "22023") return errorResponse(422, "MONITOR_SETTINGS_UNAVAILABLE", error.message);
          if (error) throw error;
        }
        const { data, error } = await admin.from("private_monitor_devices")
          .select("company_ids,eligible_opportunities,digest_enabled,refreshed_at")
          .eq("user_id", userId).eq("device_id", webMonitorDevice)
          .gte("refreshed_at", new Date(Date.now() - 90 * 86_400_000).toISOString())
          .maybeSingle();
        if (error) throw error;
        return jsonResponse(200, { preferences: data });
      }
      case "monitor_push": {
        const { device_id: device, environment, token } = body;
        if (typeof device !== "string" || !uuid.test(device) || device.toLowerCase() === webMonitorDevice ||
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
        if (typeof device !== "string" || !uuid.test(device) || device.toLowerCase() === webMonitorDevice || typeof enabled !== "boolean" || typeof eligible !== "boolean" ||
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
        const { data, error } = await admin.rpc("private_market_alert_inbox_with_revisions", { p_user: userId });
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
        const { data, error } = await publishedAnnouncements(admin)
          .in("company_id", ids).order("activity_at", { ascending: false }).order("id").limit(100)
          .returns<PublishedUpdate[]>();
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
          .order("verified_at", { ascending: false }).order("id").limit(100)
          .returns<{ id: string; status: string; source_url: string; verified_at: string;
            round: { stage: string; company: { name: string } } }[]>();
        if (roundsError) throw roundsError;
        const funding = rounds.map((item) => ({
          id: item.id, title: item.round.stage, kind: item.status === "open" ? "open_round" : "interest",
          significance: item.status === "open" ? "The source listed this funding round as open at verification." :
            "The source published an expression of interest.",
          source_url: item.source_url, published_at: item.verified_at, revised_at: null, company: item.round.company,
        }));
        const announcements = data.map(companyUpdate);
        return jsonResponse(200, {
          updates: [...announcements, ...funding].sort((a, b) =>
            Date.parse(b.revised_at ?? b.published_at) - Date.parse(a.revised_at ?? a.published_at) ||
            a.id.localeCompare(b.id)).slice(0, 100),
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
      case "allocation": {
        if (Object.keys(body).length !== 1) return errorResponse(400, "INVALID_REQUEST", "Send only the allocation action.");
        const { data, error } = await admin.rpc("private_portfolio_allocation", { p_user: userId });
        if (error) throw error;
        return jsonResponse(200, { buckets: data });
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
            "cancelled_calls:capital_calls(id,amount,due_on,source,cancelled_at,cancellation_source)," +
            "distributions(id,amount,received_on,source)," +
            "dispositions:private_holding_dispositions(id,sold_units,net_proceeds,disposed_cost,settled_on,source)")
          .eq("user_id", userId).eq("commitment.user_id", userId).eq("commitment.status", "confirmed")
          .not("confirmed_at", "is", null).not("settled_amount", "is", null)
          .eq("marks.user_id", userId).eq("calls.user_id", userId).eq("distributions.user_id", userId)
          .is("calls.cancelled_at", null).eq("cancelled_calls.user_id", userId)
          .not("cancelled_calls.cancelled_at", "is", null)
          .is("distributions.reversed_at", null)
          .eq("dispositions.user_id", userId).eq("dispositions.reversed", false)
          .order("id").range(offset, offset + pageSize)
          .order("valued_on", { referencedTable: "marks", ascending: false })
          .order("provider_event_at", { referencedTable: "marks", ascending: false, nullsFirst: false })
          .order("id", { referencedTable: "marks" })
          .order("due_on", { referencedTable: "calls", ascending: false }).order("id", { referencedTable: "calls" })
          .order("cancelled_at", { referencedTable: "cancelled_calls", ascending: false })
          .order("id", { referencedTable: "cancelled_calls" })
          .order("received_on", { referencedTable: "distributions", ascending: false })
          .order("id", { referencedTable: "distributions" })
          .order("settled_on", { referencedTable: "dispositions", ascending: false })
          .order("provider_event_at", { referencedTable: "dispositions", ascending: false })
          .order("id", { referencedTable: "dispositions" })
          .limit(101, { referencedTable: "marks" }).limit(101, { referencedTable: "calls" })
          .limit(100, { referencedTable: "cancelled_calls" })
          .limit(101, { referencedTable: "distributions" }).limit(101, { referencedTable: "dispositions" });
        if (error) throw error;
        return jsonResponse(200, {
          holdings: data.slice(0, pageSize),
          next_offset: data.length > pageSize ? offset + pageSize : null,
        });
      }
      case "applications": {
        const { data, error } = await admin.from("investment_commitments")
          .select("id,status,requested_amount,provider_application_amount,currency,provider,provider_reference,confirmed_at,cooling_off_ends_at,acknowledged_at," +
            "provider_received_at,withdrawal_requested_at,withdrawal_declined_at,withdrawn_at,provider_event_at," +
            "supplementary_notice_at,supplementary_withdrawal_ends_at,supplementary_document_url," +
            "offer:investment_opportunities(round:funding_rounds(stage,company:private_companies(name)))")
          .eq("user_id", userId).order("acknowledged_at", { ascending: false }).limit(100);
        if (error) throw error;
        return jsonResponse(200, { applications: data });
      }
      case "handoff_check":
      case "handoff": {
        const checking = body.action === "handoff_check";
        const currency = body.currency;
        if (typeof body.opportunity_id !== "string" || !uuid.test(body.opportunity_id) ||
          typeof body.amount !== "string" || !/^\d{1,16}(?:\.\d{1,4})?$/.test(body.amount) ||
          typeof body.document_url !== "string" || body.acknowledged !== true ||
          ((checking || currency !== undefined) && (typeof currency !== "string" || !/^[A-Z]{3}$/.test(currency)))) {
          return errorResponse(400, "INVALID_REQUEST", "Review the offer document and acknowledge the risks first.");
        }
        const session = sessionId(req);
        if (!session) return errorResponse(401, "UNAUTHENTICATED", "Sign in again to check this offer.");
        const active = await admin.rpc("account_deletion_session_active", { p_user: userId, p_session: session });
        if (active.error) throw active.error;
        if (!active.data) return errorResponse(401, "UNAUTHENTICATED", "Your session ended. Sign in again.");
        const args = {
          p_user: userId, p_opportunity: body.opportunity_id, p_amount: body.amount, p_document_url: body.document_url,
        };
        const { data, error } = checking
          ? await admin.rpc("check_private_handoff", { ...args, p_currency: currency })
          : currency === undefined ? await admin.rpc("prepare_private_handoff", args).single()
          : await admin.rpc("open_private_handoff", { ...args, p_currency: currency }).single();
        if (error) {
          const status = { "42501": 403, "22023": 422, "23505": 409 }[error.code];
          if (status) return errorResponse(status, "HANDOFF_UNAVAILABLE", error.message);
          throw error;
        }
        return jsonResponse(200, checking ? { ready: data === true } : data);
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
        return jsonResponse(200, publicReport((await savedReport(admin, userId, body.id)).report));
      }
      case "research_refresh": {
        if (typeof body.id !== "string" || !uuid.test(body.id)) return errorResponse(400, "INVALID_REQUEST", "Invalid report.");
        return jsonResponse(200, await researchRefresh(admin, userId, body.id));
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
        const { document_ids: documentIds, opportunity_ids: opportunityIds, announcement_ids: updateIds = [], question, mode } = body;
        if (!Array.isArray(documentIds) || !Array.isArray(opportunityIds) || !Array.isArray(updateIds)) {
          return errorResponse(400, "INVALID_RESEARCH", "Select one to three sources and enter a research question.");
        }
        const sourceIDs = [...documentIds, ...opportunityIds, ...updateIds];
        if (sourceIDs.length < 1 || sourceIDs.length > 3 ||
          sourceIDs.some((id) => typeof id !== "string" || !uuid.test(id)) ||
          new Set(sourceIDs.map((id: string) => id.toLowerCase())).size !== sourceIDs.length ||
          typeof question !== "string" || !question.trim() || question.length > 1_000 ||
          (mode !== "question" && mode !== "committee")) {
          return errorResponse(400, "INVALID_RESEARCH", "Select one to three sources and enter a research question.");
        }
        const ids = documentIds.map((id: string) => id.toLowerCase());
        const dealIDs = opportunityIds.map((id: string) => id.toLowerCase());
        const announcementIDs = updateIds.map((id: string) => id.toLowerCase());
        const previousId = body.previous_report_id;
        if (previousId !== undefined && (typeof previousId !== "string" || !uuid.test(previousId))) {
          return errorResponse(400, "INVALID_RESEARCH", "Invalid previous research report.");
        }
        const documentProvider = Deno.env.get("PRIVATE_MARKETS_DOCUMENT_AI_PROVIDER");
        const approvedProvider = documentProvider === "gemini" || documentProvider === "openai";
        if (ids.length && (body.ai_consent !== true || Deno.env.get("PRIVATE_MARKETS_DOCUMENT_AI_ENABLED") !== "true" ||
          !approvedProvider)) {
          return errorResponse(403, "DOCUMENT_AI_DISABLED", "Document analysis requires consent and an approved AI processing configuration.");
        }
        const keyring = await keys();
        const evidence: Evidence[] = [];
        const sources: ReportSource[] = [];
        const reportedFacts: ReportFactGroup[] = [];
        const companyIds = new Set<string>();
        const revisions: Record<string, string> = {};
        const baselines: Record<string, SourceBaseline> = {};
        const previous = typeof previousId === "string"
          ? reportSourceReferences((await savedReport(admin, userId, previousId.toLowerCase())).report) : undefined;
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
          const { data, error } = await catalogue(admin).in("id", dealIDs).returns<CatalogDeal[]>();
          if (error) throw error;
          if (data.length !== dealIDs.length) return errorResponse(404, "NOT_FOUND", "One or more published opportunities are unavailable.");
          const financialIssuers = new Set<string>();
          for (const deal of data) {
            revisions[deal.id] = await fundingRoundRevision(deal);
            baselines[deal.id] = fundingRoundBaseline(deal);
            companyIds.add(deal.round.company.id);
            const id = `O${sources.length + 1}`;
            const company = deal.round.company.name;
            const roundTitle = `${company} · ${deal.round.stage}`;
            const facts = roundFacts(deal);
            evidence.push({ id, title: roundTitle, text: dealEvidence(deal, facts) });
            sources.push({ id, title: roundTitle, url: deal.source_url });
            if (facts.length) reportedFacts.push({ source: id, title: roundTitle, entries: facts });
            if (deal.round.listing) {
              const { exchange, symbol, quotation_status, expected_offer_close_on, quotation_on, source_url, verified_at } = deal.round.listing;
              const id = `O${sources.length + 1}`;
              const title = `${company} listing milestone`;
              const quotationLabels = { proposed: "Proposed first quotation", anticipated: "Exchange-anticipated first quotation",
                listed: "Confirmed first quotation", withdrawn: "Listing application withdrawn" };
              const text = [
                `Exchange: ${exchange}; ${quotation_status === "listed" ? "Listed symbol" : "Proposed symbol"}: ${symbol}`,
                quotation_on ? `${quotationLabels[quotation_status]}: ${disclosureDate.format(new Date(quotation_on))}` : quotationLabels[quotation_status],
                expected_offer_close_on && `Expected offer close (date only): ${disclosureDate.format(new Date(expected_offer_close_on))}`,
                `Listing source verified: ${verified_at}`,
                "The listing milestone alone does not establish offer availability, investor eligibility, or a trading route.",
              ].filter(Boolean).join("\n");
              evidence.push({ id, title, text });
              sources.push({ id, title, url: source_url });
            }
            if (!financialIssuers.has(deal.round.company.id)) {
              financialIssuers.add(deal.round.company.id);
              const bySource = Map.groupBy(deal.round.company.financials.slice(0, 4), (record) => record.source_url);
              for (const [url, records] of bySource) {
                const id = `O${sources.length + 1}`;
                const title = `${company} financial disclosure`;
                const reported = disclosureDate.format(new Date(records[0].published_on));
                const facts = records.flatMap(financialFacts);
                const text = [`Company: ${company}`, `Disclosure published: ${reported}`,
                  ...facts.map(({ label, value }) => `${label} ${value}.`)].join("\n");
                evidence.push({ id, title, text });
                sources.push({ id, title, url });
                if (facts.length) reportedFacts.push({ source: id, title, entries: facts });
              }
            }
          }
        }
        if (announcementIDs.length) {
          const { data, error } = await publishedAnnouncements(admin).in("id", announcementIDs)
            .order("published_at", { ascending: false }).order("id")
            .returns<Announcement[]>();
          if (error) throw error;
          if (data.length !== announcementIDs.length) return errorResponse(404, "NOT_FOUND", "One or more published announcements are unavailable.");
          for (const item of data) {
            revisions[item.id] = await announcementRevision(item);
            baselines[item.id] = announcementBaseline(item);
            companyIds.add(item.company_id);
            const id = `O${sources.length + 1}`;
            const entry = announcementEvidence(item, id);
            evidence.push(entry);
            sources.push({ id, title: entry.title, url: item.source_url });
          }
        }
        const changes = sourceChangeEvidence(comparePublishedSources(previous?.baselines, baselines));
        if (changes) {
          const id = `O${sources.length + 1}`;
          const title = "Published changes since previous report";
          evidence.push({ id, title, text: changes });
          sources.push({ id, title });
        }
        const runId = crypto.randomUUID();
        const run = await admin.from("agent_analysis_runs").insert({ id: runId, user_id: userId, status: "running" });
        if (run.error) throw run.error;
        const research = async () => {
          try {
            await audit(ids.length ? "document_ai_consent" : "public_research_started", runId);
            const deps = aiDependencies(admin, ids.length && approvedProvider ? documentProvider : undefined);
            if (mode === "committee") deps.config.timeoutMs = 22_000;
            const researchQuestion = typeof previousId === "string" ?
              `${question.trim()}\nFor this update, distinguish published changes from new disclosures. Cite the comparison source when it supports a change. State when the evidence does not establish what changed.` : question;
            const report = await buildResearch(userId, researchQuestion, evidence, mode, deps);
            const source_refs: SourceReferences = { document_ids: ids, opportunity_ids: dealIDs,
              announcement_ids: announcementIDs, company_ids: [...companyIds], revisions, baselines };
            const payload = { ...report, id: runId, sources, source_refs, question, reported_facts: reportedFacts,
              previous_report_id: typeof previousId === "string" ? previousId.toLowerCase() : undefined,
              created_at: new Date().toISOString() };
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
        return jsonResponse(200, publicReport(await research()));
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
