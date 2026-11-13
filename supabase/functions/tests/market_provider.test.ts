// Market-data providers. Every test runs on an injected fetch and an instant sleep:
// nothing here touches the network, and the "keys" are the words below.
//
//   npx -y deno test --allow-read --allow-env --no-check=remote supabase/functions/tests/market_provider.test.ts

import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  asxStock,
  type Bar,
  type BarSeries,
  cryptoAsset,
  type DataProvenance,
  type Instrument,
  listed,
  makeBarSeries,
  marketProvenance,
  type Quote,
  usETF,
  usStock,
} from "../_shared/trading/market.ts";
import { AlpacaDataProvider, type AlpacaDataProviderOptions } from "../_shared/market/alpaca.ts";
import { CoinGeckoVolumeSource, type CoinGeckoVolumeSourceOptions } from "../_shared/market/coingecko.ts";
import { FixtureDataProvider } from "../_shared/market/fixture.ts";
import { providerFromEnv, RoutedProvider, UITestFixtureProvider, uiTestCloses, YahooFinanceProvider } from "../_shared/market/index.ts";
import { type YahooFinanceProviderOptions, yahooProvenance } from "../_shared/market/yahoo.ts";
import { isTradingDay, timeZone } from "../_shared/trading/calendar.ts";
import { CachedVolumeSource, memoryVolumeStore } from "../_shared/market/volume_cache.ts";
import { type MarketDataProvider, parseVenueTime, ProviderError, snapshot } from "../_shared/market/provider.ts";

const KEY_ID = "test-key-id";
const SECRET = "test-secret";
const GECKO_KEY = "test-coingecko-key";

const MINUTE = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;
/** Thursday 12 November 2026, 20:00 UTC — 3 pm in New York, an hour before the close. */
const NOW = Date.UTC(2026, 10, 12, 20, 0, 0);
/** Midnight in New York on a day of November 2026 (UTC−5): how Alpaca stamps a daily stock bar. */
const nyMidnight = (day: number) => Date.UTC(2026, 10, day, 5);

const AAPL = usStock("AAPL", "Apple");
const MSFT = usStock("MSFT", "Microsoft");
const TSLA = usStock("TSLA", "Tesla");
const SPY = usETF("SPY", "S&P 500 ETF");
const BTC = cryptoAsset("BTC", "Bitcoin");
const ETH = cryptoAsset("ETH", "Ethereum");
const BHP = asxStock("BHP", "BHP Group");
const VOD = listed("VOD", "lse", "Vodafone");

const CONSOLIDATED: DataProvenance = { kind: "market", source: "Alpaca (consolidated)", delaySeconds: 0 };
const IEX: DataProvenance = { kind: "market", source: "Alpaca (IEX)", delaySeconds: 0 };
const ALPACA_CRYPTO: DataProvenance = { kind: "market", source: "Alpaca crypto", delaySeconds: 0 };
const FIXTURE: DataProvenance = { kind: "fixture", source: "fixture", delaySeconds: 0 };

// ---------------------------------------------------------------------------------------
// A stand-in for fetch that records what was asked.

interface Call {
  raw: string;
  url: URL;
  headers: Headers;
  init: RequestInit;
}

type Reply = (call: Call, index: number) => Response | Promise<Response>;

function recorder(reply: Reply) {
  const calls: Call[] = [];
  const fake = ((input: string | URL | Request, init?: RequestInit) => {
    const raw = String(input);
    const call: Call = { raw, url: new URL(raw), headers: new Headers(init?.headers), init: init ?? {} };
    calls.push(call);
    try {
      return Promise.resolve(reply(call, calls.length - 1));
    } catch (error) {
      return Promise.reject(error);
    }
  }) as typeof fetch;
  return { fetch: fake, calls };
}

function harness(reply: Reply, options: Partial<AlpacaDataProviderOptions> = {}) {
  const { fetch: fake, calls } = recorder(reply);
  const sleeps: number[] = [];
  const events: Record<string, unknown>[] = [];
  const provider = new AlpacaDataProvider({
    keyId: KEY_ID,
    secret: SECRET,
    fetch: fake,
    sleep: (ms) => {
      sleeps.push(ms);
      return Promise.resolve();
    },
    log: (event) => events.push(event),
    ...options,
  });
  return { provider, calls, sleeps, events };
}

function geckoHarness(reply: Reply, options: Partial<CoinGeckoVolumeSourceOptions> = {}) {
  const { fetch: fake, calls } = recorder(reply);
  const sleeps: number[] = [];
  const events: Record<string, unknown>[] = [];
  const source = new CoinGeckoVolumeSource({
    apiKey: GECKO_KEY,
    fetch: fake,
    sleep: (ms) => {
      sleeps.push(ms);
      return Promise.resolve();
    },
    log: (event) => events.push(event),
    ...options,
  });
  return { source, calls, sleeps, events };
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}

/** A fetch that never answers until it is aborted, the way a hung connection behaves. */
const hang: Reply = (call) =>
  new Promise<Response>((_resolve, reject) => {
    call.init.signal!.addEventListener("abort", () => reject(new DOMException("The operation was aborted.", "AbortError")));
  });

const stamp = (time: number) => new Date(time).toISOString().replace(".000Z", "Z");
const feedOf = (call: Call) => call.url.searchParams.get("feed");
const symbolsOf = (call: Call) => call.url.searchParams.get("symbols");

/** A bar the way Alpaca sends it. */
function wireBar(time: number, close: number, volume = 1_000) {
  return { t: stamp(time), o: close - 0.5, h: close + 1, l: close - 1, c: close, v: volume, n: 12, vw: close };
}

/** The same bar the way the engine holds it. */
function bar(time: number, close: number, volume = 1_000): Bar {
  return { time, open: close - 0.5, high: close + 1, low: close - 1, close, volume };
}

function assertNoSecrets(value: unknown) {
  const text = typeof value === "string" ? value : JSON.stringify(value);
  assert(!text.includes(KEY_ID), "the key id leaked");
  assert(!text.includes(SECRET), "the secret leaked");
  assert(!text.includes(GECKO_KEY), "the CoinGecko key leaked");
}

// ---------------------------------------------------------------------------------------
// Daily stock bars: the consolidated tape first, IEX only when it can't be had

Deno.test("daily stock bars: consolidated first — paged, trimmed to the last `count`, volume market-wide", async () => {
  // AAPL's history is split across the two pages, as it is when `limit` runs out mid-symbol.
  const { provider, calls } = harness((call) => {
    if (call.url.searchParams.get("page_token") === null) {
      return json({
        bars: { AAPL: [wireBar(nyMidnight(5), 101), wireBar(nyMidnight(6), 102), wireBar(nyMidnight(9), 103)] },
        next_page_token: "page-2",
      });
    }
    return json({
      bars: {
        AAPL: [wireBar(nyMidnight(10), 104), wireBar(nyMidnight(11), 105), wireBar(nyMidnight(12), 106, 250)],
        MSFT: [wireBar(nyMidnight(11), 410), wireBar(nyMidnight(12), 412)],
      },
      next_page_token: null,
    });
  });

  const result = await provider.bars([AAPL, MSFT], "day", 4, NOW);

  assertEquals(calls.length, 2); // both pages of the consolidated request; IEX is never asked
  assertEquals(calls.map(feedOf), ["sip", "sip"]);
  assertEquals(calls[1].url.searchParams.get("page_token"), "page-2");
  for (const name of ["symbols", "timeframe", "start", "end", "limit", "adjustment", "feed", "sort"]) {
    assertEquals(calls[1].url.searchParams.get(name), calls[0].url.searchParams.get(name), `${name} changed between pages`);
  }

  assertEquals(result.failures, {});
  assertEquals(Object.keys(result.series).sort(), ["us:AAPL", "us:MSFT"]);

  const aapl = result.series["us:AAPL"];
  // Six came back; the last four are kept, spanning both pages. The final one is today's
  // still-forming bar, and it is passed on exactly as sent.
  assertEquals(aapl.bars, [bar(nyMidnight(9), 103), bar(nyMidnight(10), 104), bar(nyMidnight(11), 105), bar(nyMidnight(12), 106, 250)]);
  assertEquals(aapl.instrument, AAPL);
  assertEquals(aapl.timeframe, "day");
  assertEquals(aapl.provenance, CONSOLIDATED);
  assertEquals(aapl.volumeIsMarketWide, true);
  assertEquals(aapl.fetchedAt, NOW);

  // Fewer than asked for is returned as it is — never padded.
  assertEquals(result.series["us:MSFT"].bars, [bar(nyMidnight(11), 410), bar(nyMidnight(12), 412)]);
  assertEquals(result.series["us:MSFT"].volumeIsMarketWide, true);
});

Deno.test("daily stock bars: the consolidated request ends 16 minutes ago, is adjusted and ascending, and carries the keys only in headers", async () => {
  const { provider, calls } = harness(() =>
    json({ bars: { AAPL: [wireBar(nyMidnight(12), 106)], SPY: [wireBar(nyMidnight(12), 590)] }, next_page_token: null })
  );

  await provider.bars([AAPL, SPY], "day", 3, NOW);

  assertEquals(calls.length, 1);
  const [call] = calls;
  assertEquals(call.url.origin, "https://data.alpaca.markets");
  assertEquals(call.url.pathname, "/v2/stocks/bars");
  assertEquals(call.init.method, "GET");
  assertEquals(call.init.redirect, "manual");
  assert(call.init.signal instanceof AbortSignal);

  const query = call.url.searchParams;
  assertEquals(query.get("symbols"), "AAPL,SPY");
  assertEquals(query.get("timeframe"), "1Day");
  assertEquals(query.get("feed"), "sip");
  assertEquals(query.get("adjustment"), "all");
  assertEquals(query.get("sort"), "asc");
  assertEquals(query.get("limit"), "10000");
  // 3 bars → 3 × 1.6 + 10 = 14.8, rounded up to 15 calendar days back.
  assertEquals(query.get("start"), stamp(NOW - 15 * DAY));
  assertEquals(query.get("start"), "2026-10-28T20:00:00Z");
  // The free plan serves the consolidated tape once it is 15 minutes old.
  assertEquals(query.get("end"), stamp(NOW - 16 * MINUTE));
  assertEquals(query.get("end"), "2026-11-12T19:44:00Z");
  assertEquals(query.get("page_token"), null);

  assertEquals(call.headers.get("APCA-API-KEY-ID"), KEY_ID);
  assertEquals(call.headers.get("APCA-API-SECRET-KEY"), SECRET);
  assertNoSecrets(call.raw);
});

Deno.test("daily stock bars: HTTP 403 or 422 on the consolidated tape (not on this plan) falls back to IEX, marked as one venue's volume", async () => {
  for (const status of [403, 422]) {
    const { provider, calls, sleeps } = harness((call) =>
      feedOf(call) === "sip"
        ? json({ code: 42210000, message: "subscription does not permit querying recent SIP data" }, status)
        : json({ bars: { AAPL: [wireBar(nyMidnight(11), 105), wireBar(nyMidnight(12), 106)], MSFT: [wireBar(nyMidnight(12), 412)] }, next_page_token: null })
    );

    const result = await provider.bars([AAPL, MSFT], "day", 5, NOW);

    assertEquals(calls.map(feedOf), ["sip", "iex"], `HTTP ${status}`);
    assertEquals(sleeps, []); // a refusal is not retried
    // The IEX request is today's behaviour: same symbols and window, no `end`.
    assertEquals(symbolsOf(calls[1]), "AAPL,MSFT");
    assertEquals(calls[1].url.searchParams.get("end"), null);
    assertEquals(calls[1].url.searchParams.get("start"), calls[0].url.searchParams.get("start"));
    assertEquals(calls[1].url.searchParams.get("adjustment"), "all");
    assertEquals(calls[1].url.searchParams.get("timeframe"), "1Day");

    assertEquals(result.failures, {});
    assertEquals(result.series["us:AAPL"].bars, [bar(nyMidnight(11), 105), bar(nyMidnight(12), 106)]);
    assertEquals(result.series["us:AAPL"].provenance, IEX);
    assertEquals(result.series["us:AAPL"].volumeIsMarketWide, false);
    assertEquals(result.series["us:MSFT"].provenance, IEX);
    assertEquals(result.series["us:MSFT"].volumeIsMarketWide, false);
  }
});

Deno.test("daily stock bars: an empty consolidated answer falls back to IEX", async () => {
  for (const empty of [{ bars: {}, next_page_token: null }, { bars: null, next_page_token: null }, { next_page_token: null }, { bars: { AAPL: [] } }]) {
    const { provider, calls } = harness((call) => feedOf(call) === "sip" ? json(empty) : json({ bars: { AAPL: [wireBar(nyMidnight(12), 106)] }, next_page_token: null }));

    const result = await provider.bars([AAPL], "day", 5, NOW);

    assertEquals(calls.map(feedOf), ["sip", "iex"]);
    assertEquals(result.failures, {});
    assertEquals(result.series["us:AAPL"].provenance, IEX);
    assertEquals(result.series["us:AAPL"].volumeIsMarketWide, false);
  }
});

Deno.test("daily stock bars: when the consolidated tape answers for only some symbols, just the rest are asked of IEX", async () => {
  const { provider, calls } = harness((call) =>
    feedOf(call) === "sip"
      ? json({ bars: { AAPL: [wireBar(nyMidnight(12), 106)], MSFT: null }, next_page_token: null })
      : json({ bars: { MSFT: [wireBar(nyMidnight(12), 412)] }, next_page_token: null })
  );

  const result = await provider.bars([AAPL, MSFT, TSLA], "day", 5, NOW);

  assertEquals(calls.length, 2); // one extra request, not one per symbol
  assertEquals(calls.map(feedOf), ["sip", "iex"]);
  assertEquals(symbolsOf(calls[0]), "AAPL,MSFT,TSLA");
  assertEquals(symbolsOf(calls[1]), "MSFT,TSLA");

  // Feeds are never mixed inside one series: each is wholly one or the other.
  assertEquals(result.series["us:AAPL"].provenance, CONSOLIDATED);
  assertEquals(result.series["us:AAPL"].volumeIsMarketWide, true);
  assertEquals(result.series["us:MSFT"].provenance, IEX);
  assertEquals(result.series["us:MSFT"].volumeIsMarketWide, false);
  assertEquals(result.failures, { "us:TSLA": "Alpaca has no price history for TSLA" });
});

