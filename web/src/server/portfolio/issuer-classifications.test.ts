import assert from "node:assert/strict";
import test from "node:test";
import type { SecListing } from "../research/sec.ts";
import { incorporationCountry, issuerClassifications, operatingSector } from "./issuer-classifications.ts";

test("uses SEC incorporation codes and groups operating SIC codes into divisions", () => {
  assert.equal(incorporationCountry("CA"), "United States");
  assert.equal(incorporationCountry("A6"), "Canada");
  assert.equal(incorporationCountry("C3"), "Australia");
  assert.equal(incorporationCountry("2M"), "Germany");
  assert.equal(incorporationCountry("F5"), "Taiwan");
  assert.equal(incorporationCountry("XX"), undefined);
  assert.equal(operatingSector("3674"), "Manufacturing");
  assert.equal(operatingSector("6021"), "Finance, insurance and real estate");
  assert.equal(operatingSector("0131"), "Agriculture, forestry and fishing");
  assert.equal(operatingSector("6770"), undefined);
  assert.equal(operatingSector("36740"), undefined);
});

test("keeps dated entries when a live lookup fails and skips ambiguous listings and funds", async () => {
  const listings: SecListing[] = [
    { cik: "0000000001", symbol: "BRK-B", name: "Operating issuer", exchange: "NYSE" },
    { cik: "0000000002", symbol: "AMBIG", name: "Issuer A", exchange: "NYSE" },
    { cik: "0000000003", symbol: "AMBIG", name: "Issuer B", exchange: "Nasdaq" },
    { cik: "0000000004", symbol: "FAILED", name: "Unavailable issuer", exchange: "NYSE" },
    { cik: "0000000005", symbol: "FUND", name: "Investment company", exchange: "NYSE" },
  ];
  const fetched: string[] = [];
  const result = await issuerClassifications(
    ["us:BRK.B", "us:BRK.B", "us:AMBIG", "us:FAILED", "us:FUND", "asx:BRK.B", "us:TSM"],
    {
      configured: () => true,
      directory: async () => listings,
      submissions: async ({ name, symbol, cik, exchange }) => {
        fetched.push(symbol);
        if (symbol === "FAILED") throw new Error("Upstream unavailable");
        return {
          profile: { name, cik, exchange, sic: "6021", incorporationCode: "DE", evidence: {
            provider: "SEC EDGAR", license: "public_filing", url: `https://data.sec.gov/submissions/CIK${cik}.json`,
            retrievedAt: "2026-11-13T00:00:00Z",
          } },
          entityType: symbol === "FUND" ? "investmentcompany" : "operating",
          events: [],
          archives: [],
        };
      },
    },
  );
  assert.deepEqual(fetched.sort(), ["BRK-B", "FAILED", "FUND"]);
  assert.deepEqual(Object.keys(result.issuers).sort(), ["us:BRK.B", "us:TSM"]);
  assert.equal(result.issuers["us:TSM"].country, "Taiwan");
  assert.equal(result.issuers["us:TSM"].evidence.filedOn, "2026-04-16");
  assert.equal(result.issuers["us:BRK.B"].country, "United States");
  assert.equal(result.limited, true);
});
