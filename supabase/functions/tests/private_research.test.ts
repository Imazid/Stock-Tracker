import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { buildResearch, parseFinding, ResearchError } from "../_shared/private-markets/research.ts";

const source = { id: "D1", title: "Statement", text: "Cash on hand was A$400,000 as of June." };
const finding = {
  analysis: "The statement gives a June cash balance.",
  confidence: "high",
  evidence: [{ source: "D1", quote: "Cash on hand was A$400,000 as of June." }],
  missing: ["Monthly burn rate"],
  questions: ["What is the monthly burn?"],
};

Deno.test("research rejects invented source IDs, quotes, and incomplete committee reports", () => {
  for (const evidence of [
    [{ source: "D2", quote: source.text }],
    [{ source: "D1", quote: "Cash on hand was A$900,000 as of June." }],
  ]) {
    assertThrows(() => parseFinding(JSON.stringify({ ...finding, evidence }), "Financial", [source]), ResearchError);
  }
  assertThrows(() => parseFinding(JSON.stringify(finding), "Committee", [source], true), ResearchError);
  assertThrows(() => parseFinding(JSON.stringify({ ...finding, analysis: "Cash was A$900,000." }), "Financial", [source]), ResearchError);
});

Deno.test("research downgrades confidence where evidence is missing", () => {
  assertEquals(parseFinding(JSON.stringify({ ...finding, evidence: [] }), "Financial", [source]).confidence, "low");
});

Deno.test("numbered sources are resolved and a uniquely supported amount adds a citation", () => {
  const funds = { id: "O1", title: "Round", text: "Company: Example\nRaised: AUD 750000" };
  const answer = { ...finding, analysis: "The company raised A$750,000 (O1).", confidence: "High",
    evidence: [{ source: "O1", line: 1 }] };
  const checked = parseFinding(JSON.stringify(answer), "Financial", [funds]);
  assertEquals(checked.analysis, "The company raised A$750,000.");
  assertEquals(checked.evidence.map((item) => item.quote), ["Company: Example", "Raised: AUD 750000"]);
  assertThrows(() => parseFinding(JSON.stringify({ ...answer, analysis: "Raised A$850,000" }), "Financial", [funds]), ResearchError);
});

Deno.test("committee requests each role, synthesizes validated reviews and charges shared quota", async () => {
  let requests = 0;
  let charges = 0;
  const result = await buildResearch("11111111-1111-1111-1111-111111111111", "Review the opportunity", [source], "committee", {
    config: { openAIKey: "test" },
    quota: { consume: () => Promise.resolve({ allowed: true, used: ++charges }) },
    fetch: (_url, init) => {
      requests++;
      const body = JSON.parse(String(init?.body));
      assertEquals(body.messages.some((message: { role: string; content: string }) =>
        message.role === "system" && message.content.includes(source.text)), false);
      const scenarios = { bull: "Demand expands", base: "Demand is steady", bear: "Demand contracts" };
      return Promise.resolve(Response.json({ choices: [{ message: { content: JSON.stringify({ ...finding, ...scenarios }) } }] }));
    },
  });
  assertEquals(result.findings.length, 5);
  assertEquals(result.committee?.bear, "Demand contracts");
  assertEquals(requests, 6);
  assertEquals(charges, 6);
});

Deno.test("provider failure is returned without generating a fake report", async () => {
  await assertRejects(() => buildResearch("11111111-1111-1111-1111-111111111111", "Review it", [source], "question", {
    config: { openAIKey: "test" },
    quota: { consume: () => Promise.resolve({ allowed: true, used: 1 }) },
    fetch: () => Promise.resolve(new Response(null, { status: 503 })),
  }), ResearchError, "unavailable");
});