Deno.test("daily stock bars: an outage on the consolidated tape is a failure — it does NOT quietly fall back to IEX", async () => {
  const iexWouldAnswer = json({ bars: { AAPL: [wireBar(nyMidnight(12), 106)] }, next_page_token: null });

  const down = harness((call) => feedOf(call) === "sip" ? json({ message: "internal" }, 500) : iexWouldAnswer.clone());
  assertEquals(await down.provider.bars([AAPL, MSFT], "day", 5, NOW), {
    series: {},
    failures: { "us:AAPL": "Alpaca returned HTTP 500", "us:MSFT": "Alpaca returned HTTP 500" },
  });
  assertEquals(down.calls.map(feedOf), ["sip", "sip", "sip"]);

  const limited = harness((call) => feedOf(call) === "sip" ? json({ message: "too many requests." }, 429) : iexWouldAnswer.clone(), { maxAttempts: 2 });
  assertEquals((await limited.provider.bars([AAPL], "day", 5, NOW)).failures, { "us:AAPL": "Alpaca is rate limiting requests (HTTP 429)" });
  assertEquals(limited.calls.map(feedOf), ["sip", "sip"]);

  const slow = harness((call) => feedOf(call) === "sip" ? hang(call, 0) : iexWouldAnswer.clone(), { timeoutMs: 5, maxAttempts: 1 });
  assertEquals((await slow.provider.bars([AAPL], "day", 5, NOW)).failures, { "us:AAPL": "The request timed out" });
  assertEquals(slow.calls.map(feedOf), ["sip"]);

  const garbled = harness((call) => feedOf(call) === "sip" ? new Response("<html>", { status: 200 }) : iexWouldAnswer.clone());
  assertEquals((await garbled.provider.bars([AAPL], "day", 5, NOW)).failures, { "us:AAPL": "Alpaca returned an unreadable response" });
  assertEquals(garbled.calls.map(feedOf), ["sip"]);

  // 400 and 401 aren't "not on this plan" either.
  for (const status of [400, 401, 404]) {
    const refused = harness((call) => feedOf(call) === "sip" ? json({ message: "no" }, status) : iexWouldAnswer.clone());
    assertEquals(Object.keys((await refused.provider.bars([AAPL], "day", 5, NOW)).series), []);
    assertEquals(refused.calls.map(feedOf), ["sip"]);
  }
});

Deno.test("daily stock bars: if the IEX fallback fails, only the instruments that needed it fail", async () => {
  const { provider, calls } = harness((call) =>
    feedOf(call) === "sip" ? json({ bars: { AAPL: [wireBar(nyMidnight(12), 106)] }, next_page_token: null }) : json({ message: "internal" }, 500), { maxAttempts: 1 });

  const result = await provider.bars([AAPL, MSFT], "day", 5, NOW);

  assertEquals(calls.map(feedOf), ["sip", "iex"]);
  assertEquals(Object.keys(result.series), ["us:AAPL"]);
  assertEquals(result.series["us:AAPL"].provenance, CONSOLIDATED);
  assertEquals(result.failures, { "us:MSFT": "Alpaca returned HTTP 500" });
});

Deno.test("daily stock bars: a missing symbol, null bars or only unusable bars is a failure — no series is made up", async () => {
  const { provider, calls } = harness((call) =>
    feedOf(call) === "sip"
      ? json({
        bars: {
          AAPL: [wireBar(nyMidnight(12), 106)],
          MSFT: null,
          SPY: [],
          // Zero prices, a price sent as text, and a bar with no readable time: none is a bar.
          NVDA: [
            { t: stamp(nyMidnight(11)), o: 0, h: 0, l: 0, c: 0, v: 0 },
            { t: stamp(nyMidnight(12)), o: "120.5", h: 121, l: 120, c: 120.7, v: 10 },
            { t: "yesterday", o: 120, h: 121, l: 119, c: 120.5, v: 10 },
          ],
        },
        next_page_token: null,
      })
      : json({ bars: {}, next_page_token: null })
  );

  const result = await provider.bars([AAPL, MSFT, TSLA, SPY, usStock("NVDA")], "day", 5, NOW);

  // The three the consolidated tape said nothing about get their one IEX request. NVDA
  // was answered — with bars that aren't usable — so it fails where it stands.
  assertEquals(calls.map(feedOf), ["sip", "iex"]);
  assertEquals(symbolsOf(calls[1]), "MSFT,TSLA,SPY");
  assertEquals(Object.keys(result.series), ["us:AAPL"]);
  assertEquals(result.failures, {
    "us:MSFT": "Alpaca has no price history for MSFT",
    "us:TSLA": "Alpaca has no price history for TSLA",
    "us:SPY": "Alpaca has no price history for SPY",
    "us:NVDA": "Alpaca has no price history for NVDA",
  });
});

Deno.test("bars: `bars: null` from both feeds means nobody has history", async () => {
  const { provider, calls } = harness(() => json({ bars: null, next_page_token: null }));
  const result = await provider.bars([AAPL, MSFT], "day", 5, NOW);
  assertEquals(calls.map(feedOf), ["sip", "iex"]);
  assertEquals(result.series, {});
  assertEquals(result.failures, {
    "us:AAPL": "Alpaca has no price history for AAPL",
    "us:MSFT": "Alpaca has no price history for MSFT",
  });
});

Deno.test("bars: an invalid bar among good ones is dropped, never repaired", async () => {
  const { provider } = harness(() =>
    json({
      bars: { AAPL: [wireBar(nyMidnight(10), 104), { t: stamp(nyMidnight(11)), o: 105, h: 104, l: 106, c: 0, v: 5 }, wireBar(nyMidnight(12), 106)] },
      next_page_token: null,
    })
  );
  const result = await provider.bars([AAPL], "day", 5, NOW);
  assertEquals(result.series["us:AAPL"].bars, [bar(nyMidnight(10), 104), bar(nyMidnight(12), 106)]);
});

Deno.test("bars: if a later page fails, the whole request fails — a history that stops early is not served", async () => {
  const { provider, calls } = harness((call) =>
    call.url.searchParams.get("page_token") === null
      ? json({ bars: { AAPL: [wireBar(nyMidnight(5), 101), wireBar(nyMidnight(6), 102)] }, next_page_token: "page-2" })
      : json({ message: "boom" }, 500), { maxAttempts: 2 });

  const result = await provider.bars([AAPL, MSFT], "day", 5, NOW);

  assertEquals(calls.length, 3); // page 1, then page 2 twice — and no IEX request
  assertEquals(calls.map(feedOf), ["sip", "sip", "sip"]);
  assertEquals(result.series, {});
  assertEquals(result.failures, { "us:AAPL": "Alpaca returned HTTP 500", "us:MSFT": "Alpaca returned HTTP 500" });
});

Deno.test("bars: symbols are batched, and a failed batch fails only its own instruments", async () => {
  const stocks = Array.from({ length: 130 }, (_, index) => usStock(`T${String(index).padStart(3, "0")}`));
  const { provider, calls } = harness((call) => {
    const symbols = symbolsOf(call)!.split(",");
    if (symbols.includes("T000")) return json({ message: "bad request" }, 400);
    return json({ bars: Object.fromEntries(symbols.map((symbol) => [symbol, [wireBar(nyMidnight(12), 50)]])), next_page_token: null });
  });

  const result = await provider.bars(stocks, "day", 1, NOW);

  assertEquals(calls.map((call) => symbolsOf(call)!.split(",").length).sort(), [100, 30]);
  assertEquals(Object.keys(result.failures).length, 100);
  assertEquals(Object.keys(result.series).length, 30);
  assertEquals(result.failures["us:T000"], "Alpaca returned HTTP 400");
  assertEquals(result.failures["us:T099"], "Alpaca returned HTTP 400");
  assertEquals(result.series["us:T100"].bars, [bar(nyMidnight(12), 50)]);
});

// ---------------------------------------------------------------------------------------
// Hourly stock bars and crypto bars: one venue's volume

Deno.test("hourly stock bars: IEX, up to the present, and not market-wide", async () => {
  const { provider, calls } = harness(() => json({ bars: { AAPL: [wireBar(NOW - 2 * HOUR, 228), wireBar(NOW - HOUR, 229)] }, next_page_token: null }));

  const result = await provider.bars([AAPL], "hour", 60, NOW);

  assertEquals(calls.length, 1); // the consolidated tape is not tried for hourly bars
  const query = calls[0].url.searchParams;
  assertEquals(calls[0].url.pathname, "/v2/stocks/bars");
  assertEquals(query.get("feed"), "iex");
  assertEquals(query.get("timeframe"), "1Hour");
  assertEquals(query.get("end"), null);
  assertEquals(query.get("adjustment"), "all");
  assertEquals(query.get("sort"), "asc");
  // 60 hourly bars → (60 / 6) × 1.6 + 5 = 21 calendar days back.
  assertEquals(query.get("start"), stamp(NOW - 21 * DAY));

  assertEquals(result.failures, {});
  assertEquals(result.series["us:AAPL"].bars, [bar(NOW - 2 * HOUR, 228), bar(NOW - HOUR, 229)]);
  assertEquals(result.series["us:AAPL"].provenance, IEX);
  assertEquals(result.series["us:AAPL"].volumeIsMarketWide, false);
  assertEquals(result.series["us:AAPL"].timeframe, "hour");
});

Deno.test("crypto bars: BTC is asked for as BTC/USD, URL-encoded, on the crypto path — and the volume is Alpaca's venue only", async () => {
  const { provider, calls } = harness(() =>
    json({
      bars: {
        "BTC/USD": [wireBar(NOW - 2 * HOUR, 70_000, 0.5), wireBar(NOW - HOUR, 70_500, 0)],
        "ETH/USD": [wireBar(NOW - HOUR, 2_000, 3)],
      },
      next_page_token: null,
    })
  );

  const hourlyResult = await provider.bars([BTC, ETH], "hour", 24, NOW);
  const dailyResult = await provider.bars([BTC], "day", 30, NOW);

  assertEquals(calls.length, 2);
  const [hourly, daily] = calls;
  assertEquals(hourly.url.pathname, "/v1beta3/crypto/us/bars");
  assertEquals(symbolsOf(hourly), "BTC/USD,ETH/USD");
  assertStringIncludes(hourly.raw, "symbols=BTC%2FUSD%2CETH%2FUSD");
  assert(!hourly.raw.includes("BTC/USD"), "the slash must be encoded");
  assertEquals(hourly.url.searchParams.get("timeframe"), "1Hour");
  assertEquals(hourly.url.searchParams.get("sort"), "asc");
  assertEquals(hourly.url.searchParams.get("start"), stamp(NOW - 30 * HOUR)); // 24 + 6 hours
  assertEquals(hourly.url.searchParams.get("end"), null);
  // Stock-only options are not sent to the crypto endpoint.
  assertEquals(hourly.url.searchParams.get("feed"), null);
  assertEquals(hourly.url.searchParams.get("adjustment"), null);
  assertEquals(daily.url.searchParams.get("timeframe"), "1Day");
  assertEquals(daily.url.searchParams.get("start"), stamp(NOW - 33 * DAY)); // 30 + 3 days
  assertEquals(daily.url.searchParams.get("end"), null);
  assertEquals(daily.url.searchParams.get("feed"), null);

  assertEquals(hourlyResult.failures, {});
  assertEquals(hourlyResult.series["crypto:BTC"].instrument, BTC);
  assertEquals(hourlyResult.series["crypto:BTC"].provenance, ALPACA_CRYPTO);
  assertEquals(hourlyResult.series["crypto:BTC"].volumeIsMarketWide, false);
  // A quiet hour has volume 0 and real (quote-derived) prices; it is a valid bar and stays.
  assertEquals(hourlyResult.series["crypto:BTC"].bars, [bar(NOW - 2 * HOUR, 70_000, 0.5), bar(NOW - HOUR, 70_500, 0)]);
  assertEquals(hourlyResult.series["crypto:ETH"].bars, [bar(NOW - HOUR, 2_000, 3)]);
  assertEquals(hourlyResult.series["crypto:ETH"].volumeIsMarketWide, false);

  assertEquals(dailyResult.series["crypto:BTC"].provenance, ALPACA_CRYPTO);
  assertEquals(dailyResult.series["crypto:BTC"].volumeIsMarketWide, false);
  assertEquals(dailyResult.series["crypto:BTC"].timeframe, "day");
});

Deno.test("bars: stocks and crypto go out as separate requests and come back as one answer", async () => {
  const { provider, calls } = harness((call) =>
    call.url.pathname === "/v2/stocks/bars"
      ? json({ bars: { AAPL: [wireBar(nyMidnight(12), 106)] }, next_page_token: null })
      : json({ bars: { "BTC/USD": [wireBar(Date.UTC(2026, 10, 12), 70_000, 1.2)] }, next_page_token: null })
  );

  const result = await provider.bars([AAPL, BTC], "day", 10, NOW);

  assertEquals(calls.map((call) => call.url.pathname).sort(), ["/v1beta3/crypto/us/bars", "/v2/stocks/bars"]);
  assertEquals(Object.keys(result.series).sort(), ["crypto:BTC", "us:AAPL"]);
  assertEquals(result.series["us:AAPL"].volumeIsMarketWide, true);
  assertEquals(result.series["crypto:BTC"].volumeIsMarketWide, false);
  assertEquals(result.failures, {});
});

Deno.test("bars: an answer that never stops paging is given up on", async () => {
  const { provider, calls } = harness((_call, index) =>
    json({ bars: { AAPL: [wireBar(nyMidnight(5) + index * HOUR, 101)] }, next_page_token: `page-${index + 2}` })
  );

  const result = await provider.bars([AAPL], "hour", 5, NOW);

  assertEquals(calls.length, 50);
  assertEquals(result.series, {});
  assertEquals(result.failures, { "us:AAPL": "Alpaca sent more price history than could be read" });
});

Deno.test("bars: a request that makes no sense fails every instrument without asking Alpaca", async () => {
  const { provider, calls } = harness(() => json({ bars: {}, next_page_token: null }));

  assertEquals((await provider.bars([AAPL, BTC], "day", 0, NOW)).failures, {
    "us:AAPL": "The number of bars asked for isn't valid",
    "crypto:BTC": "The number of bars asked for isn't valid",
  });
  assertEquals((await provider.bars([AAPL], "day", 20, Number.NaN)).failures, { "us:AAPL": "The request time isn't valid" });
  assertEquals((await provider.bars([AAPL], "week" as unknown as "day", 20, NOW)).failures, { "us:AAPL": "The bar size isn't one this data source knows" });
  assertEquals(calls.length, 0);
});

Deno.test("a symbol that could change what is asked for is refused before any request", async () => {
  const { provider, calls } = harness((call) =>
    call.url.pathname.endsWith("/bars") ? json({ bars: { AAPL: [wireBar(nyMidnight(12), 106)] }, next_page_token: null }) : json({})
  );
  const sneaky: Instrument = { ...usStock("X"), symbol: "MSFT,TSLA" };
  const pair: Instrument = { ...cryptoAsset("X"), symbol: "BTC/USD" };

  const result = await provider.bars([AAPL, sneaky, pair, AAPL], "day", 5, NOW);

  assertEquals(calls.length, 1);
  assertEquals(symbolsOf(calls[0]), "AAPL"); // once, though it was listed twice
  assertEquals(Object.keys(result.series), ["us:AAPL"]);
  assertEquals(result.failures, {
    "us:MSFT,TSLA": "Alpaca has no data for MSFT,TSLA",
    "crypto:BTC/USD": "Alpaca has no data for BTC/USD",
  });
});

// ---------------------------------------------------------------------------------------
// Quotes

