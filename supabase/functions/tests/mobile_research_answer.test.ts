import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { AiProxyDeps } from "../_shared/ai/proxy.ts";
import { HttpError } from "../_shared/server/http.ts";
import { answerCompanyQuestion } from "../market-workspace/research_answer.ts";
import { mobileResearchReport } from "../market-workspace/research_report.ts";

const user = "12345678-1234-1234-1234-123456789012";
const listing = "us:AAPL";
const filing = { provider: "SEC", license: "public_filing", url: "https://www.sec.gov/filing", publishedAt: "2026-11-03" };
const report = {
  instrumentId: listing, asOf: "2026-11-14", coverage: [],
  facts: [{ label: "Net sales", unit: "USD", end: "2026-09-26", value: 478834000000, evidence: filing }],
  events: [{ title: "Licensed headline text", date: "2026-11-12", evidence: { ...filing, license: "licensed" } }],
};

Deno.test("company questions require consent before obtaining evidence or consuming AI quota", async () => {
  const forbidden = () => { throw new Error("No external work is allowed"); };
  const error = await assertRejects(
    () => answerCompanyQuestion(user, listing, { question: "What were net sales?" }, forbidden, {
      config: { openAIKey: "test" }, fetch: forbidden, quota: { consume: forbidden },
    }),
    HttpError,
  );
  assertEquals(error.code, "research_consent");
});

Deno.test("the AI gets public facts only and its citation resolves to the original filing", async () => {
  let calls = 0;
  const response = await answerCompanyQuestion(user, listing, {
    consent: true, question: "What were net sales?", holdings: "private context supplied by caller",
  }, () => Promise.resolve(report), {
    config: { openAIKey: "test" },
    quota: { consume: () => Promise.resolve({ allowed: true, used: 1 }) },
    fetch: ((_url, init) => {
      calls++;
      const payload = String(init?.body);
      assert(payload.includes("Net sales"));
      assert(!payload.includes("Licensed headline text") && !payload.includes("private context") && !payload.includes(user));
      assert(!payload.includes(filing.url));
      return Promise.resolve(Response.json({ choices: [{ message: { content: JSON.stringify({
        analysis: "The filing reports net sales for the fiscal year.", confidence: "high",
        evidence: [{ source: "O1", line: 1 }], missing: [], questions: [],
      }) } }] }));
    }) as typeof fetch,
  });
  assertEquals(calls, 1);
  assertEquals(response.instrumentId, listing);
  assertEquals(response.citations[0].url, filing.url);
  assert(response.citations[0].excerpt.includes("478834000000 USD"));
});

Deno.test("the company question refuses invented evidence even after a model retry", async () => {
  const deps: AiProxyDeps = {
    config: { openAIKey: "test" }, quota: { consume: () => Promise.resolve({ allowed: true, used: 1 }) },
    fetch: (() => Promise.resolve(Response.json({ choices: [{ message: { content: JSON.stringify({
      analysis: "Unsupported.", confidence: "high", evidence: [{ source: "O77", line: 1 }], missing: [], questions: [],
    }) } }] }))) as typeof fetch,
  };
  const error = await assertRejects(
    () => answerCompanyQuestion(user, listing, { consent: true, question: "Net sales?" }, () => Promise.resolve(report), deps),
    HttpError,
  );
  assertEquals(error.code, "INVALID_RESEARCH");
});

Deno.test("mobile report bridge can request public evidence while preserving deployment protection", async () => {
  const request = ((url: URL, init: RequestInit) => {
    assertEquals(url.searchParams.get("publicOnly"), "true");
    assertEquals(new Headers(init.headers).has("authorization"), false);
    return Promise.resolve(Response.json(report));
  }) as typeof fetch;
  const result = await mobileResearchReport(listing, "https://reports.example.com", "server-only", request, true);
  assertEquals(new URL(result.dashboardURL).search, "");
});
