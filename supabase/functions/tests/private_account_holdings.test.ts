import { assertEquals } from "jsr:@std/assert@1";
import { accountHolding, accountValuations, withAccountValuations } from "../_shared/private-markets/account-holdings.ts";

const now = new Date("2026-11-14T14:05:00Z"); // 15 November in Sydney.
const input = {
  id: "ed000000-0000-4000-8000-000000000010", name: "Self-reported venture fund", assetClass: "Venture fund", currency: "AUD",
  units: "0.12345678", ownership: "0.5", excerptID: "ed000000-0000-4000-8000-000000000011",
  valuation: { value: "1200.4321", date: "2026-11-15T00:00:00Z", source: "Fund statement", method: "Reported NAV" },
};

Deno.test("web holdings use the Sydney calendar and retain precise self-reported values", () => {
  const result = accountHolding(input, now);
  assertEquals(result?.valuation, input.valuation);
  assertEquals(result?.paid, "0");
  assertEquals(result?.returned, "0");
  assertEquals(result?.ownershipEvidence, { excerptID: input.excerptID, reviewedOn: "2026-11-14T14:05:00Z" });
  assertEquals(accountHolding({ ...input, valuation: { ...input.valuation, date: "2026-11-16T00:00:00Z" } }, now), null);
});

Deno.test("web holdings reject foreign fields, incorrect dates and invalid decimals", () => {
  for (const extra of [
    { user_id: input.id }, { provider_verified: true }, { paid: "500" }, { xirr: "2" }, { units: 0.5 },
    { ownership: "110" }, { valuation: { ...input.valuation, date: "2026-02-29T00:00:00Z" } },
    { ownershipEvidence: { excerptID: input.excerptID } }, { excerptID: "https://example.test" },
  ]) assertEquals(accountHolding({ ...input, ...extra }, now), null);
});

Deno.test("an account retains earlier valuations and uses the newest date independently of write order", () => {
  const latest = input.valuation;
  const earlier = { ...latest, date: "2026-10-01T00:00:00Z", value: "1000.123456789", source: "Prior statement" };
  const legacy = { valuation: latest };
  assertEquals(accountValuations(legacy), [latest]);
  const legacyWithTime = { valuation: { ...earlier, date: "2026-09-30T17:00:00Z" } };
  assertEquals(accountValuations(legacyWithTime), [earlier]);
  const backfilled = withAccountValuations(legacy, accountValuations(legacy), earlier);
  assertEquals(backfilled.valuation, latest);
  assertEquals(backfilled.valuationHistory, [latest, earlier]);
  const revised = { ...earlier, value: "1050.123456789" };
  const corrected = withAccountValuations(backfilled, accountValuations(backfilled), revised);
  assertEquals(corrected.valuationHistory, [latest, revised]);
  const removed = withAccountValuations(corrected, accountValuations(corrected), latest.date);
  assertEquals(removed.valuation, revised);
  assertEquals(withAccountValuations(removed, accountValuations(removed), earlier.date).valuation, undefined);
});
