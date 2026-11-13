import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const origin = process.env.RESEARCH_TEST_ORIGIN;
const executablePath = process.env.RESEARCH_TEST_CHROME;

test("company research opens from search and works at desktop and mobile widths", {
  skip: !origin || !executablePath, timeout: 240_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, acceptDownloads: true });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(new URL("/markets", origin).href, { waitUntil: "load", timeout: 75_000 });
    const search = page.getByRole("textbox", { name: "Search instruments" });
    await search.click();
    await search.pressSequentially("CIK:320193", { delay: 50 });
    const result = page.getByRole("link").filter({ hasText: "Apple Inc." });
    try {
      await result.waitFor({ timeout: 15_000 });
    } catch {
      // A cold dev server can hydrate after the browser delivered the first keystrokes.
      await search.fill("");
      await search.fill("CIK:320193");
    }
    await result.click({ timeout: 45_000 });
    await page.getByRole("heading", { name: "Company intelligence" }).waitFor({ timeout: 45_000 });
    await page.getByRole("button", { name: "Financials", exact: true }).click();
    await page.getByRole("table", { name: "Financial facts" }).waitFor({ timeout: 35_000 });
    await page.getByLabel("Statement").selectOption("income");
    await page.getByLabel("Find in dataset").fill("RevenueFromContractWithCustomerExcludingAssessedTax");
    await page.getByRole("button", { name: "Filter", exact: true }).click();
    await page.getByRole("cell", { name: "Revenue from Contract with Customer, Excluding Assessed Tax", exact: true }).first().waitFor({ timeout: 35_000 });
    const [download] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "Export page" }).click()]);
    assert.equal(download.suggestedFilename(), "AAPL-financials.csv");

    await page.getByRole("button", { name: "Research Everything" }).click();
    await page.getByRole("heading", { name: "Company research report" }).waitFor();
    await page.getByText("Reported finances and calculated ratios", { exact: true }).waitFor({ timeout: 45_000 });
    const assistant = page.getByRole("complementary", { name: "Company research assistant" });
    assert.equal(await assistant.isVisible(), true);
    await page.getByRole("button", { name: "Collapse", exact: true }).click();
    assert.equal(await assistant.isVisible(), false);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.getByRole("button", { name: "News & Filings", exact: true }).click();
    await page.getByRole("table", { name: "Company filings and events" }).waitFor({ timeout: 35_000 });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
  }
});
