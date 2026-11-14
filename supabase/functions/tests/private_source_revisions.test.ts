// deno-lint-ignore no-import-prefix
import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { announcementRevision, changedSourceIds, fundingRoundRevision } from "../_shared/private-markets/source-revisions.ts";

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
  assertNotEquals(await fundingRoundRevision(corrected), revision);
  assertEquals(await changedSourceIds([corrected], { round: revision }, fundingRoundRevision), ["round"]);
  assertEquals(await changedSourceIds([], { round: revision }, fundingRoundRevision), []);
  assertEquals(await changedSourceIds([corrected], undefined, fundingRoundRevision), []);
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