Deno.test("stock quotes: the last trade, with the bid and ask when they make a believable market", async () => {
  const { provider, calls } = harness(() =>
    // Alpaca keys stock snapshots by symbol at the top level.
    json({
      // The book is newer than the last trade: the quote takes the book's time.
      AAPL: {
        latestTrade: { t: "2026-11-12T19:59:58.123456789Z", p: 228.5, s: 100, x: "V" },
        latestQuote: { t: "2026-11-12T19:59:59.5Z", bp: 228.45, ap: 228.55 },
        dailyBar: { t: stamp(nyMidnight(12)), o: 227, h: 229, l: 226.5, c: 228.5, v: 51_234 },
      },
      // The book is older than the last trade: the trade's time stands.
      MSFT: {
        latestTrade: { t: "2026-11-12T19:59:58Z", p: 410 },
        latestQuote: { t: "2026-11-12T19:50:00Z", bp: 409.9, ap: 410.1 },
        dailyBar: { t: stamp(nyMidnight(12)), v: 99_999 },
      },
      // A good book with no readable time of its own: kept, on the trade's time.
      TSLA: {
        latestTrade: { t: "2026-11-12T19:00:00Z", p: 300.25 },
        latestQuote: { bp: 300.2, ap: 300.3 },
      },
      // Exactly one percent wide, centred on the last trade: still a market.
      NVDA: {
        latestTrade: { t: "2026-11-12T19:30:00Z", p: 100 },
        latestQuote: { t: "2026-11-12T19:30:01Z", bp: 99.5, ap: 100.5 },
      },
      // A locked book (bid = ask) is not crossed.
      AMD: {
        latestTrade: { t: "2026-11-12T19:30:00Z", p: 150 },
        latestQuote: { t: "2026-11-12T19:29:00Z", bp: 150, ap: 150 },
      },
      SPY: { latestTrade: { t: "2026-11-12T19:30:00-05:00", p: 590 } },
    })
  );
  const symbols = ["AAPL", "MSFT", "TSLA", "NVDA", "AMD", "SPY"];

  const result = await provider.quotes(symbols.map((symbol) => usStock(symbol)), NOW);

  assertEquals(calls.length, 1);
  assertEquals(calls[0].url.pathname, "/v2/stocks/snapshots");
  assertEquals(symbolsOf(calls[0]), "AAPL,MSFT,TSLA,NVDA,AMD,SPY");
  assertEquals(feedOf(calls[0]), "iex");
  assertEquals(calls[0].headers.get("APCA-API-KEY-ID"), KEY_ID);
  assertEquals(calls[0].headers.get("APCA-API-SECRET-KEY"), SECRET);
  assertNoSecrets(calls[0].raw);
  assertEquals(result.failures, {});

  assertEquals(result.quotes["us:AAPL"], { instrumentID: "us:AAPL", last: 228.5, bid: 228.45, ask: 228.55, time: Date.UTC(2026, 10, 12, 19, 59, 59, 500), provenance: IEX } as Quote);
  assert(result.quotes["us:AAPL"].time !== NOW, "the quote time is the venue's, not the fetch time");
  assertEquals(result.quotes["us:MSFT"], { instrumentID: "us:MSFT", last: 410, bid: 409.9, ask: 410.1, time: Date.UTC(2026, 10, 12, 19, 59, 58), provenance: IEX } as Quote);
  assertEquals(result.quotes["us:TSLA"], { instrumentID: "us:TSLA", last: 300.25, bid: 300.2, ask: 300.3, time: Date.UTC(2026, 10, 12, 19), provenance: IEX } as Quote);
  assertEquals(result.quotes["us:NVDA"], { instrumentID: "us:NVDA", last: 100, bid: 99.5, ask: 100.5, time: Date.UTC(2026, 10, 12, 19, 30, 1), provenance: IEX } as Quote);
  assertEquals(result.quotes["us:AMD"], { instrumentID: "us:AMD", last: 150, bid: 150, ask: 150, time: Date.UTC(2026, 10, 12, 19, 30), provenance: IEX } as Quote);
  // A time zone offset is honoured; with no book there is just the trade.
  assertEquals(result.quotes["us:SPY"], { instrumentID: "us:SPY", last: 590, time: Date.UTC(2026, 10, 13, 0, 30), provenance: IEX } as Quote);

  // IEX's daily volume is one exchange's slice: it is never passed on as the day's volume.
  for (const quote of Object.values(result.quotes)) assert(!("dayVolume" in quote), `${quote.instrumentID} carries a day volume`);
});

Deno.test("quotes: a book that isn't a believable market is dropped — both sides — and the time stays the trade's", async () => {
  const tradeTime = "2026-11-12T19:00:00Z";
  const newer = "2026-11-12T19:59:59Z";
  const books: Record<string, Record<string, unknown>> = {
    ZEROASK: { bp: 99.9, ap: 0 }, // IEX with nobody offering
    ZEROBID: { bp: 0, ap: 100.1 },
    CROSSED: { bp: 100.2, ap: 100.1 },
    WIDE: { bp: 99, ap: 101 }, // 2% apart
    JUSTWIDE: { bp: 99.49, ap: 100.5 }, // a hair over 1%
    FAR: { bp: 102, ap: 102.2 }, // tight, but 2.1% above the last trade
    FARBELOW: { bp: 97.9, ap: 98 },
    TEXT: { bp: "99.95", ap: 100.05 },
    NOASK: { bp: 99.95 },
    NEGATIVE: { bp: -1, ap: 100 },
  };
  const { provider } = harness(() =>
    json(Object.fromEntries(
      Object.entries(books).map(([symbol, book]) => [symbol, {
        latestTrade: { t: tradeTime, p: 100 },
        latestQuote: { t: newer, ...book },
        dailyBar: { t: stamp(nyMidnight(12)), v: 5_000 },
      }]),
    ))
  );

  const result = await provider.quotes(Object.keys(books).map((symbol) => usStock(symbol)), NOW);

  assertEquals(result.failures, {});
  for (const symbol of Object.keys(books)) {
    // Still a quote — the last trade is real — but with no spread to measure, and no
    // credit for the freshness of a book that was thrown away.
    assertEquals(result.quotes[`us:${symbol}`], { instrumentID: `us:${symbol}`, last: 100, time: Date.UTC(2026, 10, 12, 19), provenance: IEX } as Quote, symbol);
    assert(!("bid" in result.quotes[`us:${symbol}`]) && !("ask" in result.quotes[`us:${symbol}`]), `${symbol} kept half a book`);
  }
});

Deno.test("crypto quotes: read from under `snapshots`, keyed BTC/USD, by the same rules", async () => {
  const { provider, calls } = harness(() =>
    json({
      snapshots: {
        "BTC/USD": {
          latestTrade: { t: "2026-11-12T19:43:02.288500345Z", p: 70_854.4, s: 0.00011, tks: "B" },
          latestQuote: { t: "2026-11-12T19:59:29.320581427Z", bp: 70_762.368, ap: 70_780.86 },
          dailyBar: { t: "2026-11-12T00:00:00Z", v: 0.132473031 },
        },
        // A wide book on a thin coin: the trade stands alone, at its own (older) time.
        "SOL/USD": {
          latestTrade: { t: "2026-11-12T19:38:01.368510114Z", p: 150 },
          latestQuote: { t: "2026-11-12T19:59:26Z", bp: 147, ap: 153 },
          dailyBar: { t: "2026-11-12T00:00:00Z", v: 12.5 },
        },
      },
    })
  );
  const SOL = cryptoAsset("SOL");

  const result = await provider.quotes([BTC, ETH, SOL], NOW);

  assertEquals(calls[0].url.pathname, "/v1beta3/crypto/us/snapshots");
  assertEquals(symbolsOf(calls[0]), "BTC/USD,ETH/USD,SOL/USD");
  assertStringIncludes(calls[0].raw, "symbols=BTC%2FUSD%2CETH%2FUSD%2CSOL%2FUSD");
  assertEquals(feedOf(calls[0]), null);
  assertEquals(result.quotes, {
    "crypto:BTC": {
      instrumentID: "crypto:BTC",
      last: 70_854.4,
      bid: 70_762.368,
      ask: 70_780.86,
      // The live book is newer than the last trade on Alpaca's quiet venue.
      time: Date.UTC(2026, 10, 12, 19, 59, 29, 320),
      provenance: ALPACA_CRYPTO,
    },
    "crypto:SOL": { instrumentID: "crypto:SOL", last: 150, time: Date.UTC(2026, 10, 12, 19, 38, 1, 368), provenance: ALPACA_CRYPTO },
  });
  assertEquals(result.failures, { "crypto:ETH": "Alpaca has no live quote for ETH" });
});

Deno.test("quotes: a snapshot is found whether it is keyed at the top level or under `snapshots`", async () => {
  // The documented shapes are top-level for stocks and nested for crypto. If Alpaca ever
  // brings the two into line, the same real numbers are still read from the other place.
  const trade = { latestTrade: { t: "2026-11-12T19:59:58Z", p: 228.5 } };
  const { provider } = harness((call) => call.url.pathname === "/v2/stocks/snapshots" ? json({ snapshots: { AAPL: trade } }) : json({ "BTC/USD": trade }));

  const result = await provider.quotes([AAPL, BTC], NOW);

  assertEquals(result.failures, {});
  assertEquals(result.quotes["us:AAPL"].last, 228.5);
  assertEquals(result.quotes["crypto:BTC"].last, 228.5);
});

Deno.test("quotes: no last trade, no price — never a guessed one", async () => {
  const { provider } = harness(() =>
    json({
      AAPL: { latestTrade: { t: "2026-11-12T19:59:58Z", p: 228.5 } },
      // MSFT is absent altogether.
      // A two-sided market but no trade: the mid is NOT used as a last price.
      TSLA: { latestQuote: { t: "2026-11-12T19:59:59Z", bp: 300, ap: 300.1 }, dailyBar: { t: stamp(nyMidnight(12)), c: 300.05, v: 10 } },
      SPY: { latestTrade: { t: "2026-11-12T19:59:58Z", p: 0 } },
      NVDA: { latestTrade: { t: "2026-11-12T19:59:58Z", p: "120.50" } },
      AMD: { latestTrade: { t: "a moment ago", p: 150 } },
      INTC: { latestTrade: { t: 1_794_513_598, p: 30 } },
      QQQ: null,
    })
  );
  const symbols = ["AAPL", "MSFT", "TSLA", "SPY", "NVDA", "AMD", "INTC", "QQQ"];

  const result = await provider.quotes(symbols.map((symbol) => usStock(symbol)), NOW);

  assertEquals(Object.keys(result.quotes), ["us:AAPL"]);
  assertEquals(result.failures, Object.fromEntries(symbols.slice(1).map((symbol) => [`us:${symbol}`, `Alpaca has no live quote for ${symbol}`])));
});

// ---------------------------------------------------------------------------------------
// What isn't supported

Deno.test("only the US market and crypto are supported: every other venue is a failure with no request made", async () => {
  const { provider, calls } = harness(() => json({}));
  const TOYOTA = listed("7203", "tse", "Toyota");

  assertEquals(provider.supports(AAPL), true);
  assertEquals(provider.supports(SPY), true);
  assertEquals(provider.supports(BTC), true);
  for (const instrument of [BHP, VOD, TOYOTA, listed("SAP", "xetra"), listed("0700", "hkex"), listed("RELIANCE", "nse")]) {
    assertEquals(provider.supports(instrument), false, instrument.venue);
  }

  const failures = {
    "asx:BHP": "ASX isn't supported by this data source",
    "lse:VOD": "London market isn't supported by this data source",
    "tse:7203": "Tokyo market isn't supported by this data source",
  };
  assertEquals(await provider.bars([BHP, VOD, TOYOTA], "day", 20, NOW), { series: {}, failures });
  assertEquals(await provider.quotes([BHP, VOD, TOYOTA], NOW), { quotes: {}, failures });
  assertEquals(calls.length, 0);
});

Deno.test("an unsupported venue alongside a US stock: only the US stock is asked for", async () => {
  const { provider, calls } = harness(() => json({ AAPL: { latestTrade: { t: "2026-11-12T19:59:58Z", p: 228.5 } } }));
  const nowhere = { ...usStock("ZZZ"), venue: "moon" } as unknown as Instrument;

  const result = await provider.quotes([BHP, VOD, nowhere, AAPL], NOW);

  assertEquals(calls.length, 1);
  assertEquals(symbolsOf(calls[0]), "AAPL");
  assertEquals(Object.keys(result.quotes), ["us:AAPL"]);
  assertEquals(result.failures, {
    "asx:BHP": "ASX isn't supported by this data source",
    "lse:VOD": "London market isn't supported by this data source",
    // A venue nobody has heard of (bad input) fails by itself; it doesn't take AAPL with it.
    "moon:ZZZ": "This market isn't supported by this data source",
  });
});

// ---------------------------------------------------------------------------------------
// Retries, limits and broken answers

const oneBar = () => json({ bars: { AAPL: [wireBar(nyMidnight(12), 106)] }, next_page_token: null });

Deno.test("retry: an HTTP 500 is tried again, with a doubling pause", async () => {
  const { provider, calls, sleeps } = harness((_call, index) => index < 2 ? json({ message: "internal" }, 500) : oneBar());

  const result = await provider.bars([AAPL], "day", 5, NOW);

  assertEquals(calls.length, 3);
  assertEquals(sleeps, [300, 600]);
  assertEquals(result.failures, {});
  assertEquals(result.series["us:AAPL"].bars, [bar(nyMidnight(12), 106)]);
  assertEquals(result.series["us:AAPL"].provenance, CONSOLIDATED); // the retry is the same request, not a fallback
});

Deno.test("retry: an HTTP 429 waits for Retry-After, up to five seconds", async () => {
  const waited = harness((_call, index) => index === 0 ? json({ message: "too many requests." }, 429, { "retry-after": "2" }) : oneBar());
  assertEquals(Object.keys((await waited.provider.bars([AAPL], "day", 5, NOW)).series), ["us:AAPL"]);
  assertEquals(waited.calls.length, 2);
  assertEquals(waited.sleeps, [2_000]);

  const capped = harness((_call, index) => index === 0 ? json({ message: "too many requests." }, 429, { "retry-after": "120" }) : oneBar());
  assertEquals(Object.keys((await capped.provider.bars([AAPL], "day", 5, NOW)).series), ["us:AAPL"]);
  assertEquals(capped.sleeps, [5_000]);

  // Alpaca's 429 usually carries no Retry-After at all: then it is the ordinary backoff.
  const bare = harness((_call, index) => index === 0 ? json({ message: "too many requests." }, 429) : oneBar(), { backoffMs: 40 });
  assertEquals(Object.keys((await bare.provider.bars([AAPL], "day", 5, NOW)).series), ["us:AAPL"]);
  assertEquals(bare.sleeps, [40]);
});

Deno.test("retry: gives up after maxAttempts, and every instrument in that request fails — others are untouched", async () => {
  const { provider, calls, sleeps } = harness((call) =>
    call.url.pathname === "/v2/stocks/snapshots"
      ? json({ message: "unavailable" }, 503)
      : json({ snapshots: { "BTC/USD": { latestTrade: { t: "2026-11-12T19:59:00Z", p: 70_000 } } } })
  );

  const result = await provider.quotes([AAPL, MSFT, BTC], NOW);

  assertEquals(calls.filter((call) => call.url.pathname === "/v2/stocks/snapshots").length, 3);
  assertEquals(calls.filter((call) => call.url.pathname === "/v1beta3/crypto/us/snapshots").length, 1);
  assertEquals(sleeps, [300, 600]);
  assertEquals(result.failures, { "us:AAPL": "Alpaca returned HTTP 503", "us:MSFT": "Alpaca returned HTTP 503" });
  assertEquals(Object.keys(result.quotes), ["crypto:BTC"]);
});

