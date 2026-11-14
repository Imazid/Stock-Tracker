// deno-lint-ignore no-import-prefix
import { assertEquals } from "jsr:@std/assert@1";
import { toBase64, utf8 } from "../_shared/secure/encoding.ts";
import { handleProviderDelivery } from "../private-provider-events/handler.ts";

const now = 1_800_000_000_000;
const sample = {
  event_id: "evt-settlement:1",
  kind: "application",
  subject: "opaque-provider-account",
  event_at: "2027-01-01T00:00:00.123456Z",
  details: {
    commitment_id: "01000000-0000-4000-8000-000000000001", reference: "receipt-1", status: "confirmed",
    units: "3.12345678", invested_amount: "500.4321",
  },
};
const rawKey = new Uint8Array(32).fill(11);
const key = await crypto.subtle.importKey("raw", rawKey, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);

async function request(body: string, provider = "birchal", seconds = "1800000000", changes: Record<string, string> = {}) {
  const keyId = "key-1";
  const bytes = utf8(`stock-tracker-provider-events/v1\n${provider}\n${keyId}\n${seconds}\n${body}`);
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, bytes));
  const signature = [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return new Request("https://example.test/private-provider-events", {
    method: "POST", headers: { "x-stock-tracker-provider": provider, "x-stock-tracker-key-id": keyId,
      "x-stock-tracker-timestamp": seconds, "x-stock-tracker-signature": "v1=" + signature, ...changes }, body,
  });
}

Deno.test("signed provider events preserve monetary precision and distinguish replays", async () => {
  let deliveries = 0;
  const deps: Parameters<typeof handleProviderDelivery>[1] = {
    key: (provider, id) => provider === "birchal" && id === "key-1" ? toBase64(rawKey) : null,
    now: () => now,
    accept: (entry) => {
      assertEquals(entry.p_provider, "birchal");
      assertEquals(entry.p_event_id, sample.event_id);
      assertEquals(entry.p_event_at, sample.event_at);
      assertEquals(entry.p_details, sample.details);
      assertEquals(entry.p_body_sha256.length, 64);
      return Promise.resolve(++deliveries === 1 ? "accepted" : "duplicate");
    },
  };
  for (const result of ["accepted", "duplicate"]) {
    const response = await handleProviderDelivery(await request(JSON.stringify(sample)), deps);
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { status: result });
  }
});

Deno.test("invalid signature, stale timestamp or substituted provider never reach the ledger", async () => {
  const delivery = JSON.stringify(sample);
  const deps = {
    key: () => toBase64(rawKey),
    now: () => now,
    accept: () => { throw new Error("Unexpected ledger access"); },
  };
  const invalid = [
    await request(delivery, "birchal", "1799999699"),
    await request(delivery, "birchal", "1800000301"),
    await request(delivery, "birchal", "1800000000", { "x-stock-tracker-provider": "onmarket" }),
    await request(delivery, "birchal", "1800000000", { "x-stock-tracker-key-id": "retired" }),
  ];
  const signed = await request(delivery);
  invalid.push(new Request(signed.url, { method: "POST", headers: signed.headers, body: delivery + " " }));
  for (const req of invalid) assertEquals((await handleProviderDelivery(req, deps)).status, 401);
});

Deno.test("unknown fields, a user ID, loose decimal values and oversized payloads are refused", async () => {
  const deps = {
    key: () => toBase64(rawKey),
    now: () => now,
    accept: () => { throw new Error("Unexpected ledger access"); },
  };
  for (const event of [
    { ...sample, provider: "onmarket" },
    { ...sample, details: { ...sample.details, user_id: sample.details.commitment_id } },
    { ...sample, details: { ...sample.details, invested_amount: 500.4321 } },
    { ...sample, details: { ...sample.details, units: "1.123456789" } },
    { ...sample, event_at: "now" },
  ]) assertEquals((await handleProviderDelivery(await request(JSON.stringify(event)), deps)).status, 400);
  assertEquals((await handleProviderDelivery(await request("x".repeat(12_289)), deps)).status, 413);
});

Deno.test("database rejection, ambiguity, and retryable failures have distinct responses", async () => {
  for (const [code, status] of [["42501", 403], ["23505", 409], ["22023", 422], ["XX001", 503]] as const) {
    const result = await handleProviderDelivery(await request(JSON.stringify(sample)), {
      key: () => toBase64(rawKey), now: () => now,
      accept: () => Promise.reject({ code, message: "private-info" }),
    });
    assertEquals(result.status, status);
    assertEquals((await result.text()).includes("private-info"), false);
  }
});
