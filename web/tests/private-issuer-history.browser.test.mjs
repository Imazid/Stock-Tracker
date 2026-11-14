import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin, PRIVATE_MARKETS_TEST_CHROME: executablePath, VERCEL_OIDC_TOKEN: previewToken,
} = process.env;

test("Private Markets groups published financing and financials by issuer on mobile", {
  skip: !origin || !executablePath,
  timeout: 90_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    if (previewToken) await page.route(`${origin}/**`, (route) => route.continue({
      headers: { ...route.request().headers(), "x-vercel-trusted-oidc-idp-token": previewToken },
    }));
    await page.goto(new URL("/private-markets?view=explorer", origin).href);
    await page.getByLabel("Find a company", { exact: true }).fill("Heidi");
    const company = page.getByRole("button", { name: /^Heidi\b/ });
    assert.equal(await company.count(), 1);
    await company.click();
    await page.getByRole("heading", { name: "Funding history", exact: true }).waitFor();
    assert.equal(await page.evaluate(() => document.activeElement?.textContent), "Heidi");
    await page.getByRole("button", { name: "All companies", exact: true }).click();
    assert.equal(await page.evaluate(() => document.activeElement?.id), "private-company-filter");
    await company.click();
    await page.getByText("USD 50,000,000", { exact: true }).first().waitFor();
    const heidiRounds = page.getByRole("button", { name: /^Select Heidi .* for research$/ });
    assert.deepEqual(await heidiRounds.evaluateAll((buttons) => buttons.map((button) => button.getAttribute("aria-label"))), [
      "Select Heidi Series C for research", "Select Heidi Series B for research", "Select Heidi Series A follow-on for research",
    ]);
    await page.getByRole("button", { name: "Select Heidi Series B for research", exact: true }).click();
    await page.getByRole("button", { name: "Select Heidi Series C for research", exact: true }).click();
    await page.getByRole("heading", { name: "Compare funding rounds", exact: true }).waitFor();
    assert.equal(await page.getByRole("link", { name: "Round disclosure", exact: true }).count(), 2);
    await page.getByRole("radio", { name: "Funding Rounds", exact: true }).click();
    await page.getByRole("heading", { name: "IPO milestones", exact: true }).waitFor();
    await page.getByRole("heading", { name: "Historical and unverified rounds", exact: true }).waitFor();
    await page.getByRole("button", { name: "Remove Heidi Series B from comparison", exact: true }).click();
    await page.getByRole("heading", { name: "Selected funding round", exact: true }).waitFor();
    await page.getByRole("button", { name: "Explore Capability X Limited", exact: true }).click();
    await page.getByText("Year-over-year revenue change", { exact: true }).first().waitFor();
    await page.getByText("-38%", { exact: true }).first().waitFor();
    await page.getByRole("button", { name: "Research selected rounds (1)", exact: true }).click();
    await page.getByText("Sign in for AI research and saved reports", { exact: true }).waitFor();

    await page.goto(new URL("/private-markets", origin).href);
    await page.getByText("Investment size and traction", { exact: true }).click();
    await page.getByLabel("Reported currency", { exact: true }).selectOption("AUD");
    await page.getByLabel("Minimum raise target", { exact: true }).fill("4900000");
    await page.getByLabel("Maximum raise target", { exact: true }).fill("5100000");
    await page.getByRole("heading", { name: "ABC Commodities Limited", exact: true }).waitFor();
    assert.equal(await page.getByRole("heading", { name: "Capability X Limited", exact: true }).count(), 0);
    await page.getByLabel("Reported currency", { exact: true }).selectOption("USD");
    assert.equal(await page.getByLabel("Minimum raise target", { exact: true }).inputValue(), "");
    assert.equal(await page.getByLabel("Maximum raise target", { exact: true }).inputValue(), "");
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
    await page.goto(new URL("/private-markets?view=explorer&company=d72c4060-1ae7-4a2f-8f2e-9f4bf1577e01", origin).href);
    await page.getByRole("heading", { name: "Funding history", exact: true }).waitFor();
    assert.equal(await heidiRounds.count(), 3);
  } finally {
    await browser.close();
  }
});
