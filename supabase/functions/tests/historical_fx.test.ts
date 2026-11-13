import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { historicalCashConversion } from "../market-workspace/historical_fx.ts";
import { HttpError } from "../_shared/server/http.ts";

const now = Date.UTC(2026, 0, 20, 12);
const header = "KEY,FREQ,CURRENCY,CURRENCY_DENOM,EXR_TYPE,EXR_SUFFIX,TIME_PERIOD,OBS_VALUE";
const row = (currency: string, date: string, value: string) =>
  `EXR.D.${currency}.EUR.SP00.A,D,${currency},EUR,SP00,A,${date},${value}`;
const csv = (...rows: string[]) => new Response([header, ...rows].join("\r\n"));

Deno.test("historical FX uses the latest common day, never a later rate, and rounds once", async () => {
  let calls = 0;
  const request = ((input: URL) => {
    calls++;
    assertEquals(input.hostname, "data-api.ecb.europa.eu");
    assertEquals(input.pathname, "/service/data/EXR/D.USD+AUD.EUR.SP00.A");
    assertEquals(input.searchParams.get("startPeriod"), "2026-01-11");
    assertEquals(input.searchParams.get("endPeriod"), "2026-01-18");
    assertEquals(input.searchParams.has("amount"), false);
    return Promise.resolve(csv(row("AUD", "2026-01-16", "2"), row("USD", "2026-01-16", "1"),
      row("USD", "2026-01-17", "1.2"), row("USD", "2026-01-19", "2"), row("AUD", "2026-01-19", "2")));
  }) as typeof fetch;
  const input = { currency: "AUD", date: "2026-01-18", amount: "100.01" };
  const [first, second] = await Promise.all([
    historicalCashConversion(input, now, request),
    historicalCashConversion({ ...input, amount: "50" }, now, request),
  ]);
  assertEquals(first, { usdAmount: 50.01, fx: { source: "ECB", currency: "AUD", amount: "100.01", usd_per_unit: "0.5", rate_date: "2026-01-16" } });
  assertEquals(second.usdAmount, 25);
  assertEquals(calls, 1);
});

Deno.test("historical FX uses direct EUR observations and retries unavailable upstream data", async () => {
  const input = { currency: "EUR", date: "2026-01-14", amount: "10" };
  const unavailable = (() => Promise.resolve(new Response("", { status: 503 }))) as typeof fetch;
  await assertRejects(() => historicalCashConversion(input, now, unavailable), HttpError, "temporarily unavailable");
  const request = ((input: URL) => {
    assertEquals(input.pathname, "/service/data/EXR/D.USD.EUR.SP00.A");
    return Promise.resolve(csv(row("USD", "2026-01-14", "1.125")));
  }) as typeof fetch;
  const converted = await historicalCashConversion(input, now, request);
  assertEquals(converted.usdAmount, 11.25);
});

Deno.test("historical FX rejects invalid inputs, missing observations and stale rates", async () => {
  const request = (() => Promise.resolve(csv(row("USD", "2026-01-10", "1.2"), row("JPY", "2026-01-10", "180")))) as typeof fetch;
  const input = { currency: "JPY", date: "2026-01-19", amount: "500" };
  for (const invalid of [
    { currency: "AUD?x" }, { currency: "USD" }, { date: "2026-02-30" }, { date: "2026-01-21" },
    { date: "1999-01-01" }, { amount: "0" }, { amount: "-500" }, { amount: "1.000000001" },
  ]) {
    await assertRejects(() => historicalCashConversion({ ...input, ...invalid }, now, request), HttpError);
  }
  await assertRejects(() => historicalCashConversion(input, now, request), HttpError, "within seven days");
});
