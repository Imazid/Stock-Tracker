import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin, PRIVATE_MARKETS_TEST_CHROME: executablePath,
  PRIVATE_MARKETS_TEST_EMAIL: email, PRIVATE_MARKETS_TEST_PASSWORD: password,
  PRIVATE_RESUME_TEST_OPEN: expectedOpen, VERCEL_OIDC_TOKEN: previewToken,
} = process.env;

test("pending applications reopen the exact saved handoff after fresh review", {
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
    await page.route("https://www.birchal.com/resume-test*", (route) => route.fulfill({ body: "Provider navigation verified" }));
    await page.goto(new URL("/login?next=/private-markets?view=portfolio", origin).href);
    await page.getByLabel("Email", { exact: true }).fill(email);
    await page.getByLabel("Password", { exact: true }).fill(password);
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();
    const row = page.getByRole("article").filter({ has: page.getByText("Awaiting provider", { exact: true }) });
    const action = (request, name) => new URL(request.url()).pathname === "/api/workspace-service/private-markets" &&
      request.postDataJSON()?.action === name;
    const review = page.waitForResponse((response) => action(response.request(), "handoff_review"));
    await row.getByRole("button", { name: "Review and reopen handoff", exact: true }).click();
    const loaded = await review;
    assert.equal(loaded.status(), 200);
    assert.equal((await loaded.json()).requested_amount, "500.4321");
    const check = row.getByRole("button", { name: "Check readiness", exact: true });
    const field = row.getByLabel("Requested amount (AUD)", { exact: true });
    assert.equal(await field.inputValue(), "500.4321");
    assert.equal(await field.getAttribute("readonly"), "");
    assert.ok(await check.isDisabled());
    await row.getByLabel("I reviewed the current offer document.").check();
    assert.ok(await check.isDisabled());
    await row.getByLabel("I understand I could lose the entire investment and may be unable to sell it.").check();

    const checked = page.waitForResponse((response) => action(response.request(), "handoff_resume_check"));
    await check.click();
    const readiness = await checked;
    assert.equal(readiness.status(), 200);
    assert.deepEqual(await readiness.json(), { ready: true });
    const fields = readiness.request().postDataJSON();
    assert.deepEqual(Object.keys(fields).sort(), ["acknowledged", "action", "currency", "document_url", "id"]);

    const opened = page.waitForResponse((response) => action(response.request(), "handoff_resume"));
    await row.getByRole("button", { name: "Open Birchal application", exact: true }).click();
    const response = await opened;
    if (expectedOpen) {
      assert.deepEqual(await response.json(), { commitment_id: fields.id, handoff_url: expectedOpen });
      await page.waitForURL(expectedOpen);
      await page.getByText("Provider navigation verified").waitFor();
    } else {
      assert.equal(response.status(), 409);
      await row.getByText("This handoff is no longer pending. Refresh your applications.", { exact: true }).waitFor();
    }
  } finally {
    await browser.close();
  }
});
