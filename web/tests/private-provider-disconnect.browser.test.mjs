import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin,
  PRIVATE_MARKETS_TEST_CHROME: executablePath,
  PRIVATE_MARKETS_TEST_EMAIL: email,
  PRIVATE_MARKETS_TEST_PASSWORD: password, VERCEL_OIDC_TOKEN: previewToken,
} = process.env;

test("an investor can cancel or confirm a provider disconnection from their profile", {
  skip: !origin || !executablePath || !email || !password,
  timeout: 90_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    if (previewToken) {
      await page.route(`${origin}/**`, (route) => route.continue({
        headers: { ...route.request().headers(), "x-vercel-trusted-oidc-idp-token": previewToken },
      }));
    }
    await page.goto(new URL("/login?next=/private-markets?view=portfolio", origin).href);
    await page.getByLabel("Email", { exact: true }).fill(email);
    await page.getByLabel("Password", { exact: true }).fill(password);
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();

    const profile = page.locator("#investor-profile");
    const disconnect = profile.getByRole("button", { name: "Disconnect Birchal", exact: true });
    const confirm = profile.getByRole("button", { name: "Confirm disconnect Birchal", exact: true });
    const current = profile.getByText("Retail · Verification current", { exact: true });
    await current.waitFor();
    const isDisconnection = (request) =>
      new URL(request.url()).pathname === "/api/workspace-service/private-markets" &&
      request.postDataJSON()?.action === "disconnect_provider";
    let requests = 0;
    page.on("request", (request) => { if (isDisconnection(request)) requests += 1; });

    await disconnect.click();
    await confirm.waitFor();
    await profile.getByRole("button", { name: "Cancel", exact: true }).click();
    await disconnect.waitFor();
    assert.equal(requests, 0);
    assert.ok(await current.isVisible());

    await disconnect.click();
    const pending = page.waitForResponse((response) => isDisconnection(response.request()));
    await confirm.click();
    const response = await pending;
    assert.equal(response.status(), 200);
    assert.deepEqual(await response.json(), { disconnected: true });
    await profile.getByText("Open your Birchal account for updates.", { exact: false }).waitFor();
    await profile.getByText("Retail · Connection revoked", { exact: true }).waitFor();
    assert.equal(requests, 1);
    assert.ok(await disconnect.isHidden());
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));

    await page.reload();
    await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();
    await profile.getByText("Retail · Connection revoked", { exact: true }).waitFor();
  } finally {
    await browser.close();
  }
});
