// deno-lint-ignore no-import-prefix
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

Deno.test("committee can decode structured scenario assumptions without accepting absent scenarios", () => {
  const answer = { ...finding, scenarios: {
    bull: { assumption: "Demand increases.", outcome: "Revenue could rise." },
    base: "Demand is steady.",
    bear: "Demand weakens.",
  } };
  const committee = parseFinding(JSON.stringify(answer), "Committee", [source], true);
  assertEquals(committee.bull, "Demand increases. Revenue could rise.");
  assertEquals(committee.base, "Demand is steady.");
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
      assertEquals(body.response_format.type, "json_schema");
      assertEquals(body.response_format.json_schema.schema.required.includes("bull"), requests === 6);
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

Deno.test("scheduled summaries retry when an announcement lacks a verified citation", async () => {
  let requests = 0;
  const evidence = [
    { id: "O1", title: "Issuer announcement", text: "The issuer published its offer document." },
    { id: "O2", title: "Trading update", text: "The issuer updated its public financing statement." },
  ];
  const result = await buildResearch("11111111-1111-1111-1111-111111111111", "Summarise published announcements", evidence, "digest", {
    config: { openAIKey: "test" },
    quota: { consume: () => Promise.resolve({ allowed: true, used: requests + 1 }) },
    fetch: (_url, init) => {
      const body = JSON.parse(String(init?.body));
      const prompt = body.messages.filter((message: { role: string }) => message.role === "system")
        .map((message: { content: string }) => message.content).join("\n");
      assertEquals(prompt.includes("exactly one entry for each of these source IDs: O1, O2"), true);
      assertEquals(prompt.includes("return an empty evidence array"), false);
      const citations = evidence.slice(0, ++requests).map((source) => ({ source: source.id, line: 1 }));
      return Promise.resolve(Response.json({ choices: [{ message: { content: JSON.stringify({
        ...finding, analysis: "The issuers published financing information.", evidence: citations,
      }) } }] }));
    },
  });
  assertEquals(requests, 2);
  assertEquals(result.findings[0].evidence.map((citation) => citation.quote), evidence.map((source) => source.text));
});