Deno.test("retry: a rate limit that never lifts is a failure, not a wait forever", async () => {
  const { provider, calls } = harness(() => json({ message: "too many requests." }, 429), { maxAttempts: 4 });
  const result = await provider.bars([AAPL], "hour", 5, NOW);
  assertEquals(calls.length, 4);
  assertEquals(result.failures, { "us:AAPL": "Alpaca is rate limiting requests (HTTP 429)" });
});

Deno.test("no retry on HTTP 400", async () => {
  const { provider, calls, sleeps } = harness(() => json({ message: "invalid symbol" }, 400));

  const result = await provider.bars([AAPL, MSFT], "day", 5, NOW);

  assertEquals(calls.length, 1);
  assertEquals(sleeps, []);
  assertEquals(result.series, {});
  assertEquals(result.failures, { "us:AAPL": "Alpaca returned HTTP 400", "us:MSFT": "Alpaca returned HTTP 400" });
});

Deno.test("401 and 403: the credentials were rejected — said without repeating them, and not retried", async () => {
  for (const status of [401, 403]) {
    // Even if the server echoes the key back, it goes no further.
    const { provider, calls, sleeps, events } = harness(() => json({ message: `forbidden for ${KEY_ID} / ${SECRET}` }, status));

    const bars = await provider.bars([AAPL, BTC], "day", 5, NOW);
    const quotes = await provider.quotes([AAPL], NOW);

    // Crypto bars and stock snapshots once each. Stock bars once for a 401; a 403 could
    // mean "not on this plan", so IEX is asked too — and says the same thing.
    assertEquals(calls.filter((call) => call.url.pathname === "/v2/stocks/bars").map(feedOf), status === 403 ? ["sip", "iex"] : ["sip"]);
    assertEquals(calls.length, status === 403 ? 4 : 3);
    assertEquals(sleeps, []);
    assertEquals(bars.failures, { "us:AAPL": "Alpaca rejected the data credentials", "crypto:BTC": "Alpaca rejected the data credentials" });
    assertEquals(quotes.failures, { "us:AAPL": "Alpaca rejected the data credentials" });
    assertNoSecrets(bars);
    assertNoSecrets(quotes);
    assertNoSecrets(events);
  }
});

Deno.test("timeout: a request that hangs is aborted and reported as timed out", async () => {
  const { provider, calls, sleeps, events } = harness(hang, { timeoutMs: 5, maxAttempts: 2 });

  const result = await provider.quotes([AAPL, MSFT], NOW);

  assertEquals(calls.length, 2); // a timeout is retried
  assertEquals(sleeps, [300]);
  assertEquals(result.quotes, {});
  assertEquals(result.failures, { "us:AAPL": "The request timed out", "us:MSFT": "The request timed out" });
  assertStringIncludes(result.failures["us:AAPL"], "timed out");
  assertEquals(events.map((event) => event.error), ["timeout", "timeout"]);
});

Deno.test("network error: retried, then reported without the underlying error text", async () => {
  const { provider, calls, events } = harness((call) => {
    throw new TypeError(`error sending request for url (${call.raw}) with ${SECRET}`);
  });

  const result = await provider.bars([AAPL], "day", 5, NOW);

  assertEquals(calls.length, 3);
  assertEquals(result.failures, { "us:AAPL": "Alpaca couldn't be reached" });
  assertEquals(events.map((event) => event.error), ["network", "network", "network"]);
  assertNoSecrets(result);
  assertNoSecrets(events);
});

Deno.test("an answer that isn't JSON, or isn't the expected shape, is unreadable — and not retried", async () => {
  const html = harness(() => new Response("<html><body>Bad gateway</body></html>", { status: 200, headers: { "content-type": "text/html" } }));
  assertEquals((await html.provider.bars([AAPL], "day", 5, NOW)).failures, { "us:AAPL": "Alpaca returned an unreadable response" });
  assertEquals((await html.provider.quotes([AAPL, BTC], NOW)).failures, {
    "us:AAPL": "Alpaca returned an unreadable response",
    "crypto:BTC": "Alpaca returned an unreadable response",
  });
  assertEquals(html.calls.length, 3);
  assertEquals(html.sleeps, []);

  const list = harness(() => json([{ t: stamp(nyMidnight(12)), c: 1 }]));
  assertEquals((await list.provider.bars([AAPL], "day", 5, NOW)).failures, { "us:AAPL": "Alpaca returned an unreadable response" });
  assertEquals((await list.provider.quotes([AAPL], NOW)).failures, { "us:AAPL": "Alpaca returned an unreadable response" });

  const wrong = harness(() => json({ bars: "none", next_page_token: null }));
  assertEquals((await wrong.provider.bars([AAPL], "day", 5, NOW)).failures, { "us:AAPL": "Alpaca returned an unreadable response" });
});

Deno.test("a redirect is not followed (it would carry the keys elsewhere)", async () => {
  const { provider, calls } = harness(() => new Response(null, { status: 302, headers: { location: "https://elsewhere.example/v2/stocks/bars" } }));
  const result = await provider.bars([AAPL], "day", 5, NOW);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].init.redirect, "manual");
  assertEquals(result.failures, { "us:AAPL": "Alpaca returned HTTP 302" });
});

Deno.test("log: one small event per HTTP attempt, with no key, header or query string", async () => {
  const { provider, events } = harness((_call, index) => index === 0 ? json({ message: "internal" }, 500) : oneBar());

  await provider.bars([AAPL, MSFT], "hour", 5, NOW);

  assertEquals(events.length, 2);
  for (const [index, event] of events.entries()) {
    assertEquals(Object.keys(event).sort(), ["attempt", "event", "ms", "path", "provider", "status", "symbols"]);
    assertEquals(event.event, "market_data_request");
    assertEquals(event.provider, "alpaca");
    assertEquals(event.path, "/v2/stocks/bars");
    assertEquals(event.symbols, 2);
    assertEquals(event.attempt, index + 1);
    assert(typeof event.ms === "number" && event.ms >= 0);
  }
  assertEquals(events.map((event) => event.status), [500, 200]);
  assertNoSecrets(events);
  assert(!JSON.stringify(events).includes("?"), "no query string in a log event");
});

Deno.test("log: a logger that throws doesn't cost the caller its data", async () => {
  const { provider } = harness(() => oneBar(), {
    log: () => {
      throw new Error("logger down");
    },
  });
  assertEquals(Object.keys((await provider.bars([AAPL], "day", 5, NOW)).series), ["us:AAPL"]);
});

Deno.test("the credentials can't be printed or serialised with the provider", () => {
  const { provider } = harness(() => json({}), { volumeSource: new CoinGeckoVolumeSource({ apiKey: GECKO_KEY }) });
  assertNoSecrets(JSON.stringify(provider));
  assertNoSecrets(Deno.inspect(provider, { depth: 10, showHidden: true }));
  assertNoSecrets(Object.values(provider).map(String).join(" "));

  const source = new CoinGeckoVolumeSource({ apiKey: GECKO_KEY });
  assertNoSecrets(JSON.stringify(source));
  assertNoSecrets(Deno.inspect(source, { depth: 10, showHidden: true }));
});

Deno.test("the provider refuses to be pointed at Alpaca's trading hosts, or at plain http", () => {
  const build = (baseURL: string) => new AlpacaDataProvider({ keyId: KEY_ID, secret: SECRET, baseURL });
  for (const baseURL of ["https://api.alpaca.markets", "https://paper-api.alpaca.markets", "https://broker-api.alpaca.markets", "http://data.alpaca.markets", "not a url"]) {
    let thrown: unknown;
    try {
      build(baseURL);
    } catch (error) {
      thrown = error;
    }
    assert(thrown instanceof ProviderError, `${baseURL} should be refused`);
    assertNoSecrets(thrown.message);
  }
  // The data host, its sandbox, a test double and a local stub are fine.
  for (const baseURL of ["https://data.alpaca.markets", "https://data.sandbox.alpaca.markets/", "https://market-data.test", "http://localhost:8787"]) build(baseURL);
});

Deno.test("venue timestamps: nanoseconds and offsets are read; anything looser is not a time", () => {
  assertEquals(parseVenueTime("2021-02-06T13:35:08.946977536Z"), Date.UTC(2021, 1, 6, 13, 35, 8, 946));
  assertEquals(parseVenueTime("2022-01-03T09:00:00Z"), Date.UTC(2022, 0, 3, 9));
  assertEquals(parseVenueTime("2022-01-03T04:00:00-05:00"), Date.UTC(2022, 0, 3, 9));
  assertEquals(parseVenueTime("2022-01-03T09:00:00.5Z"), Date.UTC(2022, 0, 3, 9, 0, 0, 500));
  for (const loose of ["2022-01-03", "0", "1", "", "2022-13-40T09:00:00Z", "2022-01-03 09:00:00", "2022-01-03T09:00:00", 1_641_200_400_000, null, undefined, {}]) {
    assertEquals(parseVenueTime(loose), undefined, `${String(loose)} is not a venue time`);
  }
});

// ---------------------------------------------------------------------------------------
// Market-wide traded value

Deno.test("Alpaca dollarVolume: asks its volume source about crypto only, and passes on only real figures", async () => {
  const asked: string[][] = [];
  const { provider, calls } = harness(() => json({}), {
    volumeSource: {
      dollarVolume: (instruments, now) => {
        assertEquals(now, NOW);
        asked.push(instruments.map((instrument) => `${instrument.venue}:${instrument.symbol}`));
        // Everything but BTC's figure is something that must not get through.
        return Promise.resolve({ "crypto:BTC": 33_235_034_316, "crypto:ETH": 0, "crypto:SOL": Number.NaN, "us:AAPL": 9_000_000_000, "crypto:XRP": 1_000 });
      },
    },
  });

  const known = await provider.dollarVolume([AAPL, BTC, ETH, cryptoAsset("SOL"), BHP, BTC], NOW);

  assertEquals(asked, [["crypto:BTC", "crypto:ETH", "crypto:SOL"]]);
  assertEquals(known, { "crypto:BTC": 33_235_034_316 });
  assertEquals(calls.length, 0); // Alpaca itself is never asked: it has no market-wide figure

  // Nothing to ask about → the source isn't bothered.
  assertEquals(await provider.dollarVolume([AAPL, BHP], NOW), {});
  assertEquals(asked.length, 1);
});

Deno.test("Alpaca dollarVolume: with no source, a source that fails or a source that talks nonsense, nothing is known — and nothing throws", async () => {
  assertEquals(await harness(() => json({})).provider.dollarVolume([BTC], NOW), {});

  const rejecting = harness(() => json({}), { volumeSource: { dollarVolume: () => Promise.reject(new Error(`down ${GECKO_KEY}`)) } });
  assertEquals(await rejecting.provider.dollarVolume([BTC], NOW), {});

  const throwing = harness(() => json({}), {
    volumeSource: {
      dollarVolume: () => {
        throw new Error("down");
      },
    },
  });
  assertEquals(await throwing.provider.dollarVolume([BTC], NOW), {});

  for (const nonsense of [null, undefined, "lots", 7, [1, 2], { "crypto:BTC": "33235034316" }]) {
    const odd = harness(() => json({}), { volumeSource: { dollarVolume: () => Promise.resolve(nonsense as unknown as Record<string, number>) } });
    assertEquals(await odd.provider.dollarVolume([BTC], NOW), {});
  }
});

const geckoRows = [
  { id: "bitcoin", symbol: "btc", name: "Bitcoin", current_price: 70_854, total_volume: 33_235_034_316, last_updated: "2026-11-12T19:59:21.599Z" },
  { id: "ethereum", symbol: "eth", name: "Ethereum", current_price: 2_011, total_volume: 14_200_000_000.5 },
  { id: "avalanche-2", symbol: "avax", name: "Avalanche", current_price: 21, total_volume: 310_000_000 },
];

Deno.test("CoinGecko: one request for every coin it knows, the 24-hour traded value per instrument, the key only in a header", async () => {
  const { source, calls, sleeps, events } = geckoHarness(() => json(geckoRows));
  const AVAX = cryptoAsset("AVAX", "Avalanche");

  const known = await source.dollarVolume([BTC, ETH, AVAX, cryptoAsset("PEPE"), AAPL, BHP, BTC], NOW);

  assertEquals(known, { "crypto:BTC": 33_235_034_316, "crypto:ETH": 14_200_000_000.5, "crypto:AVAX": 310_000_000 });

  assertEquals(calls.length, 1);
  const [call] = calls;
  assertEquals(call.url.origin, "https://api.coingecko.com");
  assertEquals(call.url.pathname, "/api/v3/coins/markets");
  assertEquals([...call.url.searchParams.keys()], ["vs_currency", "ids"]);
  assertEquals(call.url.searchParams.get("vs_currency"), "usd");
  assertEquals(call.url.searchParams.get("ids"), "bitcoin,ethereum,avalanche-2"); // PEPE has no id; AAPL and BHP aren't crypto
  assertEquals(call.init.method, "GET");
  assertEquals(call.init.redirect, "manual");
  assertEquals(call.headers.get("x-cg-demo-api-key"), GECKO_KEY);
  assertNoSecrets(call.raw);
  assert(!call.raw.includes("x_cg_demo_api_key"), "the key must not be a query parameter");

  assertEquals(sleeps, []);
  assertEquals(events.length, 1);
  assertEquals(Object.keys(events[0]).sort(), ["attempt", "event", "ms", "path", "provider", "status", "symbols"]);
  assertEquals({ ...events[0], ms: 0 }, { event: "market_data_request", provider: "coingecko", path: "/api/v3/coins/markets", symbols: 3, attempt: 1, status: 200, ms: 0 });
  assertNoSecrets(events);
});

Deno.test("CoinGecko: the key is optional, and every coin in the app's list has an id", async () => {
  const keyless = geckoHarness(() => json(geckoRows), { apiKey: undefined });
  assertEquals(await keyless.source.dollarVolume([BTC], NOW), { "crypto:BTC": 33_235_034_316 });
  assertEquals(keyless.calls[0].headers.has("x-cg-demo-api-key"), false);
  const blank = geckoHarness(() => json(geckoRows), { apiKey: "  " });
  await blank.source.dollarVolume([BTC], NOW);
  assertEquals(blank.calls[0].headers.has("x-cg-demo-api-key"), false);

  const coins = ["BTC", "ETH", "SOL", "ADA", "BNB", "XRP", "DOGE", "DOT", "MATIC", "LINK", "AVAX", "UNI", "LTC", "ATOM"];
  const ids = ["bitcoin", "ethereum", "solana", "cardano", "binancecoin", "ripple", "dogecoin", "polkadot", "matic-network", "chainlink", "avalanche-2", "uniswap", "litecoin", "cosmos"];
  const all = geckoHarness((call) => json(call.url.searchParams.get("ids")!.split(",").map((id, index) => ({ id, total_volume: 1_000_000 + index }))));
  const known = await all.source.dollarVolume(coins.map((coin) => cryptoAsset(coin)), NOW);
  assertEquals(all.calls.length, 1);
  assertEquals(all.calls[0].url.searchParams.get("ids"), ids.join(","));
  assertEquals(known, Object.fromEntries(coins.map((coin, index) => [`crypto:${coin}`, 1_000_000 + index])));
});

