import assert from "node:assert/strict";
import { test } from "node:test";
import { deflateSync } from "node:zlib";
import { chromium } from "playwright-core";

const {
  PRIVATE_MARKETS_TEST_ORIGIN: origin, PRIVATE_MARKETS_TEST_CHROME: executablePath,
  PRIVATE_MARKETS_TEST_EMAIL: email, PRIVATE_MARKETS_TEST_PASSWORD: password,
  PRIVATE_MARKETS_OTHER_EMAIL: otherEmail, PRIVATE_MARKETS_OTHER_PASSWORD: otherPassword,
  VERCEL_OIDC_TOKEN: previewToken,
  PRIVATE_MARKETS_TEST_DOCUMENT_AI: testDocumentAI,
} = process.env;

function makePDF(objects) {
  const parts = [Buffer.from("%PDF-1.4\n")];
  let size = parts[0].length;
  const offsets = objects.map((object, index) => {
    const offset = size;
    const body = Buffer.concat([Buffer.from(`${index + 1} 0 obj\n`), Buffer.from(object), Buffer.from("\nendobj\n")]);
    parts.push(body);
    size += body.length;
    return String(offset).padStart(10, "0") + " 00000 n ";
  });
  const count = objects.length + 1;
  parts.push(Buffer.from(`xref\n0 ${count}\n0000000000 65535 f \n${offsets.join("\n")}\ntrailer\n<< /Size ${count} /Root 1 0 R >>\nstartxref\n${size}\n%%EOF\n`));
  return Buffer.concat(parts);
}

function stream(body, properties = "") {
  return Buffer.concat([
    Buffer.from(`<< /Length ${body.length} ${properties} >>\nstream\n`),
    Buffer.from(body),
    Buffer.from("\nendstream"),
  ]);
}

const page = (content, resources) =>
  `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << ${resources} >> /Contents ${content} 0 R >>`;

function pdfWithText(first, second) {
  const textStream = (value) => stream(value ? `BT /F1 12 Tf 72 720 Td (${value}) Tj ET` : "");
  return makePDF([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    page(5, "/Font << /F1 7 0 R >>"), page(6, "/Font << /F1 7 0 R >>"),
    textStream(first), textStream(second),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ]);
}

