import assert from "node:assert/strict";
import test from "node:test";
import type { QuoteView } from "../../lib/market-types.ts";
import { evaluateQuoteAlert } from "./alert-observation.ts";

const now = Date.parse("2026-11-15T15:10:00Z");
const observedAt = "2026-11-15T15:09:00Z";
const quote: QuoteView = { instrumentId: "us:AAPL", last: 210, volume: 3_000, volumeScope: "single_venue",
  currency: "USD", observedAt, fetchedAt: observedAt, source: "Example quote", status: "delayed", stale: false, notes: [] };
const rule = { instrument_id: "us:AAPL", kind: "price_above" as const, currency: "USD", threshold: 200,
  created_at: "2026-11-15T15:00:00Z", last_condition: null, last_observed_at: null };

test("records a qualifying price with its original observation time and source", () => {
  const result = evaluateQuoteAlert(rule, quote, now);
  assert.equal(result.condition, true);
  assert.equal(result.observedAt, observedAt);
  assert.deepEqual(result.events, [{ event_key: "price_above:" + observedAt,
    title: "AAPL price reached 210 USD (Example quote, delayed)", occurred_at: observedAt }]);
  assert.equal(evaluateQuoteAlert({ ...rule, last_condition: true }, quote, now).events.length, 0);
  assert.equal(evaluateQuoteAlert({ ...rule, kind: "price_below" }, quote, now).condition, false);
});

test("rejects older, future, stale, mismatched and non-finite observations", () => {
  for (const rejected of [{ currency: "AUD" }, { instrumentId: "asx:AAPL" }, { last: Infinity }, { stale: true },
    { observedAt: "2026-11-15T15:10:01Z" }, { observedAt: "no date" }]) {
    const evaluated = evaluateQuoteAlert(rule, { ...quote, ...rejected }, now);
    assert.equal(evaluated.condition, null);
    assert.ok(evaluated.problem);
  }
  assert.equal(evaluateQuoteAlert({ ...rule, created_at: "2026-11-15T15:10:00Z" }, quote, now).condition, null);
  assert.equal(evaluateQuoteAlert({ ...rule, last_observed_at: observedAt }, quote, now).condition, null);
});

test("volume rules require consolidated coverage and accept a genuine zero observation", () => {
  const volume = { ...rule, kind: "volume_above" as const, threshold: 2_000 };
  assert.ok(evaluateQuoteAlert(volume, quote, now).problem);
  assert.equal(evaluateQuoteAlert(volume, { ...quote, volumeScope: "consolidated" }, now).events.length, 1);
  assert.equal(evaluateQuoteAlert(volume, { ...quote, volume: 0, volumeScope: "consolidated" }, now).condition, false);
});
