import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin, PRIVATE_MARKETS_TEST_CHROME: executablePath,
  PRIVATE_MARKETS_TEST_EMAIL: email, PRIVATE_MARKETS_TEST_PASSWORD: password,
  PRIVATE_MARKETS_OTHER_EMAIL: otherEmail, PRIVATE_MARKETS_OTHER_PASSWORD: otherPassword,
  PRIVATE_MARKETS_TEST_SOURCE_REVIEW: sourceReview,
} = process.env;

test("Source review compares revised evidence and saves a separately consented, linked update", {
  skip: !sourceReview || !origin || !executablePath || !email || !password || !otherEmail || !otherPassword,
  timeout: 120_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  const api = new URL("/api/workspace-service/private-markets", origin).href;
  const reportID = sourceReview;
  const deck = "Revised round statement";
  const title = "What did the published round disclose?";
  const sends = (page, action) => page.waitForResponse((response) =>
    response.url() === api && response.request().postDataJSON()?.action === action);

  async function signIn(address, secret) {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    await page.goto(new URL("/login?next=/private-markets?view=research", origin).href);
    await page.getByLabel("Email", { exact: true }).fill(address);
    await page.getByLabel("Password", { exact: true }).fill(secret);
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await page.getByRole("heading", { name: "Saved reports", exact: true }).waitFor();
    return page;
  }

  try {
    const page = await signIn(email, password);
    assert.equal((await page.request.post(api, { data: { action: "research_refresh", id: reportID } })).status(), 401);
    await page.getByRole("button", { name: title }).click();
    const review = sends(page, "research_refresh");
    await page.getByRole("button", { name: "Review sources for an update", exact: true }).click();
    const result = await review;
    assert.equal(result.status(), 200);
    assert.equal(result.request().postDataJSON().id, reportID);
    const sources = await result.json();
    assert.equal(sources.deals.length, 1);
    assert.equal(sources.documents.length, 1);
    assert.equal(sources.newer_announcements.length, 1);
    assert.equal(sources.unavailable_sources, 1);
    assert.deepEqual(Object.keys(sources.documents[0]).sort(), ["created_at", "id", "title"]);
    await page.getByText("1 original source is unavailable.", { exact: true }).waitFor();
    await page.getByRole("heading", { name: "What changed", exact: true }).waitFor();
    await page.locator("summary").filter({ hasText: "Disclosed valuation" }).click();
    await page.getByText("USD 100000000", { exact: true }).waitFor();
    await page.getByText("USD 125000000", { exact: true }).waitFor();
    await page.getByText("Revised", { exact: true }).waitFor();

    const question = page.getByLabel("Research question");
    const round = page.getByRole("checkbox", { name: /Heidi · Series C/ });
    const notice = page.getByRole("checkbox", { name: /Financing statement update/ });
    const privateSource = page.getByRole("checkbox", { name: deck, exact: true });
    const send = page.getByRole("button", { name: "Run research", exact: true });
    assert.equal(await question.inputValue(), title);
    assert.ok(await round.isChecked());
    assert.ok(!(await notice.isChecked()));
    assert.ok(!(await privateSource.isChecked()));
    assert.ok(await send.isDisabled());
    await notice.check();
    const consent = page.getByLabel("Allow Stock Tracker to send this question and the selected published sources to its AI provider.");
    await consent.check();
    await privateSource.check();
    const privateConsent = page.getByLabel("I have permission to share the selected private excerpts with OpenAI for this request.");
    assert.ok(!(await privateConsent.isChecked()));
    assert.ok(await send.isDisabled());
    await privateConsent.check();
    await privateSource.uncheck();
    assert.ok(!(await consent.isChecked()));
    assert.ok(await send.isDisabled());
    await consent.check();
    const updated = sends(page, "research");
    await send.click();
    const response = await updated;
    const payload = response.request().postDataJSON();
    assert.equal(payload.previous_report_id, reportID);
    assert.deepEqual(payload.opportunity_ids, [sources.deals[0].id]);
    assert.deepEqual(payload.announcement_ids, [sources.newer_announcements[0].id]);
    assert.deepEqual(payload.document_ids, []);
    assert.equal(response.status(), 200);
    const report = await response.json();
    assert.equal(report.previous_report_id, reportID);
    assert.notEqual(report.id, reportID);
    assert.ok(report.sources.some((source) => source.url === sources.newer_announcements[0].source_url));
    assert.ok(report.sources.some((source) => source.title === "Published changes since previous report"));
    await page.getByRole("button", { name: "Open previous report", exact: true }).click();
    await page.getByText("Initial round review.", { exact: true }).waitFor();

    const other = await signIn(otherEmail, otherPassword);
    const request = other.waitForRequest((request) => request.url() === api && request.postDataJSON()?.action === "reports");
    await other.reload();
    const { authorization } = await (await request).allHeaders();
    const denied = await other.request.post(api, { headers: { authorization }, data: { action: "research_refresh", id: reportID } });
    assert.equal(denied.status(), 404);
    assert.equal(denied.headers()["cache-control"], "no-store");
    const linked = await other.request.post(api, { headers: { authorization }, data: { ...payload } });
    assert.equal(linked.status(), 404);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
  } finally {
    await browser.close();
  }
});