Deno.test("CoinGecko: an unknown coin, a non-crypto instrument or an unusable figure is absent — never a guess", async () => {
  const { source, calls } = geckoHarness(() =>
    json([
      { id: "bitcoin", total_volume: 0 },
      { id: "ethereum", total_volume: "14200000000" },
      { id: "solana", total_volume: null },
      { id: "cardano", total_volume: -5 },
      { id: "ripple" },
      { id: "dogecoin", total_volume: 950_000_000 },
      { id: "litecoin", total_volume: 123 }, // nobody asked about litecoin
      "nonsense",
      null,
    ])
  );
  const coins = ["BTC", "ETH", "SOL", "ADA", "XRP", "DOGE", "DOT"].map((coin) => cryptoAsset(coin));
  const euroBitcoin: Instrument = { ...cryptoAsset("BNB"), currency: "EUR" }; // a dollar figure doesn't describe it

  assertEquals(await source.dollarVolume([...coins, euroBitcoin], NOW), { "crypto:DOGE": 950_000_000 });
  assertEquals(calls[0].url.searchParams.get("ids"), "bitcoin,ethereum,solana,cardano,ripple,dogecoin,polkadot");

  // Nothing it could know about → no request at all.
  const idle = geckoHarness(() => json(geckoRows));
  assertEquals(await idle.source.dollarVolume([cryptoAsset("PEPE"), AAPL, BHP, { ...usStock("BTC") }], NOW), {});
  assertEquals(await idle.source.dollarVolume([], NOW), {});
  assertEquals(idle.calls.length, 0);
});

Deno.test("CoinGecko: a 429 or 5xx is retried once after a short pause", async () => {
  const limited = geckoHarness((_call, index) => index === 0 ? json({ status: { error_code: 429 } }, 429) : json(geckoRows));
  assertEquals(await limited.source.dollarVolume([BTC], NOW), { "crypto:BTC": 33_235_034_316 });
  assertEquals(limited.calls.length, 2);
  assertEquals(limited.sleeps, [500]);
  assertEquals(limited.events.map((event) => [event.attempt, event.status]), [[1, 429], [2, 200]]);

  const asked = geckoHarness((_call, index) => index === 0 ? json({}, 429, { "retry-after": "1.5" }) : json(geckoRows));
  assertEquals(await asked.source.dollarVolume([BTC], NOW), { "crypto:BTC": 33_235_034_316 });
  assertEquals(asked.sleeps, [1_500]);

  const unwell = geckoHarness((_call, index) => index === 0 ? json({}, 503) : json(geckoRows), { backoffMs: 20 });
  assertEquals(await unwell.source.dollarVolume([BTC], NOW), { "crypto:BTC": 33_235_034_316 });
  assertEquals(unwell.sleeps, [20]);
});

Deno.test("CoinGecko: any failure means nothing is known — {} — and nothing throws", async () => {
  const stillLimited = geckoHarness(() => json({}, 429));
  assertEquals(await stillLimited.source.dollarVolume([BTC, ETH], NOW), {});
  assertEquals(stillLimited.calls.length, 2); // one retry, then it stops

  // A server asking for a minute's patience isn't waited for.
  const patient = geckoHarness(() => json({}, 429, { "retry-after": "60" }));
  assertEquals(await patient.source.dollarVolume([BTC], NOW), {});
  assertEquals(patient.calls.length, 1);
  assertEquals(patient.sleeps, []);

  const down = geckoHarness(() => json({}, 500));
  assertEquals(await down.source.dollarVolume([BTC], NOW), {});
  assertEquals(down.calls.length, 2);

  // The wrong kind of key, a missing page: not retried.
  for (const status of [400, 401, 403, 404]) {
    const refused = geckoHarness(() => json({ status: { error_code: 10010, error_message: `bad key ${GECKO_KEY}` } }, status));
    assertEquals(await refused.source.dollarVolume([BTC], NOW), {});
    assertEquals(refused.calls.length, 1);
    assertNoSecrets(refused.events);
  }

  const offline = geckoHarness((call) => {
    throw new TypeError(`error sending request for url (${call.raw}) ${GECKO_KEY}`);
  });
  assertEquals(await offline.source.dollarVolume([BTC], NOW), {});
  assertEquals(offline.calls.length, 1);
  assertEquals(offline.events.map((event) => event.error), ["network"]);
  assertNoSecrets(offline.events);

  const hung = geckoHarness(hang, { timeoutMs: 5 });
  assertEquals(await hung.source.dollarVolume([BTC], NOW), {});
  assertEquals(hung.events.map((event) => event.error), ["timeout"]);

  const html = geckoHarness(() => new Response("<html>Just a moment...</html>", { status: 200 }));
  assertEquals(await html.source.dollarVolume([BTC], NOW), {});
  assertEquals(html.events.map((event) => event.error), ["unreadable"]);

  for (const shape of [{ bitcoin: { total_volume: 5 } }, { status: { error_code: 429 } }, "bitcoin", 5, null]) {
    const odd = geckoHarness(() => json(shape));
    assertEquals(await odd.source.dollarVolume([BTC], NOW), {});
  }

  const brokenLogger = geckoHarness(() => json(geckoRows), {
    log: () => {
      throw new Error("logger down");
    },
  });
  assertEquals(await brokenLogger.source.dollarVolume([BTC], NOW), { "crypto:BTC": 33_235_034_316 });

  const redirected = geckoHarness(() => new Response(null, { status: 302, headers: { location: "https://elsewhere.example/" } }));
  assertEquals(await redirected.source.dollarVolume([BTC], NOW), {});
  assertEquals(redirected.calls.length, 1);
});

// ---------------------------------------------------------------------------------------
// snapshot()

function stubProvider(bars: MarketDataProvider["bars"], quotes: MarketDataProvider["quotes"], dollarVolume?: MarketDataProvider["dollarVolume"]): MarketDataProvider {
  return dollarVolume === undefined ? { name: "stub", supports: () => true, bars, quotes } : { name: "stub", supports: () => true, bars, quotes, dollarVolume };
}

const stubProvenance = marketProvenance("stub");
const stubSeries = (instrument: Instrument, volumeIsMarketWide = true): BarSeries =>
  makeBarSeries(instrument, "day", [bar(nyMidnight(12), 100)], stubProvenance, NOW, volumeIsMarketWide);
const stubQuote = (instrument: Instrument): Quote => ({ instrumentID: `${instrument.venue}:${instrument.symbol}`, last: 100, time: NOW - 1_000, provenance: stubProvenance });

Deno.test("snapshot: a bars failure is reported first; a quote failure only when the bars were fine", async () => {
  const NVDA = usStock("NVDA");
  const requests: unknown[][] = [];

  const result = await snapshot(
    stubProvider(
      (instruments, timeframe, count, now) => {
        requests.push(["bars", instruments.map((instrument) => instrument.symbol), timeframe, count, now]);
        return Promise.resolve({
          series: { "us:AAPL": stubSeries(AAPL), "us:MSFT": stubSeries(MSFT) },
          failures: { "us:TSLA": "Alpaca returned HTTP 500", "us:NVDA": "Alpaca has no price history for NVDA" },
        });
      },
      (instruments, now) => {
        requests.push(["quotes", instruments.map((instrument) => instrument.symbol), now]);
        return Promise.resolve({
          quotes: { "us:AAPL": stubQuote(AAPL), "us:NVDA": stubQuote(NVDA) },
          failures: { "us:MSFT": "Alpaca has no live quote for MSFT", "us:TSLA": "The request timed out" },
        });
      },
    ),
    [AAPL, MSFT, TSLA, NVDA, AAPL],
    "day",
    30,
    NOW,
  );

  assertEquals(requests.sort((a, b) => String(a[0]).localeCompare(String(b[0]))), [
    ["bars", ["AAPL", "MSFT", "TSLA", "NVDA"], "day", 30, NOW],
    ["quotes", ["AAPL", "MSFT", "TSLA", "NVDA"], NOW],
  ]);
  assertEquals(result.failures, {
    "us:MSFT": "Live quote unavailable: Alpaca has no live quote for MSFT",
    "us:TSLA": "Price history unavailable: Alpaca returned HTTP 500", // not the quote's reason
    "us:NVDA": "Price history unavailable: Alpaca has no price history for NVDA",
  });
  // As in the Swift original, whatever did load is kept alongside the failure.
  assertEquals(Object.keys(result.series).sort(), ["us:AAPL", "us:MSFT"]);
  assertEquals(Object.keys(result.quotes).sort(), ["us:AAPL", "us:NVDA"]);
  assertEquals(result.dollarVolume, {}); // always there, even with nothing in it
});

Deno.test("snapshot: dollarVolume is filled only for series whose volume is one venue's", async () => {
  const SOL = cryptoAsset("SOL");
  const asked: unknown[][] = [];
  const provider = stubProvider(
    () =>
      Promise.resolve({
        series: { "us:AAPL": stubSeries(AAPL), "us:MSFT": stubSeries(MSFT, false), "crypto:BTC": stubSeries(BTC, false), "crypto:ETH": stubSeries(ETH, false) },
        failures: { "crypto:SOL": "Alpaca returned HTTP 500" },
      }),
    (instruments) => Promise.resolve({ quotes: Object.fromEntries(instruments.map((instrument) => [`${instrument.venue}:${instrument.symbol}`, stubQuote(instrument)])), failures: {} }),
    (instruments, now) => {
      asked.push([instruments.map((instrument) => `${instrument.venue}:${instrument.symbol}`), now]);
      return Promise.resolve({
        "crypto:BTC": 33_235_034_316,
        "crypto:ETH": 0, // not a figure
        // MSFT was asked about and simply isn't known: its key is absent.
        "us:AAPL": 9_000_000_000, // not asked about: its bars are already market-wide
        "crypto:SOL": 1_000_000_000, // not asked about: it has no series at all
        "crypto:XRP": 5,
      });
    },
  );

  const result = await snapshot(provider, [AAPL, MSFT, BTC, ETH, SOL], "day", 30, NOW);

  assertEquals(asked, [[["us:MSFT", "crypto:BTC", "crypto:ETH"], NOW]]);
  assertEquals(result.dollarVolume, { "crypto:BTC": 33_235_034_316 });
  assertEquals(Object.keys(result.series).sort(), ["crypto:BTC", "crypto:ETH", "us:AAPL", "us:MSFT"]);
  assertEquals(result.failures, { "crypto:SOL": "Price history unavailable: Alpaca returned HTTP 500" });

  // When every series is market-wide, nobody is asked.
  asked.length = 0;
  const wide = await snapshot(
    stubProvider(() => Promise.resolve({ series: { "us:AAPL": stubSeries(AAPL) }, failures: {} }), provider.quotes, provider.dollarVolume),
    [AAPL],
    "day",
    30,
    NOW,
  );
  assertEquals(asked, []);
  assertEquals(wide.dollarVolume, {});
});

Deno.test("snapshot: survives a dollarVolume() that rejects, throws, talks nonsense or doesn't exist", async () => {
  const bars: MarketDataProvider["bars"] = () => Promise.resolve({ series: { "crypto:BTC": stubSeries(BTC, false) }, failures: {} });
  const quotes: MarketDataProvider["quotes"] = () => Promise.resolve({ quotes: { "crypto:BTC": stubQuote(BTC) }, failures: {} });
  const broken: (MarketDataProvider["dollarVolume"])[] = [
    undefined,
    () => Promise.reject(new Error("CoinGecko is down")),
    () => {
      throw new Error("CoinGecko is down");
    },
    () => Promise.resolve(null as unknown as Record<string, number>),
    () => Promise.resolve("lots" as unknown as Record<string, number>),
    () => Promise.resolve([33_235_034_316] as unknown as Record<string, number>),
    () => Promise.resolve({ "crypto:BTC": "33235034316" } as unknown as Record<string, number>),
    () => Promise.resolve({ "crypto:BTC": Number.POSITIVE_INFINITY }),
    () => Promise.resolve({ "crypto:BTC": -1 }),
  ];
  for (const dollarVolume of broken) {
    const result = await snapshot(stubProvider(bars, quotes, dollarVolume), [BTC], "day", 30, NOW);
    // The prices are untouched; the liquidity is simply unknown.
    assertEquals(result.dollarVolume, {});
    assertEquals(Object.keys(result.series), ["crypto:BTC"]);
    assertEquals(Object.keys(result.quotes), ["crypto:BTC"]);
    assertEquals(result.failures, {});
  }
});

Deno.test("snapshot: never throws, and an instrument with no answer at all is a failure", async () => {
  const broken = await snapshot(
    stubProvider(() => Promise.reject(new Error(`socket hang up ${SECRET}`)), () => {
      throw new ProviderError("Alpaca couldn't be reached");
    }),
    [AAPL],
    "day",
    30,
    NOW,
  );
  assertEquals(broken, { series: {}, quotes: {}, failures: { "us:AAPL": "Price history unavailable: The market data request failed" }, dollarVolume: {} });

  const quoteOnly = await snapshot(
    stubProvider(
      () => Promise.resolve({ series: { "us:AAPL": stubSeries(AAPL) }, failures: {} }),
      () => Promise.reject(new ProviderError("Alpaca couldn't be reached")),
    ),
    [AAPL],
    "day",
    30,
    NOW,
  );
  assertEquals(quoteOnly.failures, { "us:AAPL": "Live quote unavailable: Alpaca couldn't be reached" });

  const silent = await snapshot(
    stubProvider(() => Promise.resolve({ series: {}, failures: {} }), () => Promise.resolve({ quotes: {}, failures: {} })),
    [AAPL],
    "day",
    30,
    NOW,
  );
  assertEquals(silent.failures, { "us:AAPL": "Price history unavailable: No data was returned" });

  assertEquals(await snapshot(stubProvider(() => Promise.reject(new Error("unused")), () => Promise.reject(new Error("unused"))), [], "day", 30, NOW), {
    series: {},
    quotes: {},
    failures: {},
    dollarVolume: {},
  });
});

