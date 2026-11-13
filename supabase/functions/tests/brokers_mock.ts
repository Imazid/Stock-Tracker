// A scripted `fetch` for the broker adapter tests. No test in this suite touches the network:
// each expected request is answered by the next handler in the queue, and every call is
// recorded so a test can assert exactly what was sent (and how many times).

export interface RecordedCall {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: unknown;
}

export type Handler = (call: RecordedCall, signal: AbortSignal | undefined) => Response | Promise<Response>;

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(body === undefined ? null : JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

/** Never answers; rejects with an AbortError when the request is aborted (a timeout). */
export const hang: Handler = (_call, signal) =>
  new Promise<Response>((_resolve, reject) => {
    signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
  });

export const networkError: Handler = () => Promise.reject(new TypeError("connection reset"));

export class MockFetch {
  readonly calls: RecordedCall[] = [];
  private readonly queue: Handler[];

  constructor(...handlers: Handler[]) {
    this.queue = [...handlers];
  }

  readonly fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const headers: Record<string, string> = {};
    new Headers(init?.headers).forEach((value, key) => (headers[key] = value));
    const call: RecordedCall = {
      url: String(input),
      method: init?.method ?? "GET",
      headers,
      body: typeof init?.body === "string" ? JSON.parse(init.body) : undefined,
    };
    this.calls.push(call);
    const handler = this.queue.shift();
    if (!handler) throw new Error(`unexpected request: ${call.method} ${call.url}`);
    return await handler(call, init?.signal ?? undefined);
  };

  get remaining(): number {
    return this.queue.length;
  }
}

export const respond = (status: number, body: unknown, headers: Record<string, string> = {}): Handler => () => json(status, body, headers);
