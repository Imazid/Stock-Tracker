import { fromBase64, fromUtf8, utf8, type Bytes } from "../_shared/secure/encoding.ts";
import { HttpError, json, refusal } from "../_shared/server/http.ts";

const providers = ["birchal", "onmarket", "angellist", "syndex"];
const maxBytes = 12_288;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const timestamp = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$/;
const date = /^\d{4}-\d\d-\d\d$/;
const currency = /^[A-Z]{3}$/;
const status = /^(application_received|withdrawal_requested|withdrawal_declined|confirmed|withdrawn|rejected|supplementary_notice)$/;
const activity = /^(valuation|capital_call|capital_call_cancellation|distribution|distribution_reversal|opening_settlement)$/;
const money = /^\d{1,16}(?:\.\d{1,4})?$/;
const units = /^\d{1,17}(?:\.\d{1,8})?$/;
const text = (length: number) => new RegExp(`^[^\\u0000-\\u001F]{1,${length}}$`);
const verification = {
  jurisdiction: /^[A-Z]{2}$/, evidence_reference: text(500), verified_class: /^(retail|wholesale)$/,
  expires_at: timestamp, accountant_reviewed_at: timestamp,
};
const application = {
  commitment_id: uuid, reference: text(200), status, cooling_off_ends_at: timestamp, units,
  invested_amount: money, application_amount: money, application_currency: currency, supplementary_deadline: timestamp,
  supplementary_document_url: text(2048),
};
const holdingActivity = {
  holding_id: uuid, reference: text(200), currency, source: text(400), activity,
  amount: money, record_date: date, method: text(400), settled_on: date,
};
const holdingDisposition = {
  holding_id: uuid, reference: text(200), currency, source: text(400), reversed: null,
  settled_on: date, sold_units: units, net_proceeds: money, disposed_cost: money,
};

const shapes = {
  verification: { fields: verification, required: ["jurisdiction", "evidence_reference"] },
  application: { fields: application, required: ["commitment_id", "reference", "status"] },
  holding_activity: { fields: holdingActivity, required: ["holding_id", "reference", "currency", "source", "activity"] },
  holding_disposition: { fields: holdingDisposition, required: ["holding_id", "reference", "currency", "source", "reversed"] },
} satisfies Record<string, { fields: Record<string, RegExp | null>; required: string[] }>;
type Kind = keyof typeof shapes;

interface Delivery {
  p_provider: string;
  p_event_id: string;
  p_body_sha256: string;
  p_kind: Kind;
  p_subject: string;
  p_event_at: string;
  p_details: Record<string, unknown>;
}

interface DeliveryDependencies {
  key(provider: string, keyId: string): string | null;
  now(): number;
  accept(delivery: Delivery): Promise<unknown>;
}

const isObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const matches = (value: unknown, pattern: RegExp): value is string => typeof value === "string" && pattern.test(value);
const hex = (buffer: ArrayBuffer) => [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
const badEvent = () => new HttpError(400, "INVALID_PROVIDER_EVENT", "The provider event fields are invalid.");
const unauthorized = () => new HttpError(401, "INVALID_PROVIDER_SIGNATURE", "Provider signature verification failed.");

async function readBody(request: Request): Promise<Bytes> {
  const reader = request.body?.getReader();
  if (!reader) throw badEvent();
  const bytes = new Uint8Array(maxBytes);
  let offset = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) return bytes.subarray(0, offset);
      if (offset + value.length > maxBytes) {
        void reader.cancel().catch(() => {});
        throw new HttpError(413, "PROVIDER_EVENT_TOO_LARGE", "The provider event is too large.");
      }
      bytes.set(value, offset);
      offset += value.length;
    }
  } finally {
    reader.releaseLock();
  }
}

