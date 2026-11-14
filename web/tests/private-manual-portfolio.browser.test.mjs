import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin, PRIVATE_MARKETS_TEST_CHROME: executablePath,
  PRIVATE_MARKETS_TEST_EMAIL: email, PRIVATE_MARKETS_TEST_PASSWORD: password,
  PRIVATE_MARKETS_OTHER_EMAIL: otherEmail, PRIVATE_MARKETS_OTHER_PASSWORD: otherPassword,
  PRIVATE_MANUAL_SNAPSHOT_FIXTURE: fixture, VERCEL_OIDC_TOKEN: previewToken,
} = process.env;
const previewHeaders = previewToken ? { "x-vercel-trusted-oidc-idp-token": previewToken } : {};

test("Published iPhone holdings are dated, owner-scoped, included in allocation and removable", {
  skip: !origin || !executablePath || !email || !password || !otherEmail || !otherPassword || !fixture,
  timeout: 120_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  const api = new URL("/api/workspace-service/private-markets", origin).href;
  const portfolio = "/private-markets?view=portfolio";

  async function signedIn(address, secret) {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    if (previewToken) await page.route(`${origin}/**`, (route) => route.continue({
      headers: { ...route.request().headers(), ...previewHeaders },
    }));
    await page.goto(new URL(`/login?next=${encodeURIComponent(portfolio)}`, origin).href);
    await page.getByLabel("Email", { exact: true }).fill(address);
    await page.getByLabel("Password", { exact: true }).fill(secret);
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await page.waitForURL(new URL(portfolio, origin).href);
    return page;
  }

  try {
    const page = await signedIn(email, password);
    const response = await page.request.post(api, { headers: previewHeaders, data: { action: "manual_portfolio" } });
    assert.equal(response.status(), 401);
    const holding = page.getByRole("heading", { name: fixture, exact: true }).locator("xpath=ancestor::article");
    await holding.getByText("Self-reported", { exact: true }).waitFor();
    await holding.getByText("AUD 2,400.1234", { exact: true }).waitFor();
    await holding.getByText("Stale valuation", { exact: true }).waitFor();
    await holding.getByText(/Statement value · Ownership statement/).waitFor();

    await page.goto(new URL("/portfolio", origin).href);
    const allocation = page.locator("#unified-allocation");
    await allocation.getByText("Startup equity", { exact: true }).waitFor();
    await allocation.getByText("1 of 1 private positions valued.", { exact: false }).waitFor();
    await page.goto(new URL(portfolio, origin).href);
    await holding.waitFor();

    const other = await signedIn(otherEmail, otherPassword);
    await other.getByText("Publish your current snapshot from My Private Portfolio on iPhone.", { exact: true }).waitFor();
    assert.equal(await other.getByRole("heading", { name: fixture, exact: true }).count(), 0);

    await page.getByRole("button", { name: "Remove web snapshot", exact: true }).click();
    await page.getByRole("button", { name: "Confirm removal", exact: true }).click();
    await page.getByText("Web snapshot removed.", { exact: true }).waitFor();
    await holding.waitFor({ state: "detached" });
    await page.reload();
    await page.getByText("Publish your current snapshot from My Private Portfolio on iPhone.", { exact: true }).waitFor();
  } finally {
    await browser.close();
  }
});
