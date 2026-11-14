import assert from "node:assert/strict";
import { test } from "node:test";
import { chromium } from "playwright-core";

const origin = process.env.PRIVATE_MARKETS_TEST_ORIGIN;
const executablePath = process.env.PRIVATE_MARKETS_TEST_CHROME;

async function signIn(page, email, password) {
  await page.goto(new URL("/login?next=/private-markets", origin).href);
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForURL("**/private-markets", { timeout: 30_000 });
  await page.getByRole("button", { name: "Sign out", exact: true }).waitFor();
}

test("Private Markets renders sourced rounds and keeps research account-scoped", {
  skip: !origin || !executablePath,
  timeout: 300_000,
}, async () => {
  const browser = await chromium.launch({ executablePath, headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(new URL("/markets", origin).href);
    await page.getByRole("navigation", { name: "Main" }).getByRole("link", { name: "Private Markets", exact: true }).click();
    await page.getByRole("heading", { name: "Private Markets", exact: true }).waitFor();
    const capability = page.getByRole("article").filter({ has: page.getByRole("heading", { name: "Capability X Limited", exact: true }) });
    await capability.waitFor();
    await capability.getByText("Terms and disclosures", { exact: false }).click();
    await capability.getByText("Audited financial statements", { exact: true }).first().waitFor();
    assert.match(await capability.getByRole("link", { name: "Financial disclosure" }).first().getAttribute("href"), /^https:\/\//);

    await page.getByLabel("Availability", { exact: true }).selectOption("closed");
    assert.equal(await capability.isVisible(), true);
    assert.equal(await page.getByRole("heading", { name: "ABC Commodities Limited", exact: true }).count(), 0);
    await page.getByLabel("Availability", { exact: true }).selectOption("");
    await page.getByText("Investment size and traction", { exact: true }).click();
    await page.getByLabel("Reported currency").selectOption("USD");
    await page.getByLabel("Disclosed traction", { exact: true }).check();
    await page.getByRole("heading", { name: "Heidi", exact: true }).first().waitFor();
    assert.equal(await capability.count(), 0);
    await page.getByRole("button", { name: "Select Heidi Series B for research", exact: true }).click();
    await page.getByRole("button", { name: "Select Heidi Series C for research", exact: true }).click();
    await page.getByRole("heading", { name: "Compare funding rounds", exact: true }).waitFor();
    await page.getByRole("link", { name: "Round disclosure", exact: true }).first().waitFor();
    await page.getByRole("button", { name: "Select Heidi Series B for research", exact: true }).click();
    await page.getByRole("button", { name: "Select Heidi Series C for research", exact: true }).click();

    for (const action of ["reports", "confirmed_holdings", "applications"]) {
      const response = await page.request.post(new URL("/api/workspace-service/private-markets", origin).href, { data: { action } });
      assert.equal(response.status(), 401);
      assert.equal(response.headers()["cache-control"], "no-store");
    }
    const handoff = await page.request.post(new URL("/api/workspace-service/private-markets", origin).href, { data: { action: "handoff" } });
    assert.equal(handoff.status(), 403);
    await page.getByRole("radio", { name: "AI Research", exact: true }).click();
    await page.getByText("Sign in for AI research and saved reports", { exact: true }).waitFor();

    await page.setViewportSize({ width: 390, height: 844 });
    await page.getByRole("button", { name: "Open menu" }).click();
    await page.getByRole("navigation", { name: "Main" }).getByRole("link", { name: "Private Markets", exact: true }).click();
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));

    const email = process.env.PRIVATE_MARKETS_TEST_EMAIL;
    const password = process.env.PRIVATE_MARKETS_TEST_PASSWORD;
    if (email && password) {
      await signIn(page, email, password);
      await page.getByText("Search with AI", { exact: true }).click();
      await page.getByLabel("What are you looking for?").fill("Show Heidi's closed Series C round");
      const search = page.getByRole("button", { name: "Search published rounds" });
      assert.equal(await search.isDisabled(), true);
      await page.getByLabel("Allow Stock Tracker to send this search to its AI provider.").check();
      await search.click();
      await page.getByRole("heading", { name: "AI search results" }).waitFor({ timeout: 50_000 });
      await page.getByRole("button", { name: "Select Heidi Series C for research", exact: true }).click();
      await page.getByRole("button", { name: "Research selected rounds (1)", exact: true }).click();
      await page.getByRole("heading", { name: "AI Investment Research", exact: true }).waitFor();
      const question = "What does Heidi disclose about its Series C round, and what remains unanswered?";
      await page.getByLabel("Research question").fill(question);
      const run = page.getByRole("button", { name: "Run research", exact: true });
      assert.equal(await run.isDisabled(), true);
      await page.getByLabel("Allow Stock Tracker to send this question and the selected published sources to its AI provider.").check();
      const generated = page.waitForResponse((response) => response.url().endsWith("/api/workspace-service/private-markets") &&
        response.request().postDataJSON()?.action === "research", { timeout: 70_000 });
      await run.click();
      const researchResponse = await generated;
      const report = await researchResponse.json();
      assert.equal(researchResponse.status(), 200, JSON.stringify(report.error));
      await page.getByRole("heading", { name: "Reported figures", exact: true }).waitFor();
      assert.match(await page.getByRole("link", { name: "Heidi · Series C", exact: true }).first().getAttribute("href"), /^https:\/\//);
      assert.equal(await run.isDisabled(), true);

      if (process.env.PRIVATE_MARKETS_TEST_COMMITTEE === "true") {
        await page.getByRole("radio", { name: "Investment Committee", exact: true }).click();
        const committeeQuestion = "Review the disclosed business model, financing and risks in Heidi's Series C announcement.";
        await page.getByLabel("Research question").fill(committeeQuestion);
        await page.getByLabel("Allow Stock Tracker to send this question and the selected published sources to its AI provider.").check();
        const accepted = page.waitForResponse((response) => response.url().endsWith("/api/workspace-service/private-markets") &&
          response.request().postDataJSON()?.action === "research", { timeout: 30_000 });
        await page.getByRole("button", { name: "Run committee", exact: true }).click();
        const committeeResponse = await accepted;
        assert.equal(committeeResponse.status(), 202);
        await page.getByRole("heading", { name: committeeQuestion, exact: true }).waitFor({ timeout: 190_000 });
        await page.getByRole("heading", { name: "Investment Committee", exact: true }).waitFor();
      }

      await page.reload();
      await page.getByRole("radio", { name: "AI Research", exact: true }).click();
      await page.getByRole("button", { name: new RegExp("^" + question.split(",")[0]) }).click();
      await page.getByRole("heading", { name: "Reported figures", exact: true }).waitFor();
      await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();
      if (process.env.PRIVATE_MARKETS_TEST_LEDGER === "true") {
        const position = page.getByRole("article").filter({ has: page.getByRole("heading", { name: "Stock Tracker browser holding", exact: true }) });
        await position.getByText("Provider confirmed", { exact: true }).waitFor();
        await position.getByText("Dated provider statement", { exact: false }).waitFor();
        await position.getByText("Capital activity").click();
        await position.getByText("QA capital call notice", { exact: false }).waitFor();
        await position.getByText("QA distribution receipt", { exact: false }).waitFor();
        await page.getByText("Ownership confirmed", { exact: true }).first().waitFor();
      } else {
        await page.getByText("No provider-confirmed holdings", { exact: true }).waitFor();
        await page.getByText("No recorded applications", { exact: true }).waitFor();
      }
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
      await page.goto(new URL("/portfolio", origin).href);
      await page.getByRole("link", { name: "Private portfolio", exact: true }).click();
      await page.waitForURL("**/private-markets?view=portfolio");
      await page.getByRole("heading", { name: "My Private Portfolio", exact: true }).waitFor();

      const otherEmail = process.env.PRIVATE_MARKETS_OTHER_EMAIL;
      const otherPassword = process.env.PRIVATE_MARKETS_OTHER_PASSWORD;
      if (otherEmail && otherPassword) {
        await page.getByRole("button", { name: "Sign out", exact: true }).click();
        await page.getByText("Sign in to see your private portfolio", { exact: true }).waitFor();
        await signIn(page, otherEmail, otherPassword);
        const otherRequest = page.waitForRequest((request) => request.url().endsWith("/api/workspace-service/private-markets") &&
          request.method() === "POST" && request.postDataJSON()?.action === "reports");
        await page.getByRole("radio", { name: "AI Research", exact: true }).click();
        const authorization = (await (await otherRequest).allHeaders()).authorization;
        assert.ok(authorization?.startsWith("Bearer "));
        await page.getByText("No saved reports", { exact: true }).waitFor();
        const forbidden = await page.request.post(new URL("/api/workspace-service/private-markets", origin).href, {
          headers: { Authorization: authorization }, data: { action: "report", id: report.id },
        });
        assert.equal(forbidden.status(), 404);
        assert.equal(forbidden.headers()["cache-control"], "no-store");
        await page.getByRole("radio", { name: "Portfolio & applications", exact: true }).click();
        await page.getByText("No provider-confirmed holdings", { exact: true }).waitFor();
        await page.getByText("No recorded applications", { exact: true }).waitFor();
      }
    }
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
  }
});
