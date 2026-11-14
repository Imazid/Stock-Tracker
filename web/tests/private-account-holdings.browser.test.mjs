import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin, PRIVATE_MARKETS_TEST_CHROME: executablePath,
  PRIVATE_MARKETS_TEST_EMAIL: email, PRIVATE_MARKETS_TEST_PASSWORD: password,
  PRIVATE_MARKETS_OTHER_EMAIL: otherEmail, PRIVATE_MARKETS_OTHER_PASSWORD: otherPassword,
  PRIVATE_ACCOUNT_HOLDING_PREFIX: prefix, PRIVATE_ACCOUNT_EXCERPT_TITLE: excerptTitle,
  PRIVATE_ACCOUNT_EXCERPT_TEXT: excerptText, VERCEL_OIDC_TOKEN: previewToken,
} = process.env;

test("manual web holdings appear in portfolio with account-scoped evidence", {
  skip: !origin || !executablePath || !email || !password || !otherEmail || !otherPassword || !prefix,
  timeout: 120_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  const portfolio = "/private-markets?view=portfolio";
  const name = prefix + " venture fund";
  async function signedIn(address, secret) {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    if (previewToken) await page.route(`${origin}/**`, (route) => route.continue({
      headers: { ...route.request().headers(), "x-vercel-trusted-oidc-idp-token": previewToken },
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
    await page.getByRole("button", { name: "Add private holding", exact: true }).click();
    await page.getByLabel("Company or fund name").fill(name);
    await page.getByLabel("Asset class").selectOption("Venture fund");
    await page.getByLabel("Shares or units").fill("0.12345678");
    await page.getByLabel("Ownership percentage").fill("0.5");
    await page.getByLabel("Committed capital").fill("1400");
    await page.getByLabel("Carrying value").fill("1200.4321");
    await page.getByLabel("Valuation date").fill("2026-06-01");
    await page.getByLabel("Valuation source").fill("June statement");
    await page.getByLabel("Valuation method").fill("Fund-reported NAV");
    if (excerptTitle && excerptText) {
      await page.getByLabel("Deal Room ownership excerpt").selectOption({ label: excerptTitle });
      await page.getByRole("button", { name: "Save holding", exact: true }).click();
      await page.getByText("Confirm you reviewed the selected ownership excerpt.").waitFor();
      await page.getByLabel("I reviewed the selected excerpt.").check();
    }
    await page.getByRole("button", { name: "Save holding", exact: true }).click();
    const article = page.getByRole("article").filter({ has: page.getByRole("heading", { name, exact: true }) });
    await article.getByText("AUD 1,200.4321", { exact: true }).waitFor();
    await article.getByText("0.12345678", { exact: true }).waitFor();
    if (excerptText) {
      await article.getByRole("button", { name: "Open ownership excerpt", exact: true }).click();
      await article.getByText(excerptText, { exact: true }).waitFor();
    }
    const other = await signedIn(otherEmail, otherPassword);
    await other.getByRole("button", { name: "Add private holding", exact: true }).waitFor();
    assert.equal(await other.getByRole("heading", { name, exact: true }).count(), 0);

    await page.goto(new URL("/portfolio", origin).href);
    await page.locator("#unified-allocation").getByText("Venture fund", { exact: true }).waitFor();
    await page.goto(new URL(portfolio, origin).href);
    await article.getByRole("button", { name: "Edit holding", exact: true }).click();
    await page.getByLabel("Carrying value").fill("1250.4567");
    if (excerptTitle && excerptText) await page.getByLabel("I reviewed the selected excerpt.").check();
    await page.getByRole("button", { name: "Save holding", exact: true }).click();
    await article.getByText("AUD 1,250.4567", { exact: true }).waitFor();
    if (process.env.PRIVATE_ACCOUNT_MARK_HISTORY === "1") {
      await article.getByText("Valuation history", { exact: true }).click();
      await article.getByRole("button", { name: "Add valuation", exact: true }).click();
      await article.getByLabel("Carrying value").fill("1500.123456789");
      await article.getByLabel("Valuation date").fill("2026-07-01");
      await article.getByLabel("Valuation source").fill("July fund statement");
      await article.getByLabel("Valuation method").fill("Reported NAV");
      await article.getByRole("button", { name: "Save valuation", exact: true }).click();
      const july = article.getByRole("listitem").filter({ hasText: "July fund statement" });
      const june = article.getByRole("listitem").filter({ hasText: "June statement" });
      await july.getByText("Used for carrying value", { exact: true }).waitFor();
      await june.getByText("AUD 1,250.4567", { exact: true }).waitFor();
      await june.getByRole("button", { name: "Edit valuation", exact: true }).click();
      await article.getByLabel("Carrying value").fill("1251.987654321");
      await article.getByRole("button", { name: "Save valuation", exact: true }).click();
      await june.getByText("AUD 1,251.987654321", { exact: true }).waitFor();
      await july.getByText("Used for carrying value", { exact: true }).waitFor();
      await july.getByRole("button", { name: "Remove valuation", exact: true }).click();
      await article.getByRole("button", { name: "Confirm valuation removal", exact: true }).click();
      await july.waitFor({ state: "detached" });
      await june.getByText("Used for carrying value", { exact: true }).waitFor();
    }
    if (process.env.PRIVATE_ACCOUNT_KEEP_HOLDING !== "1") {
      await article.getByRole("button", { name: "Remove holding", exact: true }).click();
      await article.getByRole("button", { name: "Confirm removal", exact: true }).click();
      await article.waitFor({ state: "detached" });
      await page.reload();
      await page.getByRole("button", { name: "Add private holding", exact: true }).waitFor();
      assert.equal(await article.count(), 0);
    }
  } finally {
    await browser.close();
  }
});
