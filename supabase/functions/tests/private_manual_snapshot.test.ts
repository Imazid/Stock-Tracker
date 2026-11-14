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
  for (const fields of [
    { units: 1.1 }, { ownership: "101" }, { pendingCalls: "-1" }, { currency: "au" }, { paid: "1e3" },
    { ownershipEvidenceID: holding.id }, { commitment: "12\n" }, { valuation: { ...holding.valuation, source: "" } },
    { valuation: { ...holding.valuation, date: "2999-01-01T00:00:00Z" } },
  ]) {
    assertEquals(validManualSnapshot([{ ...holding, ...fields }]), false);
  }
  assertEquals(validManualSnapshot([holding, { ...holding, id: holding.id.toUpperCase() }]), false);
  assertEquals(validManualSnapshot([]), false);
});