Deno.test("snapshot through Alpaca and CoinGecko: consolidated stock bars need no figure; crypto gets CoinGecko's", async () => {
  const { fetch: fake, calls } = recorder((call) => {
    if (call.url.hostname === "api.coingecko.com") return json(geckoRows);
    // ASX and London go to Yahoo now; here it has nothing for them.
    if (call.url.hostname === "query1.finance.yahoo.com") return json({ chart: { result: null, error: { code: "Not Found" } } }, 404);
    switch (call.url.pathname) {
      case "/v2/stocks/bars":
        return json({ bars: { AAPL: [wireBar(nyMidnight(11), 105), wireBar(nyMidnight(12), 106)], MSFT: [wireBar(nyMidnight(12), 412)] }, next_page_token: null });
      case "/v2/stocks/snapshots":
        return json({ AAPL: { latestTrade: { t: "2026-11-12T19:59:58Z", p: 228.5 }, dailyBar: { t: stamp(nyMidnight(12)), v: 51_234 } } });
      case "/v1beta3/crypto/us/bars":
        return json({ bars: { "BTC/USD": [wireBar(Date.UTC(2026, 10, 11), 73_929, 1.57), wireBar(Date.UTC(2026, 10, 12), 71_372, 1.39)] }, next_page_token: null });
      default:
        return json({ snapshots: { "BTC/USD": { latestTrade: { t: "2026-11-12T19:59:00Z", p: 70_000 }, dailyBar: { t: "2026-11-12T00:00:00Z", v: 0.13 } } } });
    }
  });
  const { provider } = providerFromEnv(envOf({ ...KEYS, COINGECKO_API_KEY: GECKO_KEY }), { fetch: fake });
  assert(provider !== null);

  const result = await snapshot(provider, [AAPL, MSFT, BTC, BHP, VOD], "day", 2, NOW);

  assertEquals(Object.keys(result.series).sort(), ["crypto:BTC", "us:AAPL", "us:MSFT"]);
  assertEquals(result.series["us:AAPL"].provenance, CONSOLIDATED);
  assertEquals(result.series["us:AAPL"].volumeIsMarketWide, true);
  assertEquals(result.series["crypto:BTC"].provenance, ALPACA_CRYPTO);
  assertEquals(result.series["crypto:BTC"].volumeIsMarketWide, false);
  assertEquals(Object.keys(result.quotes).sort(), ["crypto:BTC", "us:AAPL"]);
  for (const quote of Object.values(result.quotes)) assert(!("dayVolume" in quote));
  assertEquals(result.failures, {
    "us:MSFT": "Live quote unavailable: Alpaca has no live quote for MSFT",
    "asx:BHP": "Price history unavailable: Yahoo Finance answered with an error (404).",
    "lse:VOD": "Price history unavailable: Yahoo Finance answered with an error (404).",
  });
  // BTC's 1.39 coins a day on Alpaca's venue says nothing about Bitcoin; CoinGecko's figure does.
  assertEquals(result.dollarVolume, { "crypto:BTC": 33_235_034_316 });

  const gecko = calls.filter((call) => call.url.hostname === "api.coingecko.com");
  assertEquals(gecko.length, 1);
  assertEquals(gecko[0].url.searchParams.get("ids"), "bitcoin");
  assertEquals(gecko[0].headers.get("x-cg-demo-api-key"), GECKO_KEY);
  // Each host sees only its own credentials.
  assertEquals(gecko[0].headers.has("APCA-API-KEY-ID"), false);
  assertEquals(gecko[0].headers.has("APCA-API-SECRET-KEY"), false);
  for (const call of calls.filter((call) => call.url.hostname !== "api.coingecko.com")) {
    assertEquals(call.headers.has("x-cg-demo-api-key"), false);
    if (call.url.hostname === "query1.finance.yahoo.com") {
      assertEquals(call.headers.has("APCA-API-KEY-ID") || call.headers.has("APCA-API-SECRET-KEY"), false, "no key goes to Yahoo");
    } else {
      assertEquals(call.url.hostname, "data.alpaca.markets");
    }
  }
});

// ---------------------------------------------------------------------------------------
// Fixtures

const fixtureBars: Bar[] = [bar(nyMidnight(9), 100), bar(nyMidnight(10), 101), bar(nyMidnight(11), 102), bar(nyMidnight(12), 103)];

Deno.test("fixture: everything it serves is marked as fixture data", async () => {
  const provider = new FixtureDataProvider({
    series: { "us:AAPL": { timeframe: "day", bars: fixtureBars }, "asx:BHP": { timeframe: "day", bars: [bar(nyMidnight(12), 45)] } },
    quotes: { "us:AAPL": { last: 103.5, bid: 103.4, ask: 103.6, time: NOW - 2_000, dayVolume: 12_345 }, "asx:BHP": { last: 45.1, time: NOW - 5_000 } },
  });

  assertEquals(provider.supports(BHP), true);
  assertEquals(provider.supports(VOD), true);
  const bars = await provider.bars([AAPL, BHP], "day", 3, NOW);
  const quotes = await provider.quotes([AAPL, BHP], NOW);

  assertEquals(bars.failures, {});
  assertEquals(quotes.failures, {});
  const aapl = bars.series["us:AAPL"];
  assertEquals(aapl.provenance, FIXTURE);
  assertEquals(aapl.provenance.kind, "fixture");
  assertEquals(aapl.bars, fixtureBars.slice(1)); // the last three
  assertEquals(aapl.instrument, AAPL);
  assertEquals(aapl.timeframe, "day");
  assertEquals(aapl.fetchedAt, NOW);
  assertEquals(aapl.volumeIsMarketWide, true); // unless the fixture says otherwise
  assertEquals(bars.series["asx:BHP"].provenance.kind, "fixture");

  assertEquals(quotes.quotes["us:AAPL"], { instrumentID: "us:AAPL", last: 103.5, bid: 103.4, ask: 103.6, time: NOW - 2_000, provenance: FIXTURE, dayVolume: 12_345 });
  assertEquals(quotes.quotes["asx:BHP"], { instrumentID: "asx:BHP", last: 45.1, time: NOW - 5_000, provenance: FIXTURE });

  const named = new FixtureDataProvider({ source: "golden-cross-case", series: { "us:AAPL": { timeframe: "day", bars: fixtureBars } } });
  assertEquals((await named.bars([AAPL], "day", 10, NOW)).series["us:AAPL"].provenance, { kind: "fixture", source: "golden-cross-case", delaySeconds: 0 });
});

Deno.test("fixture: a series can play one venue's volume, with a market-wide dollar volume alongside", async () => {
  const provider = new FixtureDataProvider(JSON.parse(JSON.stringify({
    series: {
      "us:AAPL": { timeframe: "day", bars: fixtureBars, volumeIsMarketWide: true },
      "us:MSFT": { timeframe: "day", bars: fixtureBars, volumeIsMarketWide: null }, // null reads as left out
      "crypto:BTC": { timeframe: "day", bars: fixtureBars, volumeIsMarketWide: false },
      "crypto:ETH": { timeframe: "day", bars: fixtureBars, volumeIsMarketWide: false },
      "crypto:SOL": { timeframe: "day", bars: fixtureBars, volumeIsMarketWide: "no" }, // not a yes or a no
    },
    quotes: { "crypto:BTC": { last: 103, time: NOW }, "us:AAPL": { last: 103, time: NOW } },
    dollarVolume: { "crypto:BTC": 33_235_034_316, "crypto:ETH": 0, "crypto:SOL": "lots", "crypto:XRP": -4, "us:AAPL": 9_000_000_000, "us:TSLA": 7_000_000_000 },
  })));
  const SOL = cryptoAsset("SOL");

  const bars = await provider.bars([AAPL, MSFT, BTC, ETH, SOL], "day", 10, NOW);
  assertEquals(bars.series["us:AAPL"].volumeIsMarketWide, true);
  assertEquals(bars.series["us:MSFT"].volumeIsMarketWide, true);
  assertEquals(bars.series["crypto:BTC"].volumeIsMarketWide, false);
  assertEquals(bars.series["crypto:ETH"].volumeIsMarketWide, false);
  assertEquals(bars.series["crypto:BTC"].provenance, FIXTURE);
  assertEquals(bars.failures, { "crypto:SOL": "No fixture price history for SOL" });

  // Only real figures, and only for what was asked about.
  assertEquals(await provider.dollarVolume([BTC, ETH, SOL, AAPL, cryptoAsset("XRP")], NOW), { "crypto:BTC": 33_235_034_316, "us:AAPL": 9_000_000_000 });
  assertEquals(await provider.dollarVolume([MSFT], NOW), {});
  assertEquals(await new FixtureDataProvider({ dollarVolume: [1, 2] as never }).dollarVolume([BTC], NOW), {});

  // Through snapshot(): the figure is taken for BTC (one venue's volume) and not for AAPL
  // (its bars already count the whole market), whatever the fixture offers.
  const result = await snapshot(provider, [AAPL, BTC, ETH], "day", 10, NOW);
  assertEquals(result.dollarVolume, { "crypto:BTC": 33_235_034_316 });
  assertEquals(Object.keys(result.series).sort(), ["crypto:BTC", "crypto:ETH", "us:AAPL"]);
});

Deno.test("fixture: a missing instrument or the wrong bar size is a failure", async () => {
  const provider = new FixtureDataProvider({ series: { "us:AAPL": { timeframe: "day", bars: fixtureBars } }, quotes: {} });

  const hourly = await provider.bars([AAPL, MSFT], "hour", 3, NOW);
  assertEquals(hourly, { series: {}, failures: { "us:AAPL": "No fixture price history for AAPL", "us:MSFT": "No fixture price history for MSFT" } });
  assertEquals(await provider.quotes([AAPL], NOW), { quotes: {}, failures: { "us:AAPL": "No fixture quote for AAPL" } });
  assertEquals((await provider.bars([AAPL], "day", 0, NOW)).failures, { "us:AAPL": "The number of bars asked for isn't valid" });
  assertEquals(await provider.dollarVolume([AAPL], NOW), {});
  // A key that only exists on Object.prototype is not an instrument.
  const odd: Instrument = { ...usStock("X"), symbol: "constructor" };
  assertEquals(Object.keys((await provider.bars([odd], "day", 3, NOW)).failures), ["us:constructor"]);
});

Deno.test("fixture: malformed input is ignored, not repaired", async () => {
  const fromBody = JSON.parse(JSON.stringify({
    source: 42,
    series: {
      "us:AAPL": { timeframe: "day", bars: fixtureBars },
      "us:MSFT": { timeframe: "day", bars: "lots" },
      "us:TSLA": { timeframe: "minute", bars: fixtureBars },
      "us:SPY": { timeframe: "day", bars: [bar(nyMidnight(11), 500), { time: nyMidnight(12), open: "501", high: 502, low: 500, close: 501, volume: 9 }] },
      "us:NVDA": { timeframe: "day", bars: [{ time: nyMidnight(12), open: 120, high: 121, low: 119, close: 120.5 }] },
      "us:AMD": { timeframe: "day", bars: [{ time: nyMidnight(12), open: -1, high: -1, low: -1, close: -1, volume: 5 }] },
      "us:INTC": null,
      "us:QQQ": [1, 2, 3],
    },
    quotes: {
      "us:AAPL": { last: 103.5, time: NOW, bid: null },
      "us:MSFT": { last: "410", time: NOW },
      "us:TSLA": { last: 300 },
      "us:SPY": { last: 0, time: NOW },
      "us:NVDA": { last: 120, time: NOW, ask: "121" },
      "us:AMD": "150",
    },
  }));
  const provider = new FixtureDataProvider(fromBody);
  const symbols = ["AAPL", "MSFT", "TSLA", "SPY", "NVDA", "AMD", "INTC", "QQQ"];
  const instruments = symbols.map((symbol) => usStock(symbol));

  const bars = await provider.bars(instruments, "day", 10, NOW);
  assertEquals(Object.keys(bars.series), ["us:AAPL"]);
  assertEquals(bars.series["us:AAPL"].provenance, FIXTURE);
  assertEquals(bars.failures, Object.fromEntries(symbols.slice(1).map((symbol) => [`us:${symbol}`, `No fixture price history for ${symbol}`])));

  const quotes = await provider.quotes(instruments, NOW);
  assertEquals(quotes.quotes, { "us:AAPL": { instrumentID: "us:AAPL", last: 103.5, time: NOW, provenance: FIXTURE } });
  assertEquals(Object.keys(quotes.failures).length, 7);

  // Not an object at all: an empty provider, not a crash.
  for (const junk of [null, undefined, "fixture", 7, [], { series: [], quotes: "x", dollarVolume: 5 }, { series: { "us:AAPL": { timeframe: "day", bars: [{ time: Number.NaN, open: 1, high: 1, low: 1, close: 1, volume: 1 }] } } }]) {
    const empty = new FixtureDataProvider(junk as never);
    assertEquals(await empty.bars([AAPL], "day", 5, NOW), { series: {}, failures: { "us:AAPL": "No fixture price history for AAPL" } });
    assertEquals(await empty.quotes([AAPL], NOW), { quotes: {}, failures: { "us:AAPL": "No fixture quote for AAPL" } });
    assertEquals(await empty.dollarVolume([AAPL], NOW), {});
  }
});

// ---------------------------------------------------------------------------------------
// providerFromEnv

const envOf = (values: Record<string, string>) => (name: string) => Object.hasOwn(values, name) ? values[name] : undefined;
const KEYS = { ALPACA_DATA_KEY_ID: KEY_ID, ALPACA_DATA_SECRET: SECRET };
const FIXTURE_BODY = { series: { "us:AAPL": { timeframe: "day", bars: fixtureBars } } };

Deno.test("providerFromEnv: a fixture with the flag on gives the fixture provider — even when real keys are set", async () => {
  const choice = providerFromEnv(envOf({ TRADING_ALLOW_FIXTURE_DATA: "1", ...KEYS }), { fixture: FIXTURE_BODY });
  assertEquals(choice.allowFixtureData, true);
  assertEquals(choice.reason, undefined);
  assert(choice.provider instanceof FixtureDataProvider);
  assertEquals((await choice.provider.bars([AAPL], "day", 2, NOW)).series["us:AAPL"].provenance.kind, "fixture");
});

Deno.test("providerFromEnv: a fixture without the flag gives nothing — never real data instead", () => {
  for (const flag of [undefined, "", "0", "true", "yes", " 1"]) {
    const values: Record<string, string> = { ...KEYS };
    if (flag !== undefined) values.TRADING_ALLOW_FIXTURE_DATA = flag;
    assertEquals(providerFromEnv(envOf(values), { fixture: FIXTURE_BODY }), { provider: null, allowFixtureData: false, reason: "Fixture data isn't allowed here." });
  }
});

Deno.test("providerFromEnv: both Alpaca keys route US shares and crypto to Alpaca, wired to the given fetch and log", async () => {
  const events: Record<string, unknown>[] = [];
  const { fetch: fake, calls } = recorder(() => json({ AAPL: { latestTrade: { t: "2026-11-12T19:59:58Z", p: 228.5 } } }));

  const choice = providerFromEnv(envOf(KEYS), { fetch: fake, log: (event) => events.push(event) });

  assertEquals(choice.allowFixtureData, false);
  assertEquals(choice.reason, undefined);
  assert(choice.provider instanceof RoutedProvider);
  assertEquals(choice.provider.name, "alpaca+yahoo");
  assert(choice.provider.supports(AAPL) && choice.provider.supports(BTC) && choice.provider.supports(BHP) && choice.provider.supports(VOD));
  const quotes = await choice.provider.quotes([AAPL], NOW);
  assertEquals(quotes.quotes["us:AAPL"].last, 228.5);
  assertEquals(quotes.quotes["us:AAPL"].provenance.kind, "market");
  assertEquals(calls[0].headers.get("APCA-API-KEY-ID"), KEY_ID);
  assertEquals(calls[0].headers.get("APCA-API-SECRET-KEY"), SECRET);
  assertEquals(events.length, 1);
  assertNoSecrets(choice);
  assertNoSecrets(events);

  // The flag alone doesn't change which provider real requests get.
  const flagged = providerFromEnv(envOf({ TRADING_ALLOW_FIXTURE_DATA: "1", ...KEYS }));
  assert(flagged.provider instanceof RoutedProvider);
  assertEquals(flagged.provider.name, "alpaca+yahoo");
  assertEquals(flagged.allowFixtureData, true);
});

