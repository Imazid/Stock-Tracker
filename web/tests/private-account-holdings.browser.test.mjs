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
    await article.locator("dd").getByText("AUD 1,200.4321", { exact: true }).waitFor();
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
    await article.locator("dd").getByText("AUD 1,250.4567", { exact: true }).waitFor();
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
    if (process.env.PRIVATE_ACCOUNT_CASH_FLOW === "1") {
      await article.getByText("Cash flows", { exact: true }).click();
      async function flow(type, amount, date, source) {
        await article.getByRole("button", { name: "Add cash flow", exact: true }).click();
        await article.getByLabel("Cash flow type").selectOption(type);
        await article.getByLabel("Cash flow amount").fill(amount);
        await article.getByLabel("Cash flow date").fill(date);
        await article.getByLabel("Cash flow source").fill(source);
        await article.getByRole("button", { name: "Save cash flow", exact: true }).click();
        await article.getByText(source, { exact: false }).waitFor();
      }
      await flow("contribution", "1000.123456789", "2025-06-01", "Initial contribution notice");
      await flow("pending", "100.0000000000000001", "2026-11-30", "Original call notice");
      const call = article.getByRole("listitem").filter({ hasText: "Original call notice" });
      await call.getByRole("button", { name: "Record payment", exact: true }).click();
      await article.getByLabel("Payment date").fill("2026-05-30");
      await article.getByLabel("Resolution source").fill("Capital call receipt");
      await article.getByRole("button", { name: "Save cash flow", exact: true }).click();
      await call.getByText(/Originally due/).waitFor();
      await call.getByText(/Capital call receipt/).waitFor();
      await flow("pending", "50", "2026-12-01", "Original cancelled call");
      const cancelled = article.getByRole("listitem").filter({ hasText: "Original cancelled call" });
      await cancelled.getByRole("button", { name: "Record cancellation", exact: true }).click();
      await article.getByLabel("Cancellation date").fill("2026-05-31");
      await article.getByLabel("Resolution source").fill("Fund cancelled the call");
      await article.getByRole("button", { name: "Save cash flow", exact: true }).click();
      await cancelled.getByText(/Fund cancelled the call/).waitFor();
      await flow("distribution", "200.123456789", "2026-06-01", "Distribution statement");
      await article.locator("dd").getByText("AUD 1,100.1234567890000001", { exact: true }).waitFor();
      await article.getByText("Performance", { exact: true }).click();
      await article.getByText("1.32×", { exact: true }).waitFor();
      await article.getByText("0.18×", { exact: true }).waitFor();
      await flow("distribution", "10", "2026-07-01", "Later distribution");
      await article.getByText(/Valuation-based returns require/).waitFor();
      await page.getByRole("radio", { name: "Capital activity", exact: true }).click();
      const activity = page.getByRole("region", { name: "Self-reported capital activity" });
      await activity.getByText(/Capital call receipt/).waitFor();
      await activity.getByText(/Fund cancelled the call/).waitFor();
      await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();
    }
    if (process.env.PRIVATE_ACCOUNT_SALE === "1") {
      await article.getByText("Cash flows", { exact: true }).click();
      await article.getByRole("button", { name: "Add cash flow", exact: true }).click();
      await article.getByLabel("Cash flow type").selectOption("sale");
      await article.getByLabel("Net sale proceeds").fill("400.1234567890000001");
      await article.getByLabel("Units sold").fill("0.0234567799999999");
      await article.getByLabel("Cost basis of units sold (optional)").fill("300");
      await article.getByLabel("Settlement date").fill("2026-07-02");
      await article.getByLabel("Cash flow source").fill("Partial sale settlement statement");
      await article.getByRole("button", { name: "Save cash flow", exact: true }).click();
      await article.locator("dd").getByText("0.1000000000000001", { exact: true }).waitFor();
      await article.locator("dd").getByText("AUD 400.1234567890000001", { exact: true }).waitFor();
      await article.getByText(/Add a valuation of the remaining position dated after/).waitFor();
      await article.getByText("Valuation history", { exact: true }).click();
      assert.equal(await article.getByText("Used for carrying value", { exact: true }).count(), 0);
      await article.getByRole("button", { name: "Add valuation", exact: true }).click();
      await article.getByLabel("Carrying value").fill("850");
      await article.getByLabel("Valuation date").fill("2026-07-03");
      await article.getByLabel("Valuation source").fill("Remaining-position statement");
      await article.getByLabel("Valuation method").fill("Reported NAV");
      await article.getByRole("button", { name: "Save valuation", exact: true }).click();
      await article.getByText("Used for carrying value", { exact: true }).waitFor();
      await article.getByText("Performance", { exact: true }).click();
      await article.getByText("Realised gain on sales", { exact: true }).waitFor();
      await article.locator("dd").getByText("$100.12", { exact: true }).waitFor();
      await article.locator("dd").getByText("1.33×", { exact: true }).waitFor();
      await page.getByRole("radio", { name: "Capital activity", exact: true }).click();
      const activity = page.getByRole("region", { name: "Self-reported capital activity" });
      await activity.getByText("Partial sale settlement statement", { exact: true }).waitFor();
      await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();
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
