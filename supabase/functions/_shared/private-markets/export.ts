import type { serviceClient } from "../secure/edge.ts";
import type { SealedSecret } from "../secure/envelope.ts";

const exportSections = {
  investor_profile: ["investor_profiles", "country,declared_class", "user_id"],
  eligibility: ["investor_eligibility",
    "provider,jurisdiction,verified_class,verified_at,expires_at,accountant_certificate_reviewed_at", "provider,jurisdiction"],
  provider_connections: ["provider_connections", "id,provider,revoked_at,verification_event_at", "id"],
  applications: ["investment_commitments",
    "id,opportunity_id,provider,jurisdiction,rule_version,reviewed_document_url,requested_amount::text," +
      "provider_application_amount::text,currency,acknowledged_at,status,provider_reference,provider_received_at," +
      "cooling_off_ends_at,retail_csf_cooling_off_required,confirmed_at,withdrawal_requested_at,withdrawal_declined_at," +
      "withdrawn_at,provider_event_at,supplementary_notice_at,supplementary_withdrawal_ends_at,supplementary_document_url", "id"],
  provider_holdings: ["private_holdings",
    "id,company_id,commitment_id,name,asset_class,currency,committed_amount::text,units::text,ownership_percent::text," +
      "settled_amount::text,confirmed_at,settled_on,settlement_source,remaining_units::text,last_disposition_on," +
      "disposition_revision_at,exit_source", "id"],
  valuations: ["valuation_history", "id,holding_id,value::text,valued_on,source,methodology,provider_reference,provider_event_at", "id"],
  capital_calls: ["capital_calls",
    "id,holding_id,amount::text,due_on,settled_on,source,provider_reference,provider_event_at,cancelled_at,cancellation_source", "id"],
  distributions: ["distributions",
    "id,holding_id,amount::text,received_on,source,provider_reference,provider_event_at,reversed_at,reversal_source", "id"],
  sales: ["private_holding_dispositions",
    "id,holding_id,provider_reference,provider_event_at,sold_units::text,net_proceeds::text,disposed_cost::text,settled_on,source,reversed", "id"],
  monitor_preferences: ["private_monitor_devices", "company_ids,eligible_opportunities,digest_enabled,refreshed_at", "device_id"],
  monitoring_alerts: ["private_market_alerts", "id,subject_id,kind,company_name,title,significance,source_url,source_label,occurred_at,revised_at", "id"],
  research_history: ["agent_analysis_runs", "id,report_id,status,created_at,failure_code,failure_message", "id"],
  excerpts: ["deal_documents", "id,title,created_at,sealed", "id"],
  reports: ["research_reports", "id,title,kind,created_at,sealed", "id"],
} as const;

type ExportSection = keyof typeof exportSections;
type ExportRow = Record<string, unknown>;

export function exportSection(value: unknown): ExportSection | null {
  return typeof value === "string" && Object.hasOwn(exportSections, value) ? value as ExportSection : null;
}

export function exportOffset(value: unknown): number | null {
  if (value === undefined) return 0;
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null;
}

export async function privateExportPage(
  admin: ReturnType<typeof serviceClient>, owner: string, section: ExportSection, offset: number,
  decrypt: (kind: "document" | "report", id: string, sealed: SealedSecret) => Promise<unknown>,
) {
  const [table, fields, order] = exportSections[section];
  const size = section === "reports" || section === "excerpts" ? 20 : 100;
  let query = admin.from(table).select(fields).eq("user_id", owner);
  for (const column of order.split(",")) query = query.order(column);
  const { data, error } = await query.range(offset, offset + size).returns<ExportRow[]>();
  if (error) throw error;
  const page = data.slice(0, size);
  const rows = section === "reports" || section === "excerpts"
    ? await Promise.all(page.map(async ({ sealed, ...record }) => ({
      ...record,
      [section === "reports" ? "report" : "excerpt"]: await decrypt(
        section === "reports" ? "report" : "document", String(record.id), sealed as SealedSecret,
      ),
    })))
    : page;
  return { records: rows, next_offset: data.length > size ? offset + size : null };
}
