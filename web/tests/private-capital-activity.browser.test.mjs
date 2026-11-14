import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin, PRIVATE_MARKETS_TEST_CHROME: executablePath,
  PRIVATE_MARKETS_TEST_EMAIL: email, PRIVATE_MARKETS_TEST_PASSWORD: password,
  PRIVATE_MARKETS_OTHER_EMAIL: otherEmail, PRIVATE_MARKETS_OTHER_PASSWORD: otherPassword,
  PRIVATE_MARKETS_TEST_CAPITAL_ACTIVITY: capitalFixture, VERCEL_OIDC_TOKEN: previewToken,
} = process.env;
const previewHeaders = previewToken ? { "x-vercel-trusted-oidc-idp-token": previewToken } : {};

test("Capital activity shows owner-scoped outstanding calls and paginated posted history", {
  skip: !origin || !executablePath || !email || !password || !otherEmail || !otherPassword || capitalFixture !== "true",
  timeout: 120_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  const api = new URL("/api/workspace-service/private-markets", origin).href;
  const capital = new URL("/private-markets?view=capital", origin).href;
  const isCapitalCall = (request) => request.url() === api && request.postDataJSON()?.action === "capital_activity";
  const row = (page, text) => page.getByText(text, { exact: true }).locator("xpath=ancestor::li");

  async function signedOut() {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    if (previewToken) await page.route(`${origin}/**`, (route) => route.continue({
      headers: { ...route.request().headers(), ...previewHeaders },
    }));
    await page.goto(capital);
    await page.getByText("Sign in to see your capital activity", { exact: true }).waitFor();
    return page;
  }

  async function signIn(page, address, secret) {
    await page.getByRole("link", { name: "Sign in", exact: true }).last().click();
    await page.getByLabel("Email", { exact: true }).fill(address);
    await page.getByLabel("Password", { exact: true }).fill(secret);
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await page.waitForURL(capital);
    await page.getByRole("heading", { name: "Capital Activity", exact: true }).waitFor();
  }

  try {
    const page = await signedOut();
    const anonymous = await page.request.post(api, { headers: previewHeaders, data: { action: "capital_activity", section: "calls" } });
    assert.equal(anonymous.status(), 401);
    assert.equal(anonymous.headers()["cache-control"], "no-store");
    const first = page.waitForRequest(isCapitalCall);
    await signIn(page, email, password);
    const { authorization } = await (await first).allHeaders();

    await row(page, "Overdue statement").getByText("Overdue", { exact: true }).waitFor();
    await row(page, "Overdue statement").getByText("AUD 250,001.2345", { exact: true }).waitFor();
    await row(page, "Upcoming notice").getByText("Upcoming", { exact: true }).waitFor();
    await row(page, "Paid receipt").getByText("Paid", { exact: true }).waitFor();
    await row(page, "Cancelled notice").getByText("Cancelled", { exact: true }).waitFor();
    const paid = page.getByText("USD 515.1250", { exact: true }).locator("xpath=ancestor::li");
    await paid.getByText("Distribution", { exact: true }).waitFor();
    assert.match(await paid.getByRole("link", { name: "Read provider source" }).getAttribute("href"), /^https:\/\//);
    const sale = row(page, "Settled sale receipt");
    await sale.getByText("Settled sale", { exact: true }).waitFor();
    await sale.getByText("AUD 900,719,925,474,099.1234", { exact: true }).waitFor();
    assert.equal(await page.getByText("Reversed fixture", { exact: true }).count(), 0);
    assert.equal(await page.getByText("Future fixture", { exact: true }).count(), 0);
    assert.equal(await page.getByText("Reversed sale fixture", { exact: true }).count(), 0);

    await page.getByRole("button", { name: "Load more activity" }).click();
    await row(page, "Archive statement 29").getByText("Distribution", { exact: true }).waitFor();
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

    const spoofed = await page.request.post(api, {
      headers: { ...previewHeaders, authorization },
      data: { action: "capital_activity", section: "calls", owner: "another account" },
    });
    assert.equal(spoofed.status(), 400);
    const other = await signedOut();
    const otherCapitalRequest = other.waitForRequest(isCapitalCall);
    await signIn(other, otherEmail, otherPassword);
    await other.getByText("No outstanding capital calls", { exact: true }).waitFor();
    await other.getByText("No confirmed capital activity", { exact: true }).waitFor();

    await page.goto(new URL("/private-markets?view=portfolio", origin).href);
    const holding = page.getByRole("article").filter({ has: page.getByRole("heading", { name: "Australian fund fixture", exact: true }) });
    const requestedHistory = page.waitForRequest((request) => request.url() === api && request.postDataJSON()?.action === "valuation_history");
    await holding.getByText("Valuation history", { exact: true }).click();
    const historyRequest = await requestedHistory;
    const { authorization: otherAuthorization } = await (await otherCapitalRequest).allHeaders();
    const current = holding.getByText(/Current NAV/).locator("xpath=ancestor::li");
    await current.getByText("Used for carrying value", { exact: true }).waitFor();
    const historical = holding.getByText("AUD 900,719,925,474,099.2345", { exact: true }).locator("xpath=ancestor::li");
    await historical.getByRole("link", { name: "Read valuation source", exact: true }).waitFor();
    assert.equal(await historical.getByText("Used for carrying value", { exact: true }).count(), 0);
    assert.equal(await holding.getByText(/Future valuation fixture/).count(), 0);
    await holding.getByRole("button", { name: "Load older valuations", exact: true }).click();
    await holding.getByText(/Archived NAV 35/).waitFor();
    assert.match(await historical.getByRole("link", { name: "Read valuation source", exact: true }).getAttribute("href"), /^https:\/\//);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
    assert.ok(otherAuthorization);
    const another = await other.request.post(api, {
      headers: { ...previewHeaders, authorization: otherAuthorization }, data: historyRequest.postDataJSON(),
    });
    assert.equal(another.status(), 200);
    assert.deepEqual(await another.json(), { items: [], next_offset: null });
  } finally {
    await browser.close();
  }
});
