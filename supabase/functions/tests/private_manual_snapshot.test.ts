import { assertEquals } from "jsr:@std/assert@1";
import { validManualSnapshot } from "../_shared/private-markets/manual-snapshot.ts";

const holding = {
  id: "ed000000-0000-4000-8000-000000000010", name: "Owner-only holding", assetClass: "Startup equity",
  currency: "AUD", paid: "1000.1234", returned: "0", pendingCalls: "0", units: "200",
  valuation: { value: "950", date: "2026-01-01T00:00:00Z", source: "Ownership statement", method: "Management NAV" },
  unrealizedGain: "-50.1234",
};

Deno.test("manual portfolio snapshots accept precise amounts and decline data outside the snapshot schema", () => {
  assertEquals(validManualSnapshot([holding]), true);
  const ownershipEvidence = { excerptID: "ed000000-0000-4000-8000-000000000011", reviewedOn: "2026-01-01T00:00:00Z" };
  assertEquals(validManualSnapshot([{ ...holding, ownershipEvidence }]), true);
  for (const fields of [
    { units: 1.1 }, { ownership: "101" }, { pendingCalls: "-1" }, { currency: "au" }, { paid: "1e3" },
    { ownershipEvidenceID: holding.id }, { commitment: "12\n" }, { valuation: { ...holding.valuation, source: "" } },
    { valuation: { ...holding.valuation, date: "2999-01-01T00:00:00Z" } },
    { ownershipEvidence: { ...ownershipEvidence, excerpt: "Private document body" } },
    { ownershipEvidence: { ...ownershipEvidence, excerptID: "https://example.test/document" } },
    { ownershipEvidence: { ...ownershipEvidence, reviewedOn: "2999-01-01T00:00:00Z" } },
    { ownershipEvidence: { excerptID: ownershipEvidence.excerptID } },
  ]) {
    assertEquals(validManualSnapshot([{ ...holding, ...fields }]), false);
  }
  assertEquals(validManualSnapshot([holding, { ...holding, id: holding.id.toUpperCase() }]), false);
  assertEquals(validManualSnapshot([]), false);
});

Deno.test("manual publication keeps capital call history and protects the snapshot format", () => {
  const pending = { id: holding.id, status: "pending", amount: "500.4321", date: "2026-11-30", source: "Original call notice" };
  const cancelled = { ...pending, id: "ed000000-0000-4000-8000-000000000012", status: "cancelled",
    date: "2026-10-04", dueOn: pending.date, resolutionSource: "Cancellation notice" };
  const record = (capitalActivity: unknown) => validManualSnapshot([{ ...holding, capitalActivity }]);
  assertEquals(record([]), true);
  assertEquals(record([pending, cancelled]), true);
  assertEquals(record([{ ...cancelled, status: "paid" }]), true);
  assertEquals(record([{ ...pending, status: "paid" }]), true);
  assertEquals(record([{ ...pending, status: "distribution" }]), true);
  assertEquals(record([{ ...pending, status: "sale", amount: "0" }]), true);
  for (const malformed of [
    [{ ...pending, status: "provider-confirmed" }], [{ ...pending, date: "2026-02-29" }],
    [{ ...pending, dueOn: pending.date }], [{ ...pending, amount: 500.4321 }],
    [{ ...pending, detail: "Do not accept arbitrary fields" }], [pending, { ...pending, id: holding.id.toUpperCase() }],
    [{ ...cancelled, resolutionSource: undefined }], [{ ...cancelled, dueOn: undefined }],
    [{ ...cancelled, resolutionSource: " " }], { data: [pending] },
  ]) {
    assertEquals(record(malformed), false, JSON.stringify(malformed));
  }
});
