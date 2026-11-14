import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import postgres from "npm:postgres@3.4.5";
import type { Sql } from "../_shared/oms/store_pg.ts";
import { deliverProviderAlerts } from "../provider-maintenance/alert-delivery.ts";

const url = Deno.env.get("OMS_TEST_DB_URL");
const secret = "disposable-signing-key-for-provider-alert-tests";
const destination = "https://receiver.example.com/alerts";
const environment = (name: string) => name === "PROVIDER_ALERT_WEBHOOK_URL" ? destination
  : name === "PROVIDER_ALERT_WEBHOOK_SECRET" ? secret : undefined;

Deno.test({
  name: "pg: delivery leases, signed aggregate snapshots, ordered resolution, backoff, and recovery",
  ignore: !url,
  sanitizeOps: false,
  sanitizeResources: false,
}, async () => {
  const owner = postgres(url!, { max: 4, prepare: false });
  const sql: Sql = postgres(url!, { max: 1, prepare: false, connection: { application_name: "provider-alert-test" } });
  const competitor: Sql = postgres(url!, { max: 1, prepare: false, connection: { application_name: "provider-alert-competitor" } });
  const ids: string[] = [];
  const time = Date.now();
  const started = new Date(time - 1000);
  const signatureKey = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  try {
    await Promise.all([sql`set role service_role`, competitor`set role service_role`]);
    const [incident] = await owner`
      insert into provider_operations.alerts (condition, subject, observed_count, opened_at, last_seen_at)
      values ('worker_errors', 'alpaca-paper-order-stream', 3, ${started}, ${started}) returning id::text`;
    ids.push(incident.id);
    await owner`update provider_operations.alerts set resolved_at = now() where id = ${incident.id}`;
    await owner`update provider_operations.alert_deliveries set available_at = ${started} where alert_id = ${incident.id}`;
    await assertRejects(() => deliverProviderAlerts(sql, (key) => key.endsWith("URL") ? "http://receiver.example.com" : secret));
    assertEquals(await deliverProviderAlerts(sql, () => undefined), { configured: false, claimed: 0, delivered: 0, retrying: 0, failed: 0 });

    const received: { id: string; transition: string }[] = [];
    const send: typeof fetch = async (input, init) => {
      assertEquals(String(input), destination);
      assertEquals(init?.method, "POST");
      assertEquals(init?.redirect, "error");
      const headers = new Headers(init?.headers);
      const body = String(init?.body);
      const event = JSON.parse(body);
      assertEquals(Object.keys(event).sort(), ["condition", "eventId", "incidentId", "observedCount", "occurredAt", "schemaVersion", "subject", "transition"]);
      const timestamp = headers.get("X-Stock-Tracker-Timestamp");
      const mac = headers.get("X-Stock-Tracker-Signature")?.match(/^sha256=([a-f0-9]{64})$/)?.[1];
      assert(mac && timestamp);
      assert(await crypto.subtle.verify("HMAC", signatureKey,
        Uint8Array.from(mac.match(/.{2}/g)!, (hex) => parseInt(hex, 16)), new TextEncoder().encode(`${timestamp}.${body}`)));
      assertEquals(headers.get("Idempotency-Key"), event.eventId);
      assertEquals(event.eventId, `provider-alert:${incident.id}:${event.transition}`);
      assertEquals([event.incidentId, event.condition, event.subject, event.observedCount], [incident.id, "worker_errors", "alpaca-paper-order-stream", 3]);
      received.push({ id: event.eventId, transition: event.transition });
      if (received.length === 1) {
        assertEquals(event.occurredAt, started.toISOString());
        return new Response("temporary", { status: 429, headers: { "retry-after": "240" } });
      }
      return new Response(null, { status: 204 });
    };
    const runs = await Promise.all([
      deliverProviderAlerts(sql, environment, send, time),
      deliverProviderAlerts(competitor, environment, send, time),
    ]);
    assertEquals(runs.reduce((count, run) => count + run.claimed, 0), 1);
    assertEquals(runs.reduce((count, run) => count + run.retrying, 0), 1);
    assertEquals((await deliverProviderAlerts(sql, environment, send, time + 239_000)).claimed, 0);
    assertEquals((await deliverProviderAlerts(sql, environment, send, time + 240_000)).delivered, 1);
    assertEquals(received[0].id, received[1].id);
    assertEquals((await deliverProviderAlerts(sql, environment, send, time + 240_001)).delivered, 1);
    assertEquals(received.map((row) => row.transition), ["opened", "opened", "resolved"]);
    assertEquals((await deliverProviderAlerts(sql, environment, send, time + 400_000)).claimed, 0);

    const [fallen] = await owner`
      insert into provider_operations.alerts (condition, subject, observed_count, opened_at, last_seen_at)
      values ('worker_errors', 'snaptrade-activity-sync', 4, ${started}, ${started}) returning id::text`;
    ids.push(fallen.id);
    await owner`update provider_operations.alert_deliveries set attempts = 9, available_at = ${started}
      where alert_id = ${fallen.id}`;
    const networkError: typeof fetch = () => Promise.reject(Error("timeout"));
    assertEquals((await deliverProviderAlerts(sql, environment, networkError, time)).failed, 1);
    const [failure] = await owner`select attempts, last_failure, failed_at is not null as failed
      from provider_operations.alert_deliveries where alert_id = ${fallen.id}`;
    assertEquals({ ...failure }, { attempts: 10, last_failure: "network", failed: true });
    assertEquals((await deliverProviderAlerts(sql, environment, networkError, time + 60 * 60_000)).claimed, 0);
  } finally {
    if (ids.length) await owner`delete from provider_operations.alerts where id = any(${ids}::bigint[])`;
    await Promise.all([owner.end({ timeout: 5 }), sql.end({ timeout: 5 }), competitor.end({ timeout: 5 })]);
  }
});
