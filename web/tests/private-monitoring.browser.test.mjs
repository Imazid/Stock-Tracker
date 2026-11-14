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

async function signIn(page, address, secret) {
  await page.goto(new URL("/login?next=%2Fprivate-markets%3Fview%3Dupdates", origin).href);
  await page.getByLabel("Email", { exact: true }).fill(address);
  await page.getByLabel("Password", { exact: true }).fill(secret);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForURL("**/private-markets?view=updates");
  await page.getByRole("button", { name: "Sign out", exact: true }).waitFor();
}

test("web monitoring saves account choices, shows sourced alerts, and removes its subscription", {
  skip: !origin || !executablePath || !email || !password || !otherEmail || !otherPassword,
  timeout: 180_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const endpoint = new URL("/api/workspace-service/private-markets", origin).href;
    const anonymous = await page.request.post(endpoint, { data: { action: "web_monitor_preferences" } });
    assert.equal(anonymous.status(), 401);
    assert.equal(anonymous.headers()["cache-control"], "no-store");

    await signIn(page, email, password);
    const enabled = page.getByLabel("Collect alerts for this account from the web", { exact: true });
    await enabled.check();
    await page.getByLabel("Find a company to follow").fill("Capability X");
    const company = page.getByRole("checkbox", { name: /Capability X Limited/ });
    await company.check();
    const digest = page.getByLabel(/Allow Stock Tracker to send published updates/);
    assert.equal(await digest.isChecked(), false);
    await page.getByRole("button", { name: "Save monitoring preferences" }).click();
    await page.getByRole("status").getByText("Monitoring preferences saved.").waitFor();
    const alert = page.getByRole("heading", { name: "Capability X began trading on ASX", exact: true }).first();
    await alert.waitFor();
    const source = alert.locator("xpath=ancestor::li").getByRole("link").first();
    assert.match(await source.getAttribute("href"), /^https:\/\//);
    await page.getByRole("heading", { name: "Company updates", exact: true }).waitFor();

    await page.reload();
    await company.waitFor();
    assert.equal(await company.isChecked(), true);
    assert.equal(await enabled.isChecked(), true);
    await digest.check();
    await page.getByRole("button", { name: "Save monitoring preferences" }).click();
    await page.getByRole("status").getByText("Monitoring preferences saved.").waitFor();
    await page.reload();
    await digest.waitFor();
    assert.equal(await digest.isChecked(), true);
    await page.setViewportSize({ width: 360, height: 800 });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

    const other = await browser.newPage();
    await signIn(other, otherEmail, otherPassword);
    await other.getByText("No monitoring alerts", { exact: true }).waitFor();
    assert.equal(await other.getByLabel("Collect alerts for this account from the web", { exact: true }).isChecked(), false);
    assert.equal(await other.getByRole("heading", { name: "Capability X began trading on ASX", exact: true }).count(), 0);

    await enabled.uncheck();
    await page.getByRole("button", { name: "Save monitoring preferences" }).click();
    await page.getByRole("status").getByText("Monitoring preferences saved.").waitFor();
    await page.getByText("No monitoring alerts", { exact: true }).waitFor();
    assert.equal(await digest.count(), 0);
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
  }
});
