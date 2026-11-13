type Provider = "SEC EDGAR" | "Financial Modeling Prep" | "Massive";

export class ResearchProviderError extends Error {
  readonly status?: number;

  constructor(provider: Provider, status?: number) {
    super(status ? `${provider} returned HTTP ${status}.` : `${provider} could not be reached.`);
    this.status = status;
  }
}

const lanes = new Map<Provider, number>();
const outages = new Map<Provider, { until: number; status?: number }>();
const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

export async function providerResponse(url: URL, provider: Provider, headers: Record<string, string>, minInterval: number): Promise<Response> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const now = Date.now();
    const outage = outages.get(provider);
    if (outage && outage.until > now) throw new ResearchProviderError(provider, outage.status);
    const slot = Math.max(now, lanes.get(provider) ?? 0);
    if (slot - now > 3000) throw new ResearchProviderError(provider, 429);
    lanes.set(provider, slot + minInterval);
    if (slot > now) await wait(slot - now);
    const paused = outages.get(provider);
    if (paused && paused.until > Date.now()) throw new ResearchProviderError(provider, paused.status);
    try {
      const response = await fetch(url, { headers: { Accept: "application/json", ...headers }, cache: "no-store", signal: AbortSignal.timeout(7500), redirect: "error" });
      if (!response.ok) {
        if (response.status === 429) {
          const retryAfter = response.headers.get("retry-after");
          const seconds = Number(retryAfter);
          const delay = retryAfter && Number.isFinite(seconds) ? seconds * 1000
            : retryAfter ? Date.parse(retryAfter) - Date.now() : NaN;
          outages.set(provider, { status: 429, until: Date.now() + Math.max(10_000, Number.isFinite(delay) ? delay : 30_000) });
        }
        void response.body?.cancel().catch(() => {});
        throw new ResearchProviderError(provider, response.status);
      }
      return response;
    } catch (error) {
      const status = error instanceof ResearchProviderError ? error.status : undefined;
      if (status === undefined || status >= 500) {
        if (attempt === 0) {
          await wait(350);
          continue;
        }
        outages.set(provider, { until: Date.now() + 15_000, status });
      }
      throw new ResearchProviderError(provider, status);
    }
  }
  throw new ResearchProviderError(provider);
}

export async function providerJSON(url: URL, provider: Provider, headers: Record<string, string>, minInterval: number): Promise<unknown> {
  const response = await providerResponse(url, provider, headers, minInterval);
  try {
    return await response.json();
  } catch {
    throw new ResearchProviderError(provider);
  }
}

export function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

export function asText(value: unknown, max = 240): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, max) : undefined;
}

export function asNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

export function safeUrl(value: unknown): string | undefined {
  if (typeof value !== "string" || value.length > 1200) return undefined;
  try {
    const url = new URL(value);
    if (url.protocol === "https:" && !url.username && !url.password) return url.href;
  } catch { /* A missing source link is handled by the caller. */ }
  return undefined;
}
