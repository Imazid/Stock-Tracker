import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { test } from "node:test";
import { chromium } from "playwright-core";

const {
  ACCOUNT_EXPORT_TEST_ORIGIN: origin,
  PRIVATE_MARKETS_TEST_CHROME: executablePath,
  ACCOUNT_EXPORT_TEST_ACCOUNTS: accountData,
  VERCEL_OIDC_TOKEN: previewToken,
} = process.env;

function currentCode(secret) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const bits = [...secret.toUpperCase().replaceAll("=", "")].map((char) => alphabet.indexOf(char).toString(2).padStart(5, "0")).join("");
  const key = Buffer.from(bits.match(/.{8}/g).map((octet) => Number.parseInt(octet, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30_000)));
  const digest = createHmac("sha1", key).update(counter).digest();
  return String((digest.readUInt32BE(digest[19] & 15) & 0x7fffffff) % 1_000_000).padStart(6, "0");
}

test("Web account export verifies the owner, pages through their records and enforces MFA", {
  skip: !origin || !executablePath || !accountData,
  timeout: 180_000,
}, async () => {
  const [owner, other] = JSON.parse(accountData);
  const browser = await chromium.launch({ executablePath, headless: true });
  const endpoint = new URL("/api/workspace-service/account-export", origin).href;
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
    await page.getByRole("button", { name: "Download account data", exact: true }).waitFor();
    return page;
  }
  async function download(page, action) {
    const pending = page.waitForEvent("download", { timeout: 70_000 });
    await page.getByRole("button", { name: action, exact: true }).click();
    const file = await pending;
    assert.match(file.suggestedFilename(), /^stock-tracker-account-\d{4}-\d\d-\d\d\.json$/);
    const chunks = [];
    for await (const chunk of await file.createReadStream()) chunks.push(chunk);
    return JSON.parse(Buffer.concat(chunks).toString());
  }

  try {
    const plain = await signIn(owner);
    const requested = [];
    const headers = await plain.request.post(endpoint, { data: {}, headers: protectionHeaders });
    assert.equal(headers.status(), 401);
    assert.equal(headers.headers()["cache-control"], "no-store");

    let release;
    const blocked = new Promise((resume) => { release = resume; });
    let observed;
    const manifestStarted = new Promise((resolve) => { observed = resolve; });
    const delay = async (route) => {
      observed();
      await blocked;
      // The browser has already aborted the fetch after the user cancelled.
      await route.abort().catch((error) => {
        if (!String(error).includes("Route is already handled")) throw error;
      });
    };
    await plain.route(endpoint, delay);
    try {
      await plain.getByRole("button", { name: "Download account data", exact: true }).click();
      await manifestStarted;
      await plain.getByRole("button", { name: "Cancel export", exact: true }).click();
      await plain.getByText("Export cancelled.", { exact: true }).waitFor();
    } finally {
      release();
      await plain.unroute(endpoint, delay);
    }

    plain.on("request", (request) => {
      if (request.url() === endpoint) requested.push(request);
    });
    const file = await download(plain, "Download account data");
    assert.equal(file.schema_version, 1);
    assert.equal(file.cloud_records.account[0].id, owner.id);
    assert.ok(Object.keys(file.cloud_records).length >= 59);
    const listings = file.cloud_records.listed_holdings;
    assert.equal(listings.length, 51);
    assert.equal(new Set(listings.map((item) => item.id)).size, 51);
    assert.ok(requested.some((request) => request.postDataJSON()?.section === "listed_holdings" && request.postDataJSON().offset === 50));
    assert.equal(file.cloud_records.private_excerpts[0].excerpt, "This disposable private excerpt must only appear in the owner's archive.");
    assert.equal(file.cloud_records.private_excerpts[0].sealed, undefined);
    assert.equal(file.cloud_records.secure_credentials, undefined);
    assert.equal(file.cloud_records.stock_splits[0].fraction_shares, "0.123456789012345678");
    assert.equal(file.cloud_records.stock_splits[0].fraction_proceeds, "12.12345678");
    assert.equal(file.cloud_records.stock_spin_offs[0].child_shares, "0.123456789012345678");
    assert.equal(file.cloud_records.stock_spin_offs[0].child_basis_pct_aud, "12.123456789012");
    assert.equal(file.on_this_iphone, undefined);

    const authorization = (await requested[0].allHeaders()).authorization;
    await plain.getByRole("button", { name: "Sign out", exact: true }).last().click();
    const revoked = await plain.request.post(endpoint, { data: {}, headers: { ...protectionHeaders, authorization } });
    assert.equal(revoked.status(), 401);
    await plain.close();

    const protectedPage = await signIn(other);
    await protectedPage.getByRole("button", { name: "Download account data", exact: true }).click();
    await protectedPage.getByText("Verify your authenticator before exporting your account.", { exact: true }).waitFor();
    const code = protectedPage.getByLabel("Authenticator code", { exact: true });
    assert.ok(await protectedPage.getByRole("button", { name: "Verify and download", exact: true }).isDisabled());
    if (Date.now() % 30_000 > 25_000) {
      await new Promise((resolve) => setTimeout(resolve, 30_500 - Date.now() % 30_000));
    }
    await code.fill(currentCode(other.secret));
    const isolated = await download(protectedPage, "Verify and download");
    assert.equal(isolated.cloud_records.account[0].id, other.id);
    assert.equal(isolated.cloud_records.account[0].authenticator_enabled, true);
    assert.deepEqual(isolated.cloud_records.listed_holdings, []);
    assert.deepEqual(isolated.cloud_records.private_excerpts, []);
    assert.deepEqual(isolated.cloud_records.stock_splits, []);
    assert.deepEqual(isolated.cloud_records.stock_spin_offs, []);
    assert.ok(await protectedPage.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  } finally { await browser.close(); }
});