Deno.test("providerFromEnv: the CoinGecko volume source is always wired in; its key is optional and goes only to CoinGecko", async () => {
  for (const geckoKey of [GECKO_KEY, undefined]) {
    const events: Record<string, unknown>[] = [];
    const { fetch: fake, calls } = recorder(() => json(geckoRows));
    const values: Record<string, string> = { ...KEYS };
    if (geckoKey !== undefined) values.COINGECKO_API_KEY = geckoKey;

    const { provider } = providerFromEnv(envOf(values), { fetch: fake, log: (event) => events.push(event) });
    assert(provider !== null && provider.dollarVolume !== undefined);

    assertEquals(await provider.dollarVolume([BTC, AAPL], NOW), { "crypto:BTC": 33_235_034_316 });
    assertEquals(calls.length, 1);
    assertEquals(calls[0].url.origin, "https://api.coingecko.com");
    assertEquals(calls[0].url.searchParams.get("ids"), "bitcoin");
    assertEquals(calls[0].headers.get("x-cg-demo-api-key"), geckoKey ?? null);
    assertEquals(calls[0].headers.has("APCA-API-KEY-ID"), false);
    assertNoSecrets(calls[0].raw);
    assertEquals(events.map((event) => event.provider), ["coingecko"]);
    assertNoSecrets(events);
  }
});

Deno.test("providerFromEnv: with a store, CoinGecko is asked once a day per coin", async () => {
  const { fetch: fake, calls } = recorder(() => json(geckoRows));
  const store = memoryVolumeStore();
  const { provider } = providerFromEnv(envOf(KEYS), { fetch: fake, volumeStore: store });
  assert(provider !== null && provider.dollarVolume !== undefined);

  assertEquals(await provider.dollarVolume([BTC, AAPL], NOW), { "crypto:BTC": 33_235_034_316 });
  assertEquals(await provider.dollarVolume([BTC], NOW + HOUR), { "crypto:BTC": 33_235_034_316 });
  assertEquals(await provider.dollarVolume([BTC], NOW + DAY - 1), { "crypto:BTC": 33_235_034_316 });
  assertEquals(calls.length, 1, "within the day the stored figure is used");
  assertEquals(store.entries.get("crypto:BTC"), { value: 33_235_034_316, at: NOW, source: "CoinGecko" });

  assertEquals(await provider.dollarVolume([BTC], NOW + DAY + 1), { "crypto:BTC": 33_235_034_316 });
  assertEquals(calls.length, 2, "after a day it is fetched again");
  assertEquals(store.entries.get("crypto:BTC")!.at, NOW + DAY + 1);
});

Deno.test("volume cache: fresh figures are used, missing or stale ones are asked for, unknown stays unknown", async () => {
  const ETH = cryptoAsset("ETH", "Ethereum"), SOL = cryptoAsset("SOL", "Solana");
  const asked: string[][] = [];
  let answer: Record<string, number> = {};
  const source = {
    dollarVolume: (instruments: Instrument[]) => {
      asked.push(instruments.map((instrument) => instrument.symbol));
      return Promise.resolve(answer);
    },
  };
  const store = memoryVolumeStore();
  store.entries.set("crypto:BTC", { value: 5e10, at: NOW - HOUR, source: "CoinGecko" });
  store.entries.set("crypto:ETH", { value: 2e10, at: NOW - DAY - 1, source: "CoinGecko" });     // a day and a millisecond old
  const cached = new CachedVolumeSource(source, store);

  // BTC from the store; ETH (stale) and SOL (never seen) are asked for. The source's junk is dropped.
  answer = { "crypto:ETH": 2.5e10, "crypto:SOL": 0, "crypto:DOGE": 9e9, "crypto:BTC": 1 };
  assertEquals(await cached.dollarVolume([BTC, ETH, SOL, BTC], NOW), { "crypto:BTC": 5e10, "crypto:ETH": 2.5e10 });
  assertEquals(asked, [["ETH", "SOL"]]);
  assertEquals(store.entries.get("crypto:ETH"), { value: 2.5e10, at: NOW, source: "CoinGecko" });
  assertEquals(store.entries.has("crypto:SOL"), false, "a zero is not a figure");
  assertEquals(store.entries.has("crypto:DOGE"), false, "nothing that wasn't asked for is stored");
  assertEquals(store.entries.get("crypto:BTC")!.value, 5e10, "a fresh figure isn't replaced by the source's stray answer");

  // Everything fresh: the source isn't asked at all.
  asked.length = 0;
  assertEquals(await cached.dollarVolume([BTC, ETH], NOW + MINUTE), { "crypto:BTC": 5e10, "crypto:ETH": 2.5e10 });
  assertEquals(asked, []);
  assertEquals(await cached.dollarVolume([], NOW), {});

  // An older write never replaces a newer figure.
  await store.write({ "crypto:ETH": 1 }, NOW - MINUTE, "CoinGecko");
  assertEquals(store.entries.get("crypto:ETH")!.value, 2.5e10);
});

Deno.test("volume cache: a broken store or source means asking directly, never a made-up figure", async () => {
  const live = { dollarVolume: () => Promise.resolve({ "crypto:BTC": 4e10 }) };
  const events: Record<string, unknown>[] = [];
  const unreadable = { read: () => Promise.reject(new Error("db down")), write: () => Promise.reject(new Error("db down")) };
  assertEquals(await new CachedVolumeSource(live, unreadable, { log: (event) => events.push(event) }).dollarVolume([BTC], NOW), { "crypto:BTC": 4e10 });
  assertEquals(events.map((event) => event.event), ["volume_cache_read_failed", "volume_cache", "volume_cache_write_failed"]);
  assert(!JSON.stringify(events).includes("db down"), "store errors aren't logged verbatim");

  // The store hands back junk: ignored.
  const junk = { read: () => Promise.resolve({ "crypto:BTC": -1 } as Record<string, number>), write: () => Promise.resolve() };
  assertEquals(await new CachedVolumeSource(live, junk).dollarVolume([BTC], NOW), { "crypto:BTC": 4e10 });

  // The source fails: only what was fresh in the store comes back.
  const failing = { dollarVolume: () => Promise.reject(new Error("429")) };
  const store = memoryVolumeStore();
  assertEquals(await new CachedVolumeSource(failing, store).dollarVolume([BTC], NOW), {});
  store.entries.set("crypto:BTC", { value: 3e10, at: NOW - HOUR, source: "CoinGecko" });
  assertEquals(await new CachedVolumeSource(failing, store).dollarVolume([BTC], NOW), { "crypto:BTC": 3e10 });
});

Deno.test("providerFromEnv: without both Alpaca keys, only the exchanges Yahoo prices are covered", async () => {
  const cases: Record<string, string>[] = [
    {},
    { ALPACA_DATA_KEY_ID: KEY_ID },
    { ALPACA_DATA_SECRET: SECRET },
    { ALPACA_DATA_KEY_ID: "", ALPACA_DATA_SECRET: SECRET },
    { ALPACA_DATA_KEY_ID: KEY_ID, ALPACA_DATA_SECRET: "  " },
    { COINGECKO_API_KEY: GECKO_KEY }, // a volume source alone is not market data
  ];
  for (const values of cases) {
    const choice = providerFromEnv(envOf(values));
    assert(choice.provider instanceof RoutedProvider);
    assertEquals([choice.provider.name, choice.allowFixtureData, choice.reason], ["yahoo", false, "Market data for US shares and crypto isn't configured."]);
    assertEquals([AAPL, BTC, BHP, VOD].map((instrument) => choice.provider!.supports(instrument)), [false, false, true, true]);
  }
  // US shares and crypto get a reason, never a price from somewhere else; nothing was fetched for them.
  const { fetch: fake, calls } = recorder(() => json({}));
  const { provider } = providerFromEnv(envOf({ TRADING_ALLOW_FIXTURE_DATA: "1" }), { fetch: fake });
  const answer = await provider!.quotes([AAPL, BTC], NOW);
  assertEquals(answer, { quotes: {}, failures: { "us:AAPL": "Market data for the US market isn't configured on the server", "crypto:BTC": "Market data for the Crypto isn't configured on the server" } });
  assertEquals(calls.length, 0);
});

// ---------------------------------------------------------------------------------------
// The guard: this layer reads market data and can do nothing else.

