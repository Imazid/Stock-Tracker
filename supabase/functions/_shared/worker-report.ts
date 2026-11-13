import { logEvent } from "./server/http.ts";

export type FailureCode = "worker_error" | "database" | "provider_auth" | "provider_rate_limit" |
  "provider_unavailable" | "provider_response" | "provider_order" | "internal";

export type WorkerReport = {
  durationMs: number;
  jobs: number;
  errors: number;
  failureCodes: FailureCode[];
};

export function providerFailure(status: number | undefined, fallback: FailureCode): FailureCode {
  if (status === 401 || status === 403) return "provider_auth";
  if (status === 429) return "provider_rate_limit";
  if (status === 408 || (status !== undefined && status >= 500)) return "provider_unavailable";
  return fallback;
}

export async function reportWorker(
  worker: "provider-maintenance" | "snaptrade-activity-sync",
  started: number,
  run: Omit<WorkerReport, "durationMs">,
  persist: (report: WorkerReport) => Promise<void>,
) {
  try {
    await persist({ durationMs: Math.max(0, Math.round(performance.now() - started)), ...run });
  } catch {
    logEvent("worker_report_failed", { worker });
  }
}
