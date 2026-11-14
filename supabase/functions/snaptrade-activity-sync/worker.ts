import { handleSnapTradeRequest, listInvestmentAccounts, type SnapTradeProxyDeps } from "../_shared/snaptrade/proxy.ts";
import { logEvent } from "../_shared/server/http.ts";
import { type FailureCode, providerFailure } from "../_shared/worker-report.ts";

type SyncDatabase = {
  rpc(name: string, args?: Record<string, unknown>): PromiseLike<{ data: unknown; error: { code?: string } | null }>;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface Job {
  credential_id: string;
  user_id: string;
  lease_id: string;
  pending_id: string | null;
  start_date: string | null;
  end_date: string | null;
  account_id: string | null;
  page_offset: number;
}

class PageError extends Error {
  constructor(readonly reset: boolean, readonly code: FailureCode) { super("broker activity unavailable"); }
}

export async function syncSnapTradeActivities(admin: SyncDatabase, deps: SnapTradeProxyDeps, failures = new Set<FailureCode>()) {
  const { data, error } = await admin.rpc("claim_snaptrade_activity_jobs");
  if (error) throw new Error("Could not claim broker activity jobs");
  const jobs = data as Job[];
  const summary = { brokerActivityJobs: jobs.length, advanced: 0, errors: 0 };
  await Promise.all(jobs.map(async (job) => {
    const args = { p_credential: job.credential_id, p_lease: job.lease_id };
    try {
      let page;
      if (!job.pending_id) {
        const result = await listInvestmentAccounts(job.user_id, deps, false);
        if (result.status !== 200 || !Array.isArray(result.body)) {
          throw new PageError([400, 401, 403, 404, 409].includes(result.status),
            providerFailure(result.status, "provider_response"));
        }
        const ids = result.body.map((account) => account?.id);
        if (!ids.every((id) => typeof id === "string" && UUID.test(id))) throw new PageError(false, "provider_response");
        page = { p_accounts: [...new Set(ids.map((id: string) => id.toLowerCase()))] };
      } else {
        const result = await handleSnapTradeRequest(job.user_id, {
          operation: "accountActivities",
          params: { accountId: job.account_id, startDate: job.start_date, endDate: job.end_date, offset: job.page_offset },
        }, deps);
        if (result.status !== 200) {
          const body = result.body as { error?: { code?: string } };
          const reset = [400, 401, 403, 404, 409].includes(result.status) ||
            (job.page_offset > 0 && body.error?.code === "INVALID_ACTIVITY_RESPONSE");
          throw new PageError(reset, body.error?.code === "INVALID_ACTIVITY_RESPONSE"
            ? "provider_response" : providerFailure(result.status, "provider_response"));
        }
        const activity = result.body as { activities: unknown[]; omitted: number; nextOffset: number | null };
        page = { p_rows: activity.activities, p_omitted: activity.omitted, p_next_offset: activity.nextOffset };
      }
      const applied = await admin.rpc("advance_snaptrade_activity_job", { ...args, ...page });
      if (applied.error) throw new PageError(false, "database");
      if (applied.data === true) summary.advanced++;
    } catch (error) {
      const known = error instanceof PageError;
      failures.add(known ? error.code : "internal");
      const deferred = await admin.rpc("defer_snaptrade_activity_job", { ...args, p_reset: known && error.reset });
      summary.errors++;
      if (deferred.error) {
        failures.add("database");
        logEvent("snaptrade_activity_deferral_failed", { code: deferred.error.code });
      }
    }
  }));
  return summary;
}
