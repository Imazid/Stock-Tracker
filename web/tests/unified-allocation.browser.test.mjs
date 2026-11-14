import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin,
  PRIVATE_MARKETS_TEST_CHROME: executablePath,
  PRIVATE_MARKETS_TEST_EMAIL: email,
  PRIVATE_MARKETS_TEST_PASSWORD: password,
  PRIVATE_MARKETS_OTHER_EMAIL: otherEmail,
  PRIVATE_MARKETS_OTHER_PASSWORD: otherPassword,
} = process.env;

async function signIn(browser, address, secret) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.goto(new URL("/login?next=/portfolio", origin).href);
  await page.getByLabel("Email", { exact: true }).fill(address);
  await page.getByLabel("Password", { exact: true }).fill(secret);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForURL("**/portfolio");
  await page.getByRole("heading", { name: "Unified allocation", exact: true }).waitFor();
  return page;
}

test("listed and provider holdings share a denominator while a second account sees none", {
  skip: !origin || !executablePath || !email || !password || !otherEmail || !otherPassword,
  timeout: 180_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  try {
    const page = await signIn(browser, email, password);
    const allocation = page.locator("#unified-allocation");
    const rows = allocation.getByRole("list", { name: "Unified allocation categories" });
    await rows.getByText("Startup equity", { exact: true }).waitFor();
    await rows.getByText("A$1,300.00", { exact: true }).waitFor();
    await rows.getByText("Listed shares", { exact: true }).waitFor({ timeout: 50_000 });
    await allocation.getByText(/1 of 1 listed positions valued.*1 of 1 private positions valued/).waitFor();
    assert.equal(await allocation.getByText(/older than 90 days/).isVisible(), true);
    await allocation.getByRole("button", { name: "USD", exact: true }).click();
    const row = rows.getByRole("listitem").filter({ hasText: "Startup equity" });
    await row.getByText(/US\$/).waitFor({ timeout: 30_000 });
    await page.setViewportSize({ width: 360, height: 800 });
    assert.ok(await allocation.evaluate((card) => card.scrollWidth <= card.clientWidth + 1));

    const other = await signIn(browser, otherEmail, otherPassword);
    await other.locator("#unified-allocation").getByText(/0 of 0 listed positions valued.*0 of 0 private positions valued/).waitFor();
    assert.equal(await other.locator("#unified-allocation").getByText("Startup equity", { exact: true }).count(), 0);
  } finally {
    await browser.close();
  }
});
