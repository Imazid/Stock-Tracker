import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin, PRIVATE_MARKETS_TEST_CHROME: executablePath,
  PRIVATE_MARKETS_TEST_EMAIL: email, PRIVATE_MARKETS_TEST_PASSWORD: password,
  PRIVATE_MARKETS_OTHER_EMAIL: otherEmail, PRIVATE_MARKETS_OTHER_PASSWORD: otherPassword,
} = process.env;

test("a saved profile and a successful readiness check still require fresh provider approval", {
  skip: !origin || !executablePath || !email || !password || !otherEmail || !otherPassword,
  timeout: 120_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    const api = new URL("/api/workspace-service/private-markets", origin).href;
    const profile = page.locator("#investor-profile");
    const classification = profile.getByLabel("Self-declared classification");
    const signIn = async (address, secret) => {
      await page.goto(new URL("/login?next=/private-markets", origin).href);
      await page.getByLabel("Email", { exact: true }).fill(address);
      await page.getByLabel("Password", { exact: true }).fill(secret);
      await page.getByRole("button", { name: "Sign in", exact: true }).click();
      await page.waitForURL((url) => url.pathname === "/private-markets");
      await page.getByRole("button", { name: "Sign out", exact: true }).waitFor();
    };
    const openOffer = async () => {
      await page.getByRole("radio", { name: "Discover", exact: true }).click();
      const offer = page.getByRole("article").filter({
        has: page.getByRole("heading", { name: "Web handoff QA", exact: true }),
      });
      await offer.getByText("Provider application", { exact: true }).click();
      const check = offer.getByRole("button", { name: "Check readiness", exact: true });
      const amount = offer.getByLabel("Requested amount (AUD)", { exact: true });
      const reviewed = offer.getByLabel("I reviewed the current offer document.");
      const risk = offer.getByLabel("I understand I could lose the entire investment and may be unable to sell it.");
      assert.equal(await check.isDisabled(), true);
      await amount.fill("500.25");
      await reviewed.check();
      assert.equal(await check.isDisabled(), true);
      await risk.check();
      return { offer, check, amount };
    };

    await signIn(email, password);
    await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();
    await profile.getByText("Retail · Verification current", { exact: true }).waitFor();
    await classification.selectOption("wholesale");
    await profile.getByRole("button", { name: "Save profile" }).click();
    await profile.getByText("Investor profile saved.", { exact: true }).waitFor();
    await profile.getByText("Retail · Verification current", { exact: true }).waitFor();
    assert.equal(await classification.inputValue(), "wholesale");

    const { offer, check, amount } = await openOffer();
    const checked = page.waitForResponse((response) =>
      response.url() === api && response.request().postDataJSON()?.action === "handoff_check");
    await check.click();
    const result = await checked;
    assert.equal(result.status(), 200);
    assert.deepEqual(await result.json(), { ready: true });
    const open = offer.getByRole("button", { name: "Open Birchal application", exact: true });
    await open.waitFor();
    await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();
    await page.getByText("No recorded applications", { exact: true }).waitFor();
    const reopened = await openOffer();
    await reopened.check.click();
    await open.waitFor();
    await amount.fill("600");
    await check.waitFor();
    await check.click();
    await open.waitFor();

    // The disposable harness revokes the provider approval immediately before the next opening.
    await open.click();
    await offer.getByText("Provider handoff is awaiting approval", { exact: true }).waitFor();
    assert.equal(await open.count(), 0);
    assert.equal(new URL(page.url()).origin, origin);
    await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();
    await page.getByText("No recorded applications", { exact: true }).waitFor();
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

    await page.getByRole("button", { name: "Sign out", exact: true }).click();
    await signIn(otherEmail, otherPassword);
    await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();
    await profile.getByText("No provider verification on record.", { exact: true }).waitFor();
    assert.equal(await classification.inputValue(), "unknown");
    await page.getByText("No recorded applications", { exact: true }).waitFor();
  } finally {
    await browser.close();
  }
});
