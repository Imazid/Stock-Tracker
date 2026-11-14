import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";
import { freshAuthenticatorCode } from "./authenticator-code.mjs";

const {
  ACCOUNT_DELETION_TEST_ORIGIN: origin,
  PRIVATE_MARKETS_TEST_CHROME: executablePath,
  ACCOUNT_DELETION_TEST_ACCOUNTS: accountData,
  VERCEL_OIDC_TOKEN: previewToken,
} = process.env;

test("Web account deletion confirms the active owner, enforces MFA, and signs out the deleted account", {
  skip: !origin || !executablePath || !accountData,
  timeout: 120_000,
}, async () => {
  const [owner, other] = JSON.parse(accountData);
  const browser = await chromium.launch({ executablePath, headless: true });
  const endpoint = new URL("/api/workspace-service/account-deletion", origin).href;
  const exportEndpoint = new URL("/api/workspace-service/account-export", origin).href;
  const protectionHeaders = previewToken ? { "x-vercel-trusted-oidc-idp-token": previewToken } : {};

  async function signIn(account) {
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    if (previewToken) {
      await page.route(`${origin}/**`, (route) => route.continue({ headers: { ...route.request().headers(), ...protectionHeaders } }));
    }
    await page.goto(origin + "/login?next=/settings");
    await page.getByLabel("Email", { exact: true }).fill(account.email);
    await page.getByLabel("Password", { exact: true }).fill(account.password);
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await page.getByRole("button", { name: "Delete my account", exact: true }).waitFor();
    return page;
  }

  try {
    const page = await signIn(owner);
    const bystander = await signIn(other);
    const denied = await page.request.post(endpoint, { data: { confirm: true }, headers: protectionHeaders });
    assert.equal(denied.status(), 401);
    assert.equal(denied.headers()["cache-control"], "no-store");
    const visitKey = `st:portfolio-visit:${owner.id}`;
    await page.evaluate((key) => localStorage.setItem(key, new Date().toISOString()), visitKey);

    const started = [];
    page.on("request", (request) => { if (request.url() === endpoint) started.push(request); });
    const open = page.getByRole("button", { name: "Delete my account", exact: true });
    const submit = page.getByRole("button", { name: "Permanently delete account", exact: true });
    const password = page.getByLabel("Current password", { exact: true });

    await open.click();
    assert.ok(await submit.isDisabled());
    await password.fill("mistyped-password");
    await page.getByRole("button", { name: "Cancel account deletion", exact: true }).click();
    await open.click();
    assert.equal(await password.inputValue(), "");
    assert.equal(started.length, 0);

    await password.fill("mistyped-password");
    const stepUp = page.waitForResponse(endpoint);
    await submit.click();
    assert.equal((await stepUp).status(), 403);
    await page.getByText("Verify your authenticator code before deleting your account.", { exact: true }).waitFor();
    const code = page.getByLabel("Deletion authenticator code", { exact: true });
    assert.ok(await submit.isDisabled());
    await code.fill(await freshAuthenticatorCode(owner.secret));
    const refused = page.waitForResponse(endpoint);
    await submit.click();
    const wrongPassword = await refused;
    assert.equal(wrongPassword.status(), 403);
    assert.equal((await wrongPassword.json()).error.code, "incorrect_password");
    await page.getByText("The password did not match this account.", { exact: true }).waitFor();
    assert.equal(await password.inputValue(), "");
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));

    const authorization = (await wrongPassword.request().allHeaders()).authorization;
    const authHeaders = { ...protectionHeaders, authorization };
    const wrongOwner = await page.request.post(endpoint, {
      data: { confirm: true, password: owner.password, userId: other.id }, headers: authHeaders,
    });
    assert.equal(wrongOwner.status(), 400);
    assert.equal((await wrongOwner.json()).error.code, "confirmation_required");
    const present = await page.request.post(exportEndpoint, { data: {}, headers: authHeaders });
    assert.equal(present.status(), 200);

    await password.fill(owner.password);
    const deleted = page.waitForResponse(endpoint);
    await submit.click();
    const result = await deleted;
    assert.equal(result.status(), 200);
    assert.equal((await result.json()).deleted, true);
    const notice = page.getByText("Your Stock Tracker account was deleted.", { exact: true });
    await notice.waitFor();
    await open.waitFor({ state: "hidden" });
    assert.equal(await page.evaluate((key) => localStorage.getItem(key), visitKey), null);
    const revoked = await page.request.post(exportEndpoint, {
      data: {}, headers: { ...protectionHeaders, authorization: (await result.request().allHeaders()).authorization },
    });
    assert.equal(revoked.status(), 401);
    await page.reload();
    await page.getByRole("link", { name: "Sign in", exact: true }).last().waitFor();
    assert.ok(await open.isHidden());

    const pendingArchive = bystander.waitForEvent("download", { timeout: 60_000 });
    await bystander.getByRole("button", { name: "Download account data", exact: true }).click();
    const archive = await pendingArchive;
    const chunks = [];
    for await (const chunk of await archive.createReadStream()) chunks.push(chunk);
    const data = JSON.parse(Buffer.concat(chunks).toString()).cloud_records;
    assert.equal(data.account[0].id, other.id);
    assert.equal(data.private_excerpts.length, 1);
    assert.equal(data.private_excerpts[0].excerpt, "This separate account survives account deletion.");
  } finally {
    await browser.close();
  }
});
