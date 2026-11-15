// deno-lint-ignore no-import-prefix
import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import {
  announcementBaseline, announcementRevision, changedSourceIds, comparePublishedSources, fundingRoundBaseline,
  fundingRoundRevision, sourceChangeEvidence,
} from "../_shared/private-markets/source-revisions.ts";

Deno.test("funding revisions detect corrected terms and ignore verification-only changes and share ordering", async () => {
  const common = { name: "Common", rights: "One vote" };
  const preferred = { name: "Preferred", rights: "Priority" };
  const original = { id: "round", status: "closed", verified_at: "2026-09-21",
    round: { valuation: 150, share_classes: [common, preferred], company: { verified_at: "2026-09-21", name: "Issuer" } } };
  const reverified = { ...original, verified_at: "2026-11-14", round: { ...original.round,
    share_classes: [preferred, common], company: { name: "Issuer", verified_at: "2026-11-14" } } };
  const corrected = { ...reverified, round: { ...reverified.round, valuation: 175 } };
  const revision = await fundingRoundRevision(original);
  assertEquals(await fundingRoundRevision(reverified), revision);
  assertEquals(await fundingRoundRevision({ ...original, round: {
    ...original.round, financing_structure: null, capital_commitments: null,
    secondary_purchase_amount: null, secondary_closed_on: null,
  } }), revision);
  assertNotEquals(await fundingRoundRevision(corrected), revision);
  assertEquals(await changedSourceIds([corrected], { round: revision }, fundingRoundRevision), ["round"]);
  assertEquals(await changedSourceIds([], { round: revision }, fundingRoundRevision), []);
  assertEquals(await changedSourceIds([corrected], undefined, fundingRoundRevision), []);
});

Deno.test("fund commitment corrections stay distinct from equity pricing in source baselines", async () => {
  const original = {
    id: "fund", status: "closed", minimum: null, eligibility: "provider review", jurisdictions: [],
    round: { stage: "Fund VII", currency: "AUD", valuation: null, valuation_method: null, raised: null,
      target: null, closes_at: null, company: { name: "Manager" }, share_classes: [],
      financing_structure: "fund" as const, capital_commitments: 1_000 },
  };
  const corrected = { ...original, round: { ...original.round, capital_commitments: 1_200 } };
  assertNotEquals(await fundingRoundRevision(original), await fundingRoundRevision(corrected));
  const saved = fundingRoundBaseline(original);
  assertEquals(saved.fields["Disclosed valuation"], null);
  assertEquals(saved.fields["Capital raised"], null);
  assertEquals(comparePublishedSources({ fund: saved }, { fund: fundingRoundBaseline(corrected) }), [{
    source_id: "fund", title: "Manager · Fund VII",
    fields: [{ field: "Capital commitments", previous: "AUD 1000", current: "AUD 1200" }],
  }]);
});

Deno.test("saved public baselines compare changed terms while excluding missing and unselected sources", () => {
  const saved = { round: fundingRoundBaseline({
    status: "closed", minimum: null, eligibility: "wholesale", jurisdictions: ["AU"],
    round: { stage: "Series B", currency: "AUD", valuation: null, valuation_method: null,
      raised: 10, target: null, closes_at: null, company: { name: "Issuer" } },
  }), notice: announcementBaseline({ company_name: "Issuer", title: "Notice", significance: "Previous summary" }) };
  const current = { round: { ...saved.round, fields: { ...saved.round.fields, "Disclosed valuation": "AUD 500" } },
    another: announcementBaseline({ company_name: "Issuer", title: "New", significance: "Newly published" }) };
  const changes = comparePublishedSources(saved, current);
  assertEquals(changes, [{ source_id: "round", title: "Issuer · Series B",
    fields: [{ field: "Disclosed valuation", previous: null, current: "AUD 500" }] }]);
  assertEquals(sourceChangeEvidence(changes), "Issuer · Series B · Disclosed valuation: previously Undisclosed; currently AUD 500.");
  assertEquals(comparePublishedSources(undefined, current), []);
  assertEquals(comparePublishedSources(saved, saved), []);
});

Deno.test("announcement revisions mark a same-id correction without treating a new source as revised", async () => {
  const original = { id: "original", title: "Company notice", company_name: "Issuer", significance: "Old terms",
    published_at: "2026-11-13T00:00:00Z", source_url: "https://example.test/notice" };
  const saved = { original: await announcementRevision(original) };
  const corrected = { ...original, significance: "Revised terms" };
  const newer = { ...corrected, id: "new", published_at: "2026-11-14T00:00:00Z" };
  assertEquals(await announcementRevision({ ...original, published_at: "2026-11-13T00:00:00+00:00" }), saved.original);
  assertEquals(await changedSourceIds([original, newer], saved, announcementRevision), []);
  assertEquals(await changedSourceIds([corrected, newer], saved, announcementRevision), ["original"]);
});
