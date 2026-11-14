import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { HttpError } from "../_shared/server/http.ts";
import { mobileResearchReport } from "../market-workspace/research_report.ts";

const origin = "https://workspace.example.com";
const payload = { instrumentId: "asx:BHP", asOf: "2026-11-14", coverage: [], facts: [], events: [] };

Deno.test("mobile company reports keep exact venue and the bypass server-side", async () => {
  const fetchReport = ((url: URL, options: RequestInit) => {
    assertEquals(url.href, origin + "/api/markets/instruments/asx%3ABHP/research/report");
    assertEquals(options.redirect, "error");
    assertEquals(new Headers(options.headers).get("x-vercel-protection-bypass"), "server-only");
    assertEquals(new Headers(options.headers).has("authorization"), false);
    return Promise.resolve(Response.json(payload));
  }) as typeof fetch;
  const response = await mobileResearchReport("asx:BHP", origin, "server-only", fetchReport);
  assertEquals(response.report, payload);
  assertEquals(response.dashboardURL, origin + "/markets/asx%3ABHP");
});

Deno.test("mobile reports refuse invalid listings, redirecting origins, missing configuration and mismatched responses", async () => {
  const refuse = (() => {
    throw new Error("The request must not be sent.");
  }) as typeof fetch;
  for (const listing of ["crypto:BTC", "asx:BHP:US", "us:../AAPL", "us:aapl"]) {
    const error = await assertRejects(() => mobileResearchReport(listing, origin, "server-only", refuse), HttpError);
    assertEquals(error.status, 422);
  }
  for (const url of ["http://workspace.example.com", "https://workspace.example.com/foo", "https://user@workspace.example.com"]) {
    const error = await assertRejects(() => mobileResearchReport("asx:BHP", url, "server-only", refuse), HttpError);
    assertEquals(error.status, 503);
  }
  const wrongListing = (() => Promise.resolve(Response.json({ ...payload, instrumentId: "us:BHP" }))) as typeof fetch;
  await assertRejects(() => mobileResearchReport("asx:BHP", origin, "server-only", wrongListing), HttpError);
  await assertRejects(() => mobileResearchReport("asx:BHP", origin, undefined, refuse), HttpError);
  const busy = (() => Promise.resolve(new Response(null, { status: 429 }))) as typeof fetch;
  const throttled = await assertRejects(() => mobileResearchReport("asx:BHP", origin, "server-only", busy), HttpError);
  assertEquals(throttled.status, 429);
});