function parseEvent(bytes: Bytes): Omit<Delivery, "p_provider" | "p_body_sha256"> {
  let body: unknown;
  try { body = JSON.parse(fromUtf8(bytes)); } catch { throw badEvent(); }
  if (!isObject(body) || Object.keys(body).some((field) => !["event_id", "kind", "subject", "event_at", "details"].includes(field)) ||
    !matches(body.event_id, /^[a-zA-Z0-9_.:-]{1,160}$/) || !matches(body.subject, text(300)) ||
    body.subject.trim() !== body.subject || !matches(body.event_at, timestamp) ||
    typeof body.kind !== "string" || !Object.hasOwn(shapes, body.kind) || !isObject(body.details)) throw badEvent();
  const kind = body.kind as Kind;
  const shape = shapes[kind] as { fields: Record<string, RegExp | null>; required: string[] };
  const details = body.details;
  if (shape.required.some((field) => !Object.hasOwn(details, field) || details[field] === null) ||
      (kind === "verification" && !Object.hasOwn(details, "verified_class"))) throw badEvent();
  for (const [field, value] of Object.entries(details)) {
    if (!Object.hasOwn(shape.fields, field)) throw badEvent();
    if (value === null) continue;
    const pattern = shape.fields[field];
    if (pattern ? !matches(value, pattern) : typeof value !== "boolean") throw badEvent();
  }
  return { p_event_id: body.event_id, p_kind: kind, p_subject: body.subject, p_event_at: body.event_at, p_details: details };
}

export async function handleProviderDelivery(request: Request, deps: DeliveryDependencies): Promise<Response> {
  if (request.method !== "POST") return refusal(405, "METHOD_NOT_ALLOWED", "Use POST.");
  try {
    const provider = request.headers.get("x-stock-tracker-provider") ?? "";
    const keyId = request.headers.get("x-stock-tracker-key-id") ?? "";
    const sentAt = request.headers.get("x-stock-tracker-timestamp") ?? "";
    const signature = request.headers.get("x-stock-tracker-signature") ?? "";
    if (!providers.includes(provider) || !/^[a-zA-Z0-9_-]{1,64}$/.test(keyId) || !/^\d{10}$/.test(sentAt) ||
      Math.abs(deps.now() - Number(sentAt) * 1000) > 300_000 || !/^v1=[0-9a-f]{64}$/.test(signature)) throw unauthorized();
    const encoded = deps.key(provider, keyId);
    if (encoded === null) throw unauthorized();
    const keyBytes = fromBase64(encoded);
    if (keyBytes.length !== 32) throw new Error("Invalid key configuration");
    const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    const body = await readBody(request);
    const prefix = utf8(`stock-tracker-provider-events/v1\n${provider}\n${keyId}\n${sentAt}\n`);
    const signed = new Uint8Array(prefix.length + body.length);
    signed.set(prefix);
    signed.set(body, prefix.length);
    const supplied = Uint8Array.from(signature.slice(3).match(/../g) ?? [], (byte) => parseInt(byte, 16));
    if (!await crypto.subtle.verify("HMAC", key, supplied, signed)) throw unauthorized();
    const result = await deps.accept({
      ...parseEvent(body), p_provider: provider, p_body_sha256: hex(await crypto.subtle.digest("SHA-256", body)),
    });
    if (result !== "accepted" && result !== "duplicate") throw new Error("Unknown delivery result");
    return json(200, { status: result });
  } catch (error) {
    if (error instanceof HttpError) return refusal(error.status, error.code, error.message);
    const code = isObject(error) ? error.code : null;
    if (code === "42501") return refusal(403, "PROVIDER_EVENT_REFUSED", "The provider cannot update this record.");
    if (code === "23505") return refusal(409, "PROVIDER_EVENT_CONFLICT", "The delivery conflicts with an existing record.");
    if (code === "22023" || code === "22007" || code === "22008" || code === "22P02" || code === "22003" || code === "23514") {
      return refusal(422, "PROVIDER_EVENT_REJECTED", "The ledger rejected the event. Check the current provider record.");
    }
    return refusal(503, "PROVIDER_EVENT_UNAVAILABLE", "The provider event could not be confirmed. Retry with the same event ID and body.");
  }
}
