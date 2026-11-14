import { assertEquals } from "jsr:@std/assert@1";
import { type AlpacaOrderNotice, listenToAlpacaPaperOrders } from "../_shared/brokers/alpaca-paper-stream.ts";

class FixtureSocket {
  binaryType = "";
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((message: { data: unknown }) => void) | null = null;
  sent: unknown[] = [];
  closings = 0;

  send(frame: string) { this.sent.push(JSON.parse(frame)); }
  close() { this.closings++; }
  receive(frame: unknown, binary = false) {
    const text = JSON.stringify(frame);
    this.onmessage?.({ data: binary ? new TextEncoder().encode(text).buffer : text });
  }
  open(url: string) {
    assertEquals(url, "wss://paper-api.alpaca.markets/stream");
    return this as unknown as WebSocket;
  }
}

const creds = { provider: "alpaca", keyID: "paper-test-key", secretKey: "paper-test-secret" } as const;
const order = { id: "9f57eab5-3268-4f30-9b34-eace2e0c19c0", client_order_id: "st-verified-paper-intent-001", filled_qty: "10000" };
const frame = { stream: "trade_updates", data: { event: "partial_fill", order } };

Deno.test("paper order stream authenticates, requests updates and decodes only order references from binary frames", async () => {
  const socket = new FixtureSocket();
  const received: AlpacaOrderNotice[] = [];
  const window = new AbortController();
  const result = listenToAlpacaPaperOrders(creds, (notice) => received.push(notice), window.signal, (url) => socket.open(url));
  socket.onopen?.();
  socket.receive(frame, true);
  socket.receive({ stream: "authorization", data: { status: "authorized" } }, true);
  assertEquals(socket.sent, [
    { action: "auth", key: "paper-test-key", secret: "paper-test-secret" },
    { action: "listen", data: { streams: ["trade_updates"] } },
  ]);
  socket.receive(frame, true);
  assertEquals(received, []);
  socket.receive({ stream: "listening", data: { streams: ["trade_updates"] } }, true);
  socket.onmessage?.({ data: new Uint8Array([0xff, 0xff]).buffer });
  socket.receive({ ...frame, data: { order: { ...order, id: "foreign-invalid-id" } } });
  socket.receive({ ...frame, data: { order: { ...order, client_order_id: "wrong\nvalue" } } });
  socket.receive(frame, true);
  assertEquals(received, [{ providerOrderID: order.id, clientOrderID: order.client_order_id }]);
  window.abort();
  assertEquals(await result, "elapsed");
  assertEquals(socket.closings, 1);
  assertEquals(socket.onmessage, null);
});

Deno.test("paper order stream distinguishes authentication, missing subscription and connection errors", async () => {
  for (const [status, expected] of [["unauthorized", "unauthorized"], ["authorized", "protocol"]] as const) {
    const socket = new FixtureSocket();
    const result = listenToAlpacaPaperOrders(creds, () => {}, new AbortController().signal, (url) => socket.open(url));
    socket.onopen?.();
    socket.receive({ stream: "authorization", data: { status } });
    socket.receive({ stream: "listening", data: { streams: [] } });
    assertEquals(await result, expected);
    assertEquals(socket.closings, 1);
  }
  const socket = new FixtureSocket();
  const result = listenToAlpacaPaperOrders(creds, () => {}, new AbortController().signal, (url) => socket.open(url));
  socket.onerror?.();
  assertEquals(await result, "unavailable");
});
