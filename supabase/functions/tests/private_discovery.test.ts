// deno-lint-ignore no-import-prefix
import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { type Discoverable, interpretDiscovery, matchDiscovery, parseDiscovery } from "../_shared/private-markets/discovery.ts";
import { ResearchError } from "../_shared/private-markets/research.ts";

const filters = {
  countries: ["AU"], investor_jurisdictions: [], sectors: ["Healthcare technology"], stages: [], categories: [], statuses: ["open"],
  eligibility: ["retail"], providers: [], company: "", currency: "", max_minimum: 0, max_valuation: 0,
  min_raise_target: 0, max_raise_target: 0,
  disclosed_traction: false, unsupported: [],
};
const now = Date.parse("2026-11-14T00:00:00Z");
const recent = "2026-11-13T23:00:00Z";
const round = {
  verified_at: recent, stage: "Series C", closes_at: "2026-11-14T04:00:00Z", currency: "AUD", valuation: null, target: null,
  traction: null, company: { name: "Example", country: "AU", sector: "Healthcare technology" },
};
const deal: Discoverable = {
  category: "Crowdfunding", status: "open", eligibility: "retail", provider: "birchal", jurisdictions: ["AU"],
  minimum: null, verified_at: recent, round,
};

Deno.test("discovery filters published records by verified availability and explicit eligibility", () => {
  assertEquals(matchDiscovery([
    deal,
    { ...deal, eligibility: "provider review" },
    { ...deal, status: "interest" },
    { ...deal, status: "closed" },
    { ...deal, verified_at: "2026-11-12T22:00:00Z" },
    { ...deal, verified_at: "2026-11-14T01:00:00Z" },
    { ...deal, round: { ...round, verified_at: "2026-11-12T22:00:00Z" } },
    { ...deal, round: { ...round, closes_at: "2026-11-13T23:00:00Z" } },
    { ...deal, round: { ...round, closes_at: null } },
    { ...deal, round: { ...round, company: { ...round.company, sector: "Biotechnology" } } },
  ], parseDiscovery(JSON.stringify(filters)), now), [deal]);
});

Deno.test("specific stage filters distinguish closed financing rounds in the same category", () => {
  const seriesC = { ...deal, status: "closed", category: "Series B or later" };
  const seriesD = { ...seriesC, round: { ...round, stage: "Series D" } };
  assertEquals(matchDiscovery([seriesC, seriesD], parseDiscovery(JSON.stringify({
    ...filters, stages: ["Series C"], statuses: ["closed"], categories: ["Series B or later"],
  })), now), [seriesC]);
});

Deno.test("enumerating every status keeps availability unrestricted", () => {
  const unverified = { ...deal, status: "unverified" };
  const criteria = parseDiscovery(JSON.stringify({ ...filters, statuses: ["open", "interest", "closed", "unverified"] }));
  assertEquals(criteria.statuses, []);
  assertEquals(matchDiscovery([deal, unverified], criteria, now), [deal, unverified]);
});

Deno.test("discovery rejects malformed filter output and never assumes currency or unknown amounts", () => {
  for (const field of [{ statuses: ["definitely open"] }, { countries: ["Australia"] }, { currency: null }, { max_valuation: -1 }]) {
    assertThrows(() => parseDiscovery(JSON.stringify({ ...filters, ...field })), ResearchError);
  }
  const unclear = parseDiscovery(JSON.stringify({ ...filters, max_minimum: 1000 }));
  assertEquals(matchDiscovery([{ ...deal, minimum: 100 }], unclear, now), []);
  const priced = parseDiscovery(JSON.stringify({ ...filters, currency: "AUD", max_minimum: 1000 }));
  const qualifying = { ...deal, minimum: 100 };
  assertEquals(matchDiscovery([deal, qualifying, { ...deal, minimum: 1200 }], priced, now), [qualifying]);
});

Deno.test("disclosed traction matches structured company financials and narrative disclosures", () => {
  const financials = { ...deal, round: { ...round, company: { ...round.company, financials: [{ revenue: 1200 }] } } };
  const narrative = { ...deal, round: { ...round, traction: "A published operating update" } };
  assertEquals(matchDiscovery([deal, financials, narrative], { ...filters, disclosed_traction: true }, now), [financials, narrative]);
});

Deno.test("the investor country and original-currency raise range use disclosed offer terms", () => {
  const qualifying = { ...deal, round: { ...round, target: 1_000_000 } };
  const criteria = { ...filters, investor_jurisdictions: ["AU"], currency: "AUD",
    min_raise_target: 1_000_000, max_raise_target: 3_000_000 };
  const candidates = [
    qualifying, deal, { ...qualifying, jurisdictions: [] }, { ...qualifying, jurisdictions: ["NZ"] },
    { ...qualifying, round: { ...qualifying.round, currency: "USD" } },
    { ...qualifying, round: { ...qualifying.round, target: 3_000_001 } },
    { ...qualifying, round: { ...qualifying.round, target: 999_999 } },
    { ...qualifying, round: { ...qualifying.round, company: { ...round.company, country: "NZ" } } },
    { ...qualifying, eligibility: "wholesale" },
  ];
  assertEquals(matchDiscovery(candidates, parseDiscovery(JSON.stringify(criteria)), now), [qualifying]);
  assertEquals(matchDiscovery(candidates, parseDiscovery(JSON.stringify({ ...criteria, currency: "" })), now), []);
  assertEquals(matchDiscovery(candidates, parseDiscovery(JSON.stringify({ ...criteria, max_raise_target: 500 })), now), []);
  assertThrows(() => parseDiscovery(JSON.stringify({ ...criteria, investor_jurisdictions: ["Australia"] })), ResearchError);
});

Deno.test("discovery asks the model for filters and enforces the shared AI quota", async () => {
  let charges = 0;
  const criteria = await interpretDiscovery("11111111-1111-1111-1111-111111111111",
    "Australian healthcare startups raising for retail", ["Healthcare technology"], {
      config: { openAIKey: "test" },
      quota: { consume: () => Promise.resolve({ allowed: true, used: ++charges }) },
      fetch: (_url, init) => {
        const request = JSON.parse(String(init?.body));
        assertEquals(request.response_format.json_schema.schema.required.includes("statuses"), true);
        assertEquals(JSON.parse(request.messages.at(-1).content).known_sectors, ["Healthcare technology"]);
        return Promise.resolve(Response.json({ choices: [{ message: { content: JSON.stringify(filters) } }] }));
      },
    });
  assertEquals(criteria.statuses, ["open"]);
  assertEquals(criteria.eligibility, ["retail"]);
  assertEquals(charges, 1);
});
