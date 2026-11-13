// Fetch JSON from our own route handlers; errors keep the server's machine-readable code.

export class ApiError extends Error {
  constructor(readonly code: string, message: string, readonly status: number, readonly details?: Record<string, unknown>) {
    super(message);
    this.name = "ApiError";
  }
}

export async function getJSON<T>(path: string, signal?: AbortSignal): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, { signal, headers: { Accept: "application/json" } });
  } catch (error) {
    if (error instanceof Error && error.name === "AbortError") throw error;
    throw new ApiError("network", "Couldn't reach the server. Check your connection.", 0);
  }
  const body = (await response.json().catch(() => undefined)) as { error?: { code: string; message: string; details?: Record<string, unknown> } } | undefined;
  if (!response.ok || body?.error) {
    throw new ApiError(body?.error?.code ?? "http_error", body?.error?.message ?? `Request failed (${response.status})`, response.status, body?.error?.details);
  }
  return body as T;
}
