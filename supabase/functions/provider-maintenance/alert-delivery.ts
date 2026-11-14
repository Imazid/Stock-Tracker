import type { Sql } from "../_shared/oms/store_pg.ts";

type ReadEnv = (name: string) => string | undefined;
type AlertDelivery = {
  alert_id: string;
  transition: "opened" | "resolved";
  occurred_at: Date;
  condition: string;
  subject: string;
  observed_count: number;
  attempts: number;
};

type Receipt = { ok: true } | { ok: false; failure: "http" | "network"; status: number | null; retryAfter?: string | null };
const maxAttempts = 10;
const timeoutMs = 6_000;
const leaseMs = 45_000;

function configuration(env: ReadEnv) {
  const destination = env("PROVIDER_ALERT_WEBHOOK_URL")?.trim();
  const secret = env("PROVIDER_ALERT_WEBHOOK_SECRET");
  if (!destination && !secret) return;
  if (!destination || !secret || new TextEncoder().encode(secret).length < 32) throw Error("invalid_alert_webhook_configuration");
  const url = new URL(destination);
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password || url.hash) {
    throw Error("invalid_alert_webhook_configuration");
  }
  return { url, secret };
}

function retryDelay(attempt: number, retryAfter: string | null | undefined, now: number): number {
  const scheduled = Math.min(60 * 60_000, 60_000 * 2 ** (attempt - 1));
  if (!retryAfter) return scheduled;
  const requested = /^\d+$/.test(retryAfter) ? Number(retryAfter) * 1000 : Date.parse(retryAfter) - now;
  return Number.isFinite(requested) ? Math.max(scheduled, Math.min(requested, 60 * 60_000)) : scheduled;
}

async function signature(key: CryptoKey, timestamp: string, body: string): Promise<string> {
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${body}`)));
  return `sha256=${Array.from(mac, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

async function send(row: AlertDelivery, url: URL, key: CryptoKey, request: typeof fetch, now: number): Promise<Receipt> {
  const eventID = `provider-alert:${row.alert_id}:${row.transition}`;
  const body = JSON.stringify({
    schemaVersion: 1,
    eventId: eventID,
    incidentId: row.alert_id,
    transition: row.transition,
    occurredAt: row.occurred_at.toISOString(),
    condition: row.condition,
    subject: row.subject,
    observedCount: row.observed_count,
  });
  const timestamp = String(Math.floor(now / 1000));
  const mac = await signature(key, timestamp, body);
  try {
    const reply = await request(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Idempotency-Key": eventID,
        "X-Stock-Tracker-Timestamp": timestamp,
        "X-Stock-Tracker-Signature": mac,
      },
      body, redirect: "error", signal: AbortSignal.timeout(timeoutMs),
    });
    const retryAfter = reply.headers.get("retry-after");
    await reply.body?.cancel().catch(() => {});
    if (reply.ok) return { ok: true };
    return { ok: false, failure: "http", status: reply.status, retryAfter };
  } catch {
    return { ok: false, failure: "network", status: null };
  }
}

export async function deliverProviderAlerts(sql: Sql, env: ReadEnv, request: typeof fetch = fetch, now = Date.now()) {
  const target = configuration(env);
  if (!target) return { configured: false, claimed: 0, delivered: 0, retrying: 0, failed: 0 };
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(target.secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const token = crypto.randomUUID();
  const rows = await sql<AlertDelivery[]>`
    with due as (
      select delivery.alert_id, delivery.transition from provider_operations.alert_deliveries delivery
      where delivery.delivered_at is null and delivery.failed_at is null and delivery.available_at <= ${new Date(now)}
        and (delivery.transition = 'opened' or exists (
          select 1 from provider_operations.alert_deliveries opened
          where opened.alert_id = delivery.alert_id and opened.transition = 'opened' and opened.delivered_at is not null
        ))
      order by delivery.available_at, delivery.alert_id, delivery.transition
      limit 12 for update of delivery skip locked
    )
    update provider_operations.alert_deliveries delivery
    set available_at = ${new Date(now + leaseMs)}, lease_token = ${token}
    from due where delivery.alert_id = due.alert_id and delivery.transition = due.transition
    returning delivery.alert_id::text, delivery.transition, delivery.occurred_at,
      delivery.condition, delivery.subject, delivery.observed_count, delivery.attempts`;

  const result = { configured: true, claimed: rows.length, delivered: 0, retrying: 0, failed: 0 };
  await Promise.all(rows.map(async (row) => {
    const reply = await send(row, target.url, key, request, now);
    const attempts = row.attempts + 1;
    const exhausted = !reply.ok && attempts >= maxAttempts;
    const updated = await sql`
      update provider_operations.alert_deliveries
      set lease_token = null,
        attempts = ${attempts},
        available_at = ${new Date(reply.ok || exhausted ? now : now + retryDelay(attempts, reply.retryAfter, now))},
        delivered_at = ${reply.ok ? new Date(now) : null},
        failed_at = ${exhausted ? new Date(now) : null},
        last_failure = ${reply.ok ? null : reply.failure},
        last_http_status = ${reply.ok ? null : reply.status}
      where alert_id = ${row.alert_id}::bigint and transition = ${row.transition} and lease_token = ${token}
      returning alert_id`;
    if (updated.length) result[reply.ok ? "delivered" : exhausted ? "failed" : "retrying"]++;
  }));
  return result;
}