Deno.test("source guard: no trading host, no order or account path, no write method, no clock", async () => {
  const sources = ["provider.ts", "alpaca.ts", "coingecko.ts", "fixture.ts", "index.ts", "volume_cache.ts", "yahoo.ts", "routed.ts", "ui_test_fixture.ts"];
  const hosts = new Set<string>();
  for (const name of sources) {
    const text = await Deno.readTextFile(new URL(`../_shared/market/${name}`, import.meta.url));
    assert(text.length > 0);

    const withoutDataHost = text.replaceAll("data.alpaca.markets", "");
    assert(!withoutDataHost.includes("api.alpaca.markets"), `${name} names a non-data Alpaca host`);
    // The only other Alpaca host a source may name is the documentation, in a comment.
    const otherHosts = [...withoutDataHost.matchAll(/([a-z0-9-]+)\.alpaca\.markets/gi)].map((match) => match[1].toLowerCase());
    assertEquals(otherHosts.filter((host) => host !== "docs"), [], `${name} names another Alpaca host`);
    for (const forbidden of ["/v2/orders", "/v2/account", "/v2/positions", "/v2/assets", "/v2/watchlists", "paper-api", "/orders", "/accounts"]) {
      assert(!text.includes(forbidden), `${name} mentions ${forbidden}`);
    }
    assert(!/["'`](POST|PUT|PATCH|DELETE)["'`]/.test(text), `${name} uses a write method`);
    assertEquals([...text.matchAll(/method:\s*"([A-Z]+)"/g)].map((match) => match[1]).filter((method) => method !== "GET"), [], `${name} uses a method other than GET`);
    assert(!text.includes("Date.now"), `${name} reads the clock`);
    assertNoSecrets(text);
    for (const match of text.matchAll(/https?:\/\/([a-z0-9.-]+)/gi)) hosts.add(match[1].toLowerCase());
  }
  // Three hosts are ever written down: Alpaca's data host, CoinGecko's public API and Yahoo's chart host.
  assertEquals([...hosts].sort(), ["api.coingecko.com", "data.alpaca.markets", "query1.finance.yahoo.com"]);
  // Yahoo: one read-only path, GET only, and nothing that looks like a credential.
  const yahoo = await Deno.readTextFile(new URL("../_shared/market/yahoo.ts", import.meta.url));
  assertEquals([...yahoo.matchAll(/"(\/v[^"]*)"/g)].map((match) => match[1]), ["/v8/finance/chart/"]);
  assertEquals([...yahoo.matchAll(/method:\s*"([A-Z]+)"/g)].map((match) => match[1]), ["GET"]);
  assert(!/api[_-]?key|authorization|cookie|crumb/i.test(yahoo), "Yahoo needs no credential and gets none");

  // Every path literal in the Alpaca provider is one of the four read-only data paths.
  const alpaca = await Deno.readTextFile(new URL("../_shared/market/alpaca.ts", import.meta.url));
  const paths = [...alpaca.matchAll(/"(\/v[^"]*)"/g)].map((match) => match[1]).sort();
  assertEquals(paths, ["/v1beta3/crypto/us/bars", "/v1beta3/crypto/us/snapshots", "/v2/stocks/bars", "/v2/stocks/snapshots"]);
  assertEquals([...alpaca.matchAll(/method:\s*"([A-Z]+)"/g)].map((match) => match[1]), ["GET"]);

  // CoinGecko: one read-only URL, and the key is only ever a header.
  const gecko = await Deno.readTextFile(new URL("../_shared/market/coingecko.ts", import.meta.url));
  assertEquals([...gecko.matchAll(/"(https:\/\/[^"]+)"/g)].map((match) => match[1]), ["https://api.coingecko.com/api/v3/coins/markets"]);
  assertEquals([...gecko.matchAll(/method:\s*"([A-Z]+)"/g)].map((match) => match[1]), ["GET"]);
  assert(!gecko.includes("x_cg_demo_api_key") && !gecko.includes("x_cg_pro_api_key"), "the CoinGecko key must never be a query parameter");
});

// ---------------------------------------------------------------------------------------
// Yahoo Finance: the eleven exchanges outside the US (a port of the app's exchangeChart,
// exchangeDailyBars and exchangeQuote).

const TOYOTA = listed("7203", "tse", "Toyota");
const NESTLE = listed("NESN", "six", "Nestlé");
const RELIANCE = listed("RELIANCE", "nse", "Reliance");
const yday = (date: string) => Date.parse(`${date}T08:00:00Z`) / 1_000;

type YahooRow = [number, number | null, number | null, number | null, number | null, number | null];

/** A chart answer the way Yahoo sends it (checked against a live VOD.L call, 13 Nov 2026). */
function yahooChart(meta: Record<string, unknown>, rows: YahooRow[] = []) {
  return {
    chart: {
      result: [{
        meta: { exchangeTimezoneName: "Europe/London", instrumentType: "EQUITY", ...meta },
        timestamp: rows.map((row) => row[0]),
        indicators: {
          quote: [{
            open: rows.map((row) => row[1]), high: rows.map((row) => row[2]), low: rows.map((row) => row[3]),
            close: rows.map((row) => row[4]), volume: rows.map((row) => row[5]),
          }],
        },
      }],
      error: null,
    },
  };
}

function yahooHarness(reply: Reply, options: Partial<YahooFinanceProviderOptions> = {}) {
  const { fetch: fake, calls } = recorder(reply);
  const sleeps: number[] = [];
  const events: Record<string, unknown>[] = [];
  const provider = new YahooFinanceProvider({
    fetch: fake,
    sleep: (ms) => {
      sleeps.push(ms);
      return Promise.resolve();
    },
    log: (event) => events.push(event),
    ...options,
  });
  return { provider, calls, sleeps, events };
}

const chartSymbol = (call: Call) => decodeURIComponent(call.url.pathname.split("/").pop()!);

Deno.test("Yahoo: a pence listing is converted to pounds; bars skip incomplete rows; one GET with a browser User-Agent", async () => {
  const { provider, calls, events } = yahooHarness(() => json(yahooChart({ currency: "GBp", regularMarketPrice: 115.95, regularMarketTime: 1794557611 }, [
    [yday("2026-11-09"), 116, 118, 115, 116.95, 1_200_000],
    [yday("2026-11-10"), 117, 117.5, 115.5, 115.75, null], // no volume: counted as 0, as the app does
    [yday("2026-11-11"), null, 118, 116, 117.35, 900_000], // no open: skipped
    [yday("2026-11-12"), 117.3, 118.1, 116.2, 117.8, 1_000_000],
  ])));
  const answer = await provider.bars([VOD], "day", 3, NOW);
  assertEquals(answer.failures, {});
  const series = answer.series["lse:VOD"];
  assertEquals(series.provenance, { kind: "market", source: "Yahoo Finance (LSE, 15 min delayed)", delaySeconds: 900 });
  assertEquals(series.volumeIsMarketWide, true, "the home exchange's volume counts as market-wide");
  assertEquals([series.timeframe, series.fetchedAt], ["day", NOW]);
  // The last three complete rows, in pounds (×0.01), volume untouched.
  assertEquals(series.bars, [
    { time: yday("2026-11-09") * 1_000, open: 116 * 0.01, high: 118 * 0.01, low: 115 * 0.01, close: 116.95 * 0.01, volume: 1_200_000 },
    { time: yday("2026-11-10") * 1_000, open: 117 * 0.01, high: 117.5 * 0.01, low: 115.5 * 0.01, close: 115.75 * 0.01, volume: 0 },
    { time: yday("2026-11-12") * 1_000, open: 117.3 * 0.01, high: 118.1 * 0.01, low: 116.2 * 0.01, close: 117.8 * 0.01, volume: 1_000_000 },
  ]);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url.origin + calls[0].url.pathname, "https://query1.finance.yahoo.com/v8/finance/chart/VOD.L");
  assertEquals([calls[0].url.searchParams.get("interval"), calls[0].url.searchParams.get("range")], ["1d", "1y"]);
  assertEquals(calls[0].init.method, "GET");
  assertEquals(calls[0].headers.get("User-Agent"), "Mozilla/5.0");
  assertEquals(events.map((event) => [event.provider, event.path, event.status]), [["yahoo", "/v8/finance/chart/", 200]]);

  // The quote: regularMarketPrice in pounds, at regularMarketTime, with the day's volume.
  const quoted = yahooHarness(() => json(yahooChart({ currency: "GBp", regularMarketPrice: 115.95, regularMarketTime: 1794557611, regularMarketVolume: 907253 })));
  const quote = (await quoted.provider.quotes([VOD], NOW)).quotes["lse:VOD"];
  assertEquals(quote, {
    instrumentID: "lse:VOD", last: 115.95 * 0.01, time: 1794557611_000, dayVolume: 907253,
    provenance: { kind: "market", source: "Yahoo Finance (LSE, 15 min delayed)", delaySeconds: 900 },
  });
  assertEquals(quoted.calls[0].url.searchParams.get("range"), "5d");
});

Deno.test("Yahoo: a listing quoted in another currency is refused, never mixed", async () => {
  const { provider } = yahooHarness(() => json(yahooChart({ currency: "USD", regularMarketPrice: 12.5, regularMarketTime: 1794557611 }, [[yday("2026-11-12"), 12, 13, 11.5, 12.5, 10]])));
  const reason = "VOD is quoted in USD on the London market, not GBP, so it can't be practice traded here.";
  assertEquals(await provider.bars([VOD], "day", 5, NOW), { series: {}, failures: { "lse:VOD": reason } });
  assertEquals(await provider.quotes([VOD], NOW), { quotes: {}, failures: { "lse:VOD": reason } });
});

Deno.test("Yahoo: no regularMarketTime, no price, an empty or missing result: no quote and no bars", async () => {
  const cases: [string, unknown][] = [
    ["missing regularMarketTime", yahooChart({ currency: "GBp", regularMarketPrice: 115.95 })],
    ["unreadable regularMarketTime", yahooChart({ currency: "GBp", regularMarketPrice: 115.95, regularMarketTime: "today" })],
    ["zero price", yahooChart({ currency: "GBp", regularMarketPrice: 0, regularMarketTime: 1794557611 })],
    ["no price", yahooChart({ currency: "GBp", regularMarketTime: 1794557611 })],
    ["empty result", { chart: { result: [], error: null } }],
    ["null result", { chart: { result: null, error: { code: "Not Found", description: "No data found" } } }],
    ["no currency", yahooChart({ regularMarketPrice: 115.95, regularMarketTime: 1794557611 })],
  ];
  for (const [name, body] of cases) {
    const { provider } = yahooHarness(() => json(body));
    assertEquals(await provider.quotes([VOD], NOW), { quotes: {}, failures: { "lse:VOD": "No prices came back for VOD." } }, name);
  }
  // A chart with no usable rows is no history.
  const empty = yahooHarness(() => json(yahooChart({ currency: "GBp" }, [[yday("2026-11-12"), null, null, null, null, null]])));
  assertEquals(await empty.provider.bars([VOD], "day", 5, NOW), { series: {}, failures: { "lse:VOD": "No prices came back for VOD." } });
  const noRows = yahooHarness(() => json({ chart: { result: [{ meta: { currency: "GBp" } }], error: null } }));
  assertEquals(await noRows.provider.bars([VOD], "day", 5, NOW), { series: {}, failures: { "lse:VOD": "No prices came back for VOD." } });
});

Deno.test("Yahoo: HTTP 429 and 5xx are retried with backoff (as for Alpaca); a 404 or a timeout is reported, nothing invented", async () => {
  // Rate limited twice, then an answer.
  const ok = yahooChart({ currency: "JPY", regularMarketPrice: 2_950, regularMarketTime: 1794557611 });
  const recovering = yahooHarness((_call, index) => index < 2 ? json({}, 429, { "retry-after": "1" }) : json(ok));
  assertEquals((await recovering.provider.quotes([TOYOTA], NOW)).quotes["tse:7203"].last, 2_950);
  assertEquals([recovering.calls.length, recovering.sleeps], [3, [1_000, 1_000]]);

  // Rate limited every time: three attempts, then the reason.
  const limited = yahooHarness(() => json({}, 429));
  assertEquals(await limited.provider.quotes([TOYOTA], NOW), { quotes: {}, failures: { "tse:7203": "Yahoo Finance answered with an error (429)." } });
  assertEquals([limited.calls.length, limited.sleeps], [3, [300, 600]]);

  const down = yahooHarness(() => json({}, 503));
  assertEquals((await down.provider.bars([TOYOTA], "day", 5, NOW)).failures, { "tse:7203": "Yahoo Finance answered with an error (503)." });
  assertEquals(down.calls.length, 3);

  // Not found: not retried.
  const missing = yahooHarness(() => json({ chart: { result: null, error: { code: "Not Found" } } }, 404));
  assertEquals((await missing.provider.quotes([TOYOTA], NOW)).failures, { "tse:7203": "Yahoo Finance answered with an error (404)." });
  assertEquals(missing.calls.length, 1);

  const hung = yahooHarness(hang, { timeoutMs: 5, maxAttempts: 2 });
  assertEquals((await hung.provider.quotes([TOYOTA], NOW)).failures, { "tse:7203": "The request timed out" });
  const unreadable = yahooHarness(() => new Response("<html>consent</html>", { status: 200 }));
  assertEquals((await unreadable.provider.quotes([TOYOTA], NOW)).failures, { "tse:7203": "Yahoo Finance returned an unreadable response" });
});

Deno.test("Yahoo: the app's per-exchange delays, ranges and symbols; hourly bars, US shares and crypto aren't its job", async () => {
  const venues = ["asx", "lse", "xetra", "euronextParis", "euronextAmsterdam", "six", "tse", "hkex", "sgx", "krx", "nse"] as const;
  const delays = Object.fromEntries(venues.map((venue) => [venue, yahooProvenance(venue).delaySeconds / 60]));
  assertEquals(delays, { asx: 20, lse: 15, xetra: 15, euronextParis: 15, euronextAmsterdam: 15, six: 30, tse: 20, hkex: 15, sgx: 15, krx: 20, nse: 0 });
  assertEquals(yahooProvenance("nse").source, "Yahoo Finance (NSE)", "no delay, no 'delayed' in the label");
  assertEquals(yahooProvenance("six").source, "Yahoo Finance (SIX, 30 min delayed)");
  assertEquals(yahooProvenance("asx").source, "Yahoo Finance (ASX, 20 min delayed)");

  // Every venue's own suffix and currency, one request each, duplicates asked once.
  const currencies: Record<string, string> = { "BHP.AX": "AUD", "7203.T": "JPY", "NESN.SW": "CHF", "RELIANCE.NS": "INR" };
  const { provider, calls } = yahooHarness((call) => json(yahooChart({ currency: currencies[chartSymbol(call)], regularMarketPrice: 10, regularMarketTime: 1794557611 })));
  const answer = await provider.quotes([BHP, TOYOTA, NESTLE, RELIANCE, BHP], NOW);
  assertEquals(Object.keys(answer.quotes).sort(), ["asx:BHP", "nse:RELIANCE", "six:NESN", "tse:7203"]);
  assertEquals(calls.map(chartSymbol).sort(), ["7203.T", "BHP.AX", "NESN.SW", "RELIANCE.NS"]);

  for (const [count, range] of [[30, "1y"], [250, "1y"], [251, "2y"], [500, "2y"], [501, "5y"]] as const) {
    const h = yahooHarness(() => json(yahooChart({ currency: "AUD" }, [[yday("2026-11-12"), 1, 2, 0.5, 1.5, 10]])));
    await h.provider.bars([BHP], "day", count, NOW);
    assertEquals(h.calls[0].url.searchParams.get("range"), range, `count ${count}`);
  }

  const refused = yahooHarness(() => json({}));
  assertEquals(await refused.provider.bars([BHP], "hour", 30, NOW), { series: {}, failures: { "asx:BHP": "Hourly bars aren't available for shares on the ASX." } });
  assertEquals((await refused.provider.quotes([AAPL, BTC], NOW)).failures, {
    "us:AAPL": "This market isn't supported by this data source", "crypto:BTC": "This market isn't supported by this data source",
  });
  assertEquals(refused.calls.length, 0);
  assertEquals([AAPL, BTC, BHP, VOD, TOYOTA].map((instrument) => refused.provider.supports(instrument)), [false, false, true, true, true]);
  // A symbol with characters that could steer a URL never reaches one.
  const odd = yahooHarness(() => json(yahooChart({ currency: "GBP", regularMarketPrice: 1, regularMarketTime: 1 })));
  await odd.provider.quotes([{ ...VOD, symbol: "VOD/../x?y=1" }], NOW);
  assertEquals(odd.calls[0].url.pathname, "/v8/finance/chart/VOD..XY1.L");
});

Deno.test("routing: each instrument goes to the source for its market, and the answers are merged", async () => {
  const { fetch: fake, calls } = recorder((call) => call.url.hostname === "query1.finance.yahoo.com"
    ? json(yahooChart({ currency: "AUD", regularMarketPrice: 45.1, regularMarketTime: 1794557611 }))
    : json({ AAPL: { latestTrade: { t: "2026-11-12T19:59:58Z", p: 228.5 } } }));
  const { provider } = providerFromEnv(envOf(KEYS), { fetch: fake });
  const answer = await provider!.quotes([AAPL, BHP], NOW);
  assertEquals([answer.quotes["us:AAPL"].last, answer.quotes["asx:BHP"].last], [228.5, 45.1]);
  assertEquals(answer.quotes["asx:BHP"].provenance.source, "Yahoo Finance (ASX, 20 min delayed)");
  assertEquals(calls.map((call) => call.url.hostname).sort(), ["data.alpaca.markets", "query1.finance.yahoo.com"]);
  const toYahoo = calls.find((call) => call.url.hostname === "query1.finance.yahoo.com")!;
  assertEquals(toYahoo.headers.has("APCA-API-KEY-ID") || toYahoo.headers.has("APCA-API-SECRET-KEY"), false, "Alpaca's keys never go to Yahoo");
});

// ---------------------------------------------------------------------------------------
// The app's UI-test prices (FixtureMarketData).

Deno.test("ui-test fixture: the app's formula, bar days, volume, ±1 bp quotes and fixture label", async () => {
  const choice = providerFromEnv(envOf({ TRADING_ALLOW_FIXTURE_DATA: "1", ...KEYS }), { fixture: "ui-test" });
  assert(choice.provider instanceof UITestFixtureProvider);
  assertEquals(providerFromEnv(envOf(KEYS), { fixture: "ui-test" }), { provider: null, allowFixtureData: false, reason: "Fixture data isn't allowed here." });
  const provider = choice.provider;

  // close(i) = base × (1 + i × (0.0015 + drift) + sin(i / 6) × 0.02); AAPL's scalars sum to 291, so drift = 1 × 0.0002.
  assertEquals(uiTestCloses(AAPL, 3), [200, 200 * (1 + 1 * (0.0015 + 0.0002) + Math.sin(1 / 6) * 0.02), 200 * (1 + 2 * (0.0015 + 0.0002) + Math.sin(2 / 6) * 0.02)]);
  assertEquals([uiTestCloses(MSFT, 1), uiTestCloses(BTC, 1), uiTestCloses(BHP, 1)], [[400], [60_000], [200]]);

  const series = (await provider.bars([BHP, BTC], "day", 30, NOW)).series;
  const bhp = series["asx:BHP"];
  assertEquals([bhp.bars.length, bhp.provenance, bhp.timeframe, bhp.fetchedAt], [30, { kind: "fixture", source: "ui-test", delaySeconds: 0 }, "day", NOW]);
  const closes = uiTestCloses(BHP, 30);
  const sydneyClock = new Intl.DateTimeFormat("en-GB", { timeZone: timeZone("asx"), hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  bhp.bars.forEach((b, i) => {
    const open = i === 0 ? closes[0] : closes[i - 1];
    assertEquals(b, { time: b.time, open, high: Math.max(open, closes[i]) * 1.004, low: Math.min(open, closes[i]) * 0.996, close: closes[i], volume: 8_000_000 });
    // Midnight in Sydney on an ASX trading day, before the day `now` falls on.
    assert(isTradingDay("asx", b.time), new Date(b.time).toISOString());
    assertEquals(sydneyClock.format(b.time), "00:00");
  });
  assert(bhp.bars[29].time < NOW && bhp.bars.every((b, i) => i === 0 || b.time > bhp.bars[i - 1].time));
  // Crypto: every calendar day, midnight UTC, up to yesterday (NOW is 12 Nov 2026, 20:00 UTC).
  assertEquals(series["crypto:BTC"].bars.map((b) => b.time).slice(-2), [Date.UTC(2026, 10, 10), Date.UTC(2026, 10, 11)]);

  // The quote is the 260th close, 1 bp either side, stamped now; no day volume.
  const quote = (await provider.quotes([AAPL], NOW)).quotes["us:AAPL"];
  const last = uiTestCloses(AAPL, 260)[259];
  assertEquals(quote, { instrumentID: "us:AAPL", last, bid: last * 0.9999, ask: last * 1.0001, time: NOW, provenance: { kind: "fixture", source: "ui-test", delaySeconds: 0 } });
  // An hourly request keeps its timeframe (as the app's fixture does).
  assertEquals((await provider.bars([AAPL], "hour", 5, NOW)).series["us:AAPL"].timeframe, "hour");
  assertEquals((await provider.bars([AAPL], "day", 0, NOW)).failures["us:AAPL"], "The number of bars must be a whole number from 1 to 5000");
});
