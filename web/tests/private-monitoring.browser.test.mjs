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
  PRIVATE_MARKETS_TEST_UPDATE_RESEARCH: updateResearch,
  VERCEL_OIDC_TOKEN: previewToken,
} = process.env;

const previewHeaders = previewToken ? { "x-vercel-trusted-oidc-idp-token": previewToken } : {};
const capabilityCompany = "/private-markets?view=explorer&company=a581f4af-a8d0-41fd-a9be-0e4e1607f102";
const heidiCompany = "/private-markets?view=explorer&company=d72c4060-1ae7-4a2f-8f2e-9f4bf1577e01";

async function permitPreview(page) {
  if (previewToken) await page.route(`${origin}/**`, (route) => route.continue({
    headers: { ...route.request().headers(), ...previewHeaders },
  }));
}

async function signIn(page, address, secret, destination = "/private-markets?view=updates") {
  await page.goto(new URL(`/login?next=${encodeURIComponent(destination)}`, origin).href);
  await page.getByLabel("Email", { exact: true }).fill(address);
  await page.getByLabel("Password", { exact: true }).fill(secret);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForURL(new URL(destination, origin).href);
  await page.getByRole("button", { name: "Sign out", exact: true }).waitFor();
}

test("web monitoring saves account choices, shows sourced alerts, and removes its subscription", {
  skip: !origin || !executablePath || !email || !password || !otherEmail || !otherPassword,
  timeout: 180_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
    await permitPreview(page);
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const endpoint = new URL("/api/workspace-service/private-markets", origin).href;
    const anonymous = await page.request.post(endpoint, { headers: previewHeaders, data: { action: "web_monitor_preferences" } });
    assert.equal(anonymous.status(), 401);
    assert.equal(anonymous.headers()["cache-control"], "no-store");

    await page.goto(new URL(capabilityCompany, origin).href);
    const followSignIn = page.getByRole("link", { name: "Sign in to follow", exact: true });
    assert.equal(await followSignIn.getAttribute("href"), `/login?next=${encodeURIComponent(capabilityCompany)}`);
    await signIn(page, email, password, capabilityCompany);
    const follow = page.getByRole("button", { name: "Follow company", exact: true });
    const unfollow = page.getByRole("button", { name: "Unfollow company", exact: true });
    await follow.click();
    await page.getByText("Enable web monitoring to collect this company’s published updates", { exact: false }).waitFor();
    await page.getByRole("button", { name: "Cancel", exact: true }).click();
    await follow.click();
    await page.getByRole("button", { name: "Enable monitoring and follow", exact: true }).click();
    await unfollow.waitFor();
    await page.getByRole("button", { name: "View company updates", exact: true }).click();
    const enabled = page.getByLabel("Collect alerts for this account from the web", { exact: true });
    await page.getByLabel("Find a company to follow").fill("Capability X");
    const company = page.getByRole("checkbox", { name: /Capability X Limited/ });
    assert.ok(await enabled.isChecked());
    assert.ok(await company.isChecked());
    const digest = page.getByLabel(/Allow Stock Tracker to send published updates/);
    assert.equal(await digest.isChecked(), false);
    const alert = page.getByRole("heading", { name: "Capability X began trading on ASX", exact: true }).first();
    await alert.waitFor();
    const source = alert.locator("xpath=ancestor::li").getByRole("link").first();
    assert.match(await source.getAttribute("href"), /^https:\/\//);
    const updates = page.getByRole("heading", { name: "Company updates", exact: true }).locator("xpath=ancestor::section");
    await updates.waitFor();

    if (updateResearch === "true") {
      const noticeTitle = "Capability X began trading on ASX";
      const filingTitle = "Audited financial results";
      const notice = updates.getByRole("checkbox", { name: `Select ${noticeTitle} for research` });
      const filing = updates.getByRole("checkbox", { name: `Select ${filingTitle} for research` });
      const noticeURL = await notice.locator("xpath=ancestor::li").getByRole("link").getAttribute("href");
      const filingURL = await filing.locator("xpath=ancestor::li").getByRole("link").getAttribute("href");
      const runRequests = [];
      page.on("request", (request) => {
        if (request.url() === endpoint && request.postDataJSON()?.action === "research") runRequests.push(request);
      });
      await notice.check();
      await filing.check();
      await updates.getByRole("button", { name: "Research selected updates" }).click();
      await page.getByRole("heading", { name: "Selected company updates" }).waitFor();
      const draft = page.getByLabel("Research question");
      assert.equal(await draft.inputValue(), "Summarise these published company updates and identify what still needs verification.");
      const run = page.getByRole("button", { name: "Run research", exact: true });
      const consent = page.getByLabel("Allow Stock Tracker to send this question and the selected published sources to its AI provider.");
      assert.ok(await run.isDisabled());
      assert.ok(!(await consent.isChecked()));
      await consent.check();
      await page.getByRole("button", { name: `Remove ${noticeTitle}`, exact: true }).click();
      assert.ok(!(await consent.isChecked()));
      assert.ok(await run.isDisabled());
      assert.equal(runRequests.length, 0);
      await consent.check();
      const result = page.waitForResponse((response) => response.url() === endpoint &&
        response.request().postDataJSON()?.action === "research");
      await run.click();
      const response = await result;
      const payload = response.request().postDataJSON();
      assert.equal(response.status(), 200);
      assert.equal(runRequests.length, 1);
      assert.equal(payload.announcement_ids.length, 1);
      assert.deepEqual(payload.opportunity_ids, []);
      assert.deepEqual(payload.document_ids, []);
      assert.equal(payload.model_consent, true);
      const report = await response.json();
      assert.ok(report.sources.some(({ url }) => url === filingURL));
      assert.ok(!report.sources.some(({ url }) => url === noticeURL));
      await page.getByRole("heading", { name: "Sources", exact: true }).waitFor();
      assert.ok(await run.isDisabled());
    }

    await page.goto(new URL("/private-markets?view=updates", origin).href);
    await company.waitFor();
    assert.equal(await company.isChecked(), true);
    assert.equal(await enabled.isChecked(), true);
    await digest.check();
    await page.getByRole("button", { name: "Save monitoring preferences" }).click();
    await page.getByRole("status").getByText("Monitoring preferences saved.").waitFor();
    await page.reload();
    await digest.waitFor();
    assert.equal(await digest.isChecked(), true);
    await page.getByLabel(/Include new rounds matching/).check();
    await page.getByRole("button", { name: "Save monitoring preferences" }).click();
    await page.getByRole("status").getByText("Monitoring preferences saved.").waitFor();

    const concurrent = await page.context().newPage();
    await permitPreview(concurrent);
    await concurrent.goto(new URL(heidiCompany, origin).href);
    const concurrentFollow = concurrent.getByRole("button", { name: "Follow company", exact: true });
    await concurrentFollow.waitFor();
    await page.goto(new URL(capabilityCompany, origin).href);
    await unfollow.click();
    await follow.waitFor();
    await concurrentFollow.click();
    await concurrent.getByText("Monitoring preferences changed. Review the latest choices and try again.", { exact: true }).waitFor();
    await concurrentFollow.click();
    await concurrent.getByRole("button", { name: "Unfollow company", exact: true }).waitFor();
    await concurrent.close();
    await page.goto(new URL("/private-markets?view=updates", origin).href);
    const heidi = page.getByRole("checkbox", { name: /Heidi/ });
    await heidi.waitFor();
    assert.ok(await heidi.isChecked());
    assert.ok(!(await company.isChecked()));
    assert.ok(await digest.isChecked());
    assert.ok(await page.getByLabel(/Include new rounds matching/).isChecked());
    await page.setViewportSize({ width: 360, height: 800 });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

    const other = await browser.newPage();
    await permitPreview(other);
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