async function pdfWithScan(browserPage) {
  const width = 1000;
  const height = 280;
  const pixels = await browserPage.evaluate(({ width, height }) => {
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "white";
    ctx.fillRect(0, 0, width, height);
    ctx.fillStyle = "black";
    ctx.font = "38px Arial";
    ctx.fillText("The scanned statement reports a pending review.", 35, 90);
    ctx.fillText("The sample portfolio contains three positions.", 35, 150);
    const rgba = ctx.getImageData(0, 0, width, height).data;
    return Array.from({ length: width * height }, (_, index) => rgba[index * 4]);
  }, { width, height });
  return makePDF([
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
    page(5, "/Font << /F1 7 0 R >>"), page(6, "/XObject << /Scan 8 0 R >>"),
    stream("BT /F1 12 Tf 72 720 Td (Report cover) Tj ET"),
    stream("q 560 0 0 156.8 26 540 cm /Scan Do Q"),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    stream(deflateSync(Buffer.from(pixels)),
      `/Type /XObject /Subtype /Image /Width ${width} /Height ${height} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode`),
  ]);
}

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
    const browserErrors = [];
    owner.on("pageerror", (error) => browserErrors.push(error.message));
    const save = owner.getByRole("button", { name: "Save excerpt", exact: true });
    const titleField = owner.getByLabel("Excerpt title");
    const draft = owner.getByLabel("Reviewed excerpt");
    const permission = owner.getByLabel("I have permission to store this excerpt in Stock Tracker.");
    const upload = owner.locator('input[type="file"]');
    const importButton = owner.getByRole("button", { name: "Extract text from a file", exact: true });
    const submissions = [];
    owner.on("request", (request) => {
      if (request.url() === api && request.postDataJSON()?.action === "save_document") submissions.push(request);
    });
    const chooser = owner.waitForEvent("filechooser");
    await importButton.click();
    await (await chooser).setFiles({ name: "long.txt", mimeType: "text/plain", buffer: Buffer.from("é".repeat(4_499) + "📈more") });
    await owner.getByText("Only part of the file was imported.", { exact: false }).waitFor();
    assert.equal(await draft.inputValue(), "é".repeat(4_499));
    assert.equal(await titleField.inputValue(), "long");
    assert.ok(await save.isDisabled());

    await permission.check();
    await upload.setInputFiles({ name: "unreadable.txt", mimeType: "text/plain", buffer: Buffer.from([0xff, 0xfe, 0xff]) });
    await owner.getByText("Save the text file as UTF-8 and try again.", { exact: true }).waitFor();
    assert.equal(await draft.inputValue(), "é".repeat(4_499));

    await upload.setInputFiles({ name: "empty.pdf", mimeType: "application/pdf", buffer: pdfWithText("", "") });
    await owner.getByText("This PDF has no readable text.", { exact: false }).waitFor();
    assert.equal(await draft.inputValue(), "é".repeat(4_499));

    const importPDF = {
      name: title + ".pdf", mimeType: "application/pdf",
      buffer: pdfWithText("The fund statement records that the sample portfolio contains three positions.", "The manager review is still pending."),
    };
    await upload.setInputFiles(importPDF);
    await owner.getByText("Review and edit the extracted text before saving.", { exact: true }).waitFor();
    assert.equal(await titleField.inputValue(), title);
    assert.equal(await draft.inputValue(),
      "[Page 1]\nThe fund statement records that the sample portfolio contains three positions.\n\n[Page 2]\nThe manager review is still pending.");
    assert.ok(await save.isDisabled());
    assert.equal(submissions.length, 0);

    await permission.check();
    const scanned = { name: "Scanned fund statement.pdf", mimeType: "application/pdf", buffer: await pdfWithScan(owner) };
    const languagePath = new URL("/api/private-markets/ocr/eng.traineddata.gz", origin).href;
    let allowData;
    const waitingForCancel = new Promise((resume) => { allowData = resume; });
    const delayLanguage = async (route) => {
      await waitingForCancel;
      await route.continue();
    };
    await owner.route(languagePath, delayLanguage);
    try {
      await upload.setInputFiles(scanned);
      await owner.getByText("Reading scanned pages…", { exact: true }).waitFor();
      await owner.getByRole("button", { name: "Cancel import", exact: true }).click();
      assert.equal(await titleField.inputValue(), title);
      assert.match(await draft.inputValue(), /^\[Page 1\]\nThe fund statement records/);
    } finally {
      allowData();
      await owner.unroute(languagePath, delayLanguage);
    }

    const scanRequests = [];
    const trackScan = (request) => scanRequests.push([request.method(), new URL(request.url())]);
    owner.on("request", trackScan);
    await upload.setInputFiles(scanned);
    await owner.getByText("Check the recognized text against the scan before saving.", { exact: true }).waitFor();
    owner.off("request", trackScan);
    assert.match(await draft.inputValue(), /^\[Page 1\]\nReport cover\n\n\[Page 2\]\nThe scanned statement reports a pending review\./);
    assert.match(await draft.inputValue(), /The sample portfolio contains three positions\./);
    assert.ok(scanRequests.some(([method, url]) => method === "GET" && url.href === languagePath));
    assert.ok(scanRequests.some(([method, url]) => method === "GET" && url.pathname.includes("tesseract-core")));
    assert.ok(scanRequests.every(([method, url]) => method === "GET" && url.origin === origin));
    assert.deepEqual(browserErrors, []);
    assert.ok(await save.isDisabled());
    assert.equal(submissions.length, 0);

    await upload.setInputFiles(importPDF);
    await owner.getByText("Review and edit the extracted text before saving.", { exact: true }).waitFor();
    await permission.check();
    await draft.fill(excerpt + " Updated.");
    assert.ok(await save.isDisabled());
    await permission.check();

    const saved = owner.waitForResponse((response) => response.url() === api && response.request().postDataJSON()?.action === "save_document");
    await save.click();
    const response = await saved;
    assert.equal(response.status(), 201);
    assert.deepEqual(response.request().postDataJSON(), {
      action: "save_document", title, excerpt: excerpt + " Updated.", authorized: true,
    });
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
