import type { ProviderCredentials } from "./types.ts";

const PAPER_STREAM = "wss://paper-api.alpaca.markets/stream";
const MAX_FRAME_BYTES = 65_536;
const decoder = new TextDecoder("utf-8", { fatal: true });

type Credentials = Extract<ProviderCredentials, { provider: "alpaca" }>;

export interface AlpacaOrderNotice {
  providerOrderID: string;
  clientOrderID: string;
}

export type AlpacaStreamEnd = "elapsed" | "closed" | "unauthorized" | "protocol" | "unavailable";

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

// Read order references only. Broker prices, quantities and states are confirmed through REST.
export function listenToAlpacaPaperOrders(
  credentials: Credentials,
  onOrder: (notice: AlpacaOrderNotice) => void,
  signal: AbortSignal,
  connect: (url: string) => WebSocket = (url) => new WebSocket(url),
): Promise<AlpacaStreamEnd> {
  if (signal.aborted) return Promise.resolve("elapsed");
  return new Promise((resolve) => {
    let socket: WebSocket;
    try {
      socket = connect(PAPER_STREAM);
    } catch {
      resolve("unavailable");
      return;
    }

    socket.binaryType = "arraybuffer";
    let phase: "connecting" | "authorizing" | "listening" | "ready" = "connecting";
    let finished = false;
    const handshake = setTimeout(() => finish("unavailable"), 8_000);
    const abort = () => finish(phase === "ready" ? "elapsed" : "unavailable");
    function finish(result: AlpacaStreamEnd) {
      if (finished) return;
      finished = true;
      clearTimeout(handshake);
      signal.removeEventListener("abort", abort);
      socket.onopen = socket.onmessage = socket.onerror = socket.onclose = null;
      try { socket.close(); } catch { /* the connection can already be closed */ }
      resolve(result);
    }

    signal.addEventListener("abort", abort, { once: true });
    socket.onerror = () => finish("unavailable");
    socket.onclose = () => finish(phase === "ready" ? "closed" : "unavailable");
    socket.onopen = () => {
      phase = "authorizing";
      try {
        socket.send(JSON.stringify({ action: "auth", key: credentials.keyID, secret: credentials.secretKey }));
      } catch { finish("unavailable"); }
    };
    socket.onmessage = ({ data }: MessageEvent) => {
      try {
        const text = data instanceof ArrayBuffer
          ? data.byteLength <= MAX_FRAME_BYTES ? decoder.decode(data) : ""
          : typeof data === "string" && data.length <= MAX_FRAME_BYTES ? data : "";
        if (!text) return;
        const message = record(JSON.parse(text));
        const payload = record(message.data);
        if (message.stream === "authorization") {
          if (payload.status === "unauthorized") {
            finish("unauthorized");
          } else if (phase === "authorizing" && payload.status === "authorized") {
            phase = "listening";
            try {
              socket.send(JSON.stringify({ action: "listen", data: { streams: ["trade_updates"] } }));
            } catch { finish("unavailable"); }
          }
        } else if (message.stream === "listening" && phase === "listening") {
          if (!Array.isArray(payload.streams) || !payload.streams.includes("trade_updates")) {
            finish("protocol");
          } else {
            phase = "ready";
            clearTimeout(handshake);
          }
        } else if (message.action === "error") {
          finish("unavailable");
        } else if (phase === "ready" && message.stream === "trade_updates") {
          const order = record(payload.order);
          if (typeof order.id === "string" && /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(order.id) &&
              typeof order.client_order_id === "string" && /^[a-zA-Z0-9-]{8,48}$/.test(order.client_order_id)) {
            onOrder({ providerOrderID: order.id, clientOrderID: order.client_order_id });
          }
        }
      } catch {
        // A malformed frame carries no usable order reference. The next frame can still be valid.
      }
    };
  });
}
