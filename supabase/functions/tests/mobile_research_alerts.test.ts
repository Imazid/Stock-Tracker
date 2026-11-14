import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { HttpError } from "../_shared/server/http.ts";
import { mobileCompanyAlerts } from "../market-workspace/research_alerts.ts";

const origin = "https://workspace.example.com";
const bearer = "Bearer session";
const bypass = "server-only";
const instrumentId = "asx:BHP";
const inbox = { alerts: [], events: [], availableKinds: ["price_above"], monitoring: true };

Deno.test("mobile alerts reuse listing rules and forward only their caller's token and permitted fields", async () => {
  const id = "9a82ae83-d16e-4068-a04d-236ba5ff2383";
  const operations = [
    { operation: "read", method: "GET", response: inbox },
    { operation: "create", method: "POST", input: { kind: "price_above", threshold: 42.5 }, response: { ok: true } },
    { operation: "remove", method: "DELETE", input: { id }, response: { ok: true } },
  ];
  for (const { operation, method, input, response } of operations) {
    const relay = ((url: URL, options: RequestInit) => {
      assertEquals(url.href, origin + "/api/markets/instruments/asx%3ABHP/research/alerts");
      assertEquals(options.method, method);
      assertEquals(options.redirect, "error");
      assertEquals(new Headers(options.headers).get("Authorization"), bearer);
      assertEquals(new Headers(options.headers).get("x-vercel-protection-bypass"), bypass);
      assertEquals(options.body ? JSON.parse(String(options.body)) : undefined, input);
      return Promise.resolve(Response.json(response));
    }) as typeof fetch;
    assertEquals(await mobileCompanyAlerts({
      instrumentId, operation, ...input, userId: "another account", currency: "USD", origin: "https://other.example",
    }, bearer, origin, bypass, relay), response);
  }
});

Deno.test("mobile alerts reject invalid requests and relay the scheduler's rule validation", async () => {
  const denied = (() => {
    throw new Error("The request should not reach the web app.");
  }) as typeof fetch;
  for (const body of [
    { instrumentId: "crypto:BTC", operation: "read" },
    { instrumentId, operation: "create", kind: "price_above", threshold: "42.50" },
    { instrumentId, operation: "remove", id: "someone-else" },
  ]) {
    const error = await assertRejects(() => mobileCompanyAlerts(body, bearer, origin, bypass, denied), HttpError);
    assertEquals(error.status === 400 || error.status === 422, true);
  }
  const action = { instrumentId, operation: "read" };
  const unsafe = await assertRejects(() => mobileCompanyAlerts(action, bearer, "http://workspace.example.com", bypass, denied), HttpError);
  assertEquals(unsafe.code, "alerts_unavailable");
  const duplicate = (() => Promise.resolve(Response.json({
    error: { code: "duplicate", message: "This alert already exists." },
  }, { status: 409 }))) as typeof fetch;
  const rejection = await assertRejects(() => mobileCompanyAlerts(action, bearer, origin, bypass, duplicate), HttpError);
  assertEquals(rejection.status, 409);
  assertEquals(rejection.code, "duplicate");
  const badResponse = (() => Promise.resolve(Response.json({ alerts: [] }))) as typeof fetch;
  const malformed = await assertRejects(() => mobileCompanyAlerts(action, bearer, origin, bypass, badResponse), HttpError);
  assertEquals(malformed.code, "alerts_unavailable");
});
