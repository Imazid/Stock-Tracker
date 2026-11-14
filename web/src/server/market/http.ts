// Upstream fetch with a deadline. Errors carry plain-English reasons that are safe to show:
// never a URL with a key in it, never a header.

export class UpstreamError extends Error {
  readonly status?: number;
  readonly throttled: boolean;

  constructor(message: string, status?: number, throttled = false) {
    super(message);
    this.name = "UpstreamError";
    this.status = status;
    this.throttled = throttled;
  }
}

// A bare generic agent. Measured 2026-11-13: Yahoo answered 429 to curl's agent, to no agent
// and to a full Safari string, and 200 to plain "Mozilla/5.0". Nothing identifying is sent.
const USER_AGENT = "Mozilla/5.0";

export async function getJSON(url: string, options: { headers?: Record<string, string>; timeoutMs?: number; label: string }): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? 8_000);
  let response: Response;
  try {
    response = await fetch(url, {
      headers: { "User-Agent": USER_AGENT, Accept: "application/json", ...options.headers },
      signal: controller.signal,
      cache: "no-store",
    });
  } catch (error) {
    const aborted = error instanceof Error && error.name === "AbortError";
    throw new UpstreamError(aborted ? `${options.label} didn't answer in time` : `${options.label} couldn't be reached`);
  } finally {
    clearTimeout(timer);
  }
  if (response.status === 429) throw new UpstreamError(`${options.label} is rate-limiting requests right now`, 429, true);
  if (response.status === 401 || response.status === 403) throw new UpstreamError(`${options.label} refused the request (${response.status})`, response.status);
  if (response.status === 404) throw new UpstreamError(`${options.label} has no data for that`, 404);
  if (!response.ok) throw new UpstreamError(`${options.label} answered ${response.status}`, response.status);
  try {
    return await response.json();
  } catch {
    throw new UpstreamError(`${options.label} sent a response that couldn't be read`);
  }
}
