import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin, PRIVATE_MARKETS_TEST_CHROME: executablePath,
  PRIVATE_MARKETS_TEST_EMAIL: email, PRIVATE_MARKETS_TEST_PASSWORD: password,
  PRIVATE_MARKETS_OTHER_EMAIL: otherEmail, PRIVATE_MARKETS_OTHER_PASSWORD: otherPassword,
  VERCEL_OIDC_TOKEN: previewToken,
  PRIVATE_MARKETS_TEST_DOCUMENT_AI: testDocumentAI,
} = process.env;

test("Deal Room requires permission to save and keeps private excerpts account-scoped", {
  skip: !origin || !executablePath || !email || !password || !otherEmail || !otherPassword,
  timeout: 120_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  const api = new URL("/api/workspace-service/private-markets", origin).href;
  const title = "Disposable fund statement";
  const excerpt = "The fund statement records that the sample portfolio contains three positions. The manager’s review is still pending.";
  async function signIn(address, secret) {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    if (previewToken) {
      await page.route(`${origin}/**`, (route) => route.continue({
        headers: { ...route.request().headers(), "x-vercel-trusted-oidc-idp-token": previewToken },
      }));
    }
    await page.goto(new URL("/private-markets?view=deal-room", origin).href);
    await page.getByText("Sign in to open your Deal Room", { exact: true }).waitFor();
    await page.getByRole("link", { name: "Sign in", exact: true }).last().click();
    await page.getByLabel("Email", { exact: true }).fill(address);
    await page.getByLabel("Password", { exact: true }).fill(secret);
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await page.waitForURL((url) => url.pathname === "/private-markets" && url.searchParams.get("view") === "deal-room");
    await page.getByRole("heading", { name: "Saved excerpts", exact: true }).waitFor();
    return page;
  }
  try {
    const owner = await signIn(email, password);
    const save = owner.getByRole("button", { name: "Save excerpt", exact: true });
    await owner.getByLabel("Excerpt title").fill(title);
    await owner.getByLabel("Reviewed excerpt").fill(excerpt);
    assert.ok(await save.isDisabled());
    const permission = owner.getByLabel("I have permission to store this excerpt in Stock Tracker.");
    await permission.check();
    await owner.getByLabel("Reviewed excerpt").fill(excerpt + " Updated.");
    assert.ok(await save.isDisabled());
    await permission.check();

    const saved = owner.waitForResponse((response) => response.url() === api && response.request().postDataJSON()?.action === "save_document");
    await save.click();
    const response = await saved;
    assert.equal(response.status(), 201);
    const document = await response.json();
    assert.deepEqual(Object.keys(document).sort(), ["id", "title"]);
    await owner.getByText(excerpt + " Updated.", { exact: true }).waitFor();
    await owner.reload();
    await owner.getByRole("button", { name: new RegExp(title) }).click();
    await owner.getByText(excerpt + " Updated.", { exact: true }).waitFor();
    assert.ok(await owner.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

    const other = await signIn(otherEmail, otherPassword);
    const libraryRequest = other.waitForRequest((request) => request.url() === api && request.postDataJSON()?.action === "documents");
    await other.reload();
    const authorization = (await (await libraryRequest).allHeaders()).authorization;
    await other.getByText("No excerpts saved", { exact: true }).waitFor();
    const refused = await other.request.post(api, {
      headers: { authorization, ...(previewToken ? { "x-vercel-trusted-oidc-idp-token": previewToken } : {}) },
      data: { action: "document", id: document.id },
    });
    assert.equal(refused.status(), 404);
    assert.equal(refused.headers()["cache-control"], "no-store");

    const question = "What does the fund statement say about the review?";
    let reportID;
    if (testDocumentAI === "true") {
      await owner.getByRole("radio", { name: "AI Research", exact: true }).click();
      await owner.getByLabel(title, { exact: true }).check();
      await owner.getByLabel("Research question").fill(question);
      await owner.getByLabel("Allow Stock Tracker to send this question and the selected sources to its AI provider.").check();
      const research = owner.getByRole("button", { name: "Run research", exact: true });
      assert.ok(await research.isDisabled());
      await owner.getByLabel("I have permission to share the selected private excerpts with OpenAI for this request.").check();
      assert.ok(await research.isEnabled());
      const completion = owner.waitForResponse((result) => result.url() === api && result.request().postDataJSON()?.action === "research");
      await research.click();
      const result = await completion;
      assert.equal(result.status(), 200);
      reportID = (await result.json()).id;
      await owner.getByText("The statement reports a pending review.", { exact: true }).waitFor();
      await owner.getByRole("radio", { name: "Deal Room", exact: true }).click();
      await owner.getByRole("button", { name: new RegExp(title) }).click();
    }

    await owner.getByRole("button", { name: "Delete excerpt", exact: true }).click();
    await owner.getByRole("button", { name: "Confirm deletion", exact: true }).click();
    await owner.getByText("No excerpts saved", { exact: true }).waitFor();
    await owner.reload();
    await owner.getByText("No excerpts saved", { exact: true }).waitFor();

    if (reportID) {
      const previewHeaders = previewToken ? { "x-vercel-trusted-oidc-idp-token": previewToken } : {};
      assert.equal((await other.request.post(api, { headers: previewHeaders, data: { action: "delete_report", id: reportID } })).status(), 401);
      assert.equal((await other.request.post(api, {
        headers: { ...previewHeaders, authorization }, data: { action: "delete_report", id: reportID },
      })).status(), 200);

      await owner.getByRole("radio", { name: "AI Research", exact: true }).click();
      await owner.getByRole("button", { name: question }).click();
      const quote = owner.getByRole("blockquote").filter({ hasText: excerpt });
      await quote.waitFor();
      await owner.getByRole("button", { name: "Delete report", exact: true }).click();
      await owner.getByRole("button", { name: "Cancel", exact: true }).click();
      await quote.waitFor();
      await owner.getByRole("button", { name: "Delete report", exact: true }).click();
      const deletion = owner.waitForResponse((result) => result.url() === api && result.request().postDataJSON()?.action === "delete_report");
      await owner.getByRole("button", { name: "Confirm deletion", exact: true }).click();
      const deleted = await deletion;
      assert.equal(deleted.status(), 200);
      const ownerAuthorization = (await deleted.request().allHeaders()).authorization;
      await owner.getByText("Report deleted.", { exact: true }).waitFor();
      await quote.waitFor({ state: "detached" });
      await owner.getByText("No saved reports", { exact: true }).waitFor();
      await owner.reload();
      await owner.getByRole("radio", { name: "AI Research", exact: true }).click();
      await owner.getByText("No saved reports", { exact: true }).waitFor();
      const missing = await owner.request.post(api, {
        headers: { ...previewHeaders, authorization: ownerAuthorization }, data: { action: "report", id: reportID },
      });
      assert.equal(missing.status(), 404);
    }
  } finally {
    await browser.close();
  }
});
