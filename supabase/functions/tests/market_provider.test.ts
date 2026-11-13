// Market-data providers. Every test runs on an injected fetch and an instant sleep:
// nothing here touches the network, and the "keys" are the words below.
//
//   npx -y deno test --allow-read --allow-env --no-check=remote supabase/functions/tests/market_provider.test.ts

import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { asxStock, type Bar, type BarSeries, cryptoAsset, type Instrument, makeBarSeries, marketProvenance, type Quote, usETF, usStock } from "../_shared/trading/market.ts";
import { AlpacaDataProvider, type AlpacaDataProviderOptions } from "../_shared/market/alpaca.ts";
import { FixtureDataProvider } from "../_shared/market/fixture.ts";
import { providerFromEnv } from "../_shared/market/index.ts";
import { type MarketDataProvider, parseVenueTime, ProviderError, snapshot } from "../_shared/market/provider.ts";

const KEY_ID = "test-key-id";
const SECRET = "test-secret";

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

// ---------------------------------------------------------------------------------------
// A stand-in for fetch that records what was asked.

interface Call {
  raw: string;
  url: URL;
  headers: Headers;
  init: RequestInit;
}

type Reply = (call: Call, index: number) => Response | Promise<Response>;

function harness(reply: Reply, options: Partial<AlpacaDataProviderOptions> = {}) {
  const calls: Call[] = [];
  const sleeps: number[] = [];
  const events: Record<string, unknown>[] = [];
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

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}

const stamp = (time: number) => new Date(time).toISOString().replace(".000Z", "Z");

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
}

// ---------------------------------------------------------------------------------------
// Bars

Deno.test("stock bars: follows pagination and keeps only the last `count`, oldest first", async () => {
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

  assertEquals(calls.length, 2);
  assertEquals(calls[1].url.searchParams.get("page_token"), "page-2");
  for (const name of ["symbols", "timeframe", "start", "limit", "adjustment", "feed", "sort"]) {
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
  assertEquals(aapl.provenance, { kind: "market", source: "Alpaca (IEX)", delaySeconds: 0 });
  assertEquals(aapl.fetchedAt, NOW);

  // Fewer than asked for is returned as it is — never padded.
  assertEquals(result.series["us:MSFT"].bars, [bar(nyMidnight(11), 410), bar(nyMidnight(12), 412)]);
});

Deno.test("stock bars: the request is adjusted, IEX, ascending, authenticated by header — and the URL holds no key", async () => {
  const { provider, calls } = harness(() => json({ bars: {}, next_page_token: null }));

  await provider.bars([AAPL, SPY], "day", 3, NOW);
  await provider.bars([AAPL], "hour", 60, NOW);

  const [daily, hourly] = calls;
  assertEquals(daily.url.origin, "https://data.alpaca.markets");
  assertEquals(daily.url.pathname, "/v2/stocks/bars");
  assertEquals(daily.init.method, "GET");
  assertEquals(daily.init.redirect, "manual");
  assert(daily.init.signal instanceof AbortSignal);

  const query = daily.url.searchParams;
  assertEquals(query.get("symbols"), "AAPL,SPY");
  assertEquals(query.get("timeframe"), "1Day");
  assertEquals(query.get("adjustment"), "all");
  assertEquals(query.get("feed"), "iex");
  assertEquals(query.get("sort"), "asc");
  assertEquals(query.get("limit"), "10000");
  // 3 bars → 3 × 1.6 + 10 = 14.8, rounded up to 15 calendar days back.
  assertEquals(query.get("start"), stamp(NOW - 15 * DAY));
  assertEquals(query.get("start"), "2026-10-28T20:00:00Z");
  assertEquals(query.get("end"), null);
  assertEquals(query.get("page_token"), null);

  assertEquals(hourly.url.searchParams.get("timeframe"), "1Hour");
  // 60 hourly bars → (60 / 6) × 1.6 + 5 = 21 calendar days back.
  assertEquals(hourly.url.searchParams.get("start"), stamp(NOW - 21 * DAY));

  for (const call of calls) {
    assertEquals(call.headers.get("APCA-API-KEY-ID"), KEY_ID);
    assertEquals(call.headers.get("APCA-API-SECRET-KEY"), SECRET);
    assertNoSecrets(call.raw);
  }
});

Deno.test("crypto bars: BTC is asked for as BTC/USD, URL-encoded, on the crypto path", async () => {
  const { provider, calls } = harness(() =>
    json({
      bars: {
        "BTC/USD": [wireBar(NOW - 2 * HOUR, 70_000, 0.5), wireBar(NOW - HOUR, 70_500, 0)],
        "ETH/USD": [wireBar(NOW - HOUR, 2_000, 3)],
      },
      next_page_token: null,
    })
  );

  const result = await provider.bars([BTC, ETH], "hour", 24, NOW);
  await provider.bars([BTC], "day", 30, NOW);

  const [hourly, daily] = calls;
  assertEquals(hourly.url.pathname, "/v1beta3/crypto/us/bars");
  assertEquals(hourly.url.searchParams.get("symbols"), "BTC/USD,ETH/USD");
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

  assertEquals(result.failures, {});
  assertEquals(result.series["crypto:BTC"].instrument, BTC);
  assertEquals(result.series["crypto:BTC"].provenance, { kind: "market", source: "Alpaca (crypto)", delaySeconds: 0 });
  // A quiet hour has volume 0 and real (quote-derived) prices; it is a valid bar and stays.
  assertEquals(result.series["crypto:BTC"].bars, [bar(NOW - 2 * HOUR, 70_000, 0.5), bar(NOW - HOUR, 70_500, 0)]);
  assertEquals(result.series["crypto:ETH"].bars, [bar(NOW - HOUR, 2_000, 3)]);
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
  assertEquals(result.failures, {});
});

Deno.test("bars: a missing symbol, null bars or only unusable bars is a failure — no series is made up", async () => {
  const { provider } = harness(() =>
    json({
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
  );

  const result = await provider.bars([AAPL, MSFT, TSLA, SPY, usStock("NVDA")], "day", 5, NOW);

  assertEquals(Object.keys(result.series), ["us:AAPL"]);
  assertEquals(result.failures, {
    "us:MSFT": "Alpaca has no price history for MSFT",
    "us:TSLA": "Alpaca has no price history for TSLA",
    "us:SPY": "Alpaca has no price history for SPY",
    "us:NVDA": "Alpaca has no price history for NVDA",
  });
});

Deno.test("bars: `bars: null` for the whole answer means nobody has history", async () => {
  const { provider } = harness(() => json({ bars: null, next_page_token: null }));
  const result = await provider.bars([AAPL, MSFT], "day", 5, NOW);
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

  assertEquals(calls.length, 3); // page 1, then page 2 twice
  assertEquals(result.series, {});
  assertEquals(result.failures, { "us:AAPL": "Alpaca returned HTTP 500", "us:MSFT": "Alpaca returned HTTP 500" });
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

Deno.test("bars: symbols are batched, and a failed batch fails only its own instruments", async () => {
  const stocks = Array.from({ length: 130 }, (_, index) => usStock(`T${String(index).padStart(3, "0")}`));
  const { provider, calls } = harness((call) => {
    const symbols = call.url.searchParams.get("symbols")!.split(",");
    if (symbols.includes("T000")) return json({ message: "bad request" }, 400);
    return json({ bars: Object.fromEntries(symbols.map((symbol) => [symbol, [wireBar(nyMidnight(12), 50)]])), next_page_token: null });
  });

  const result = await provider.bars(stocks, "day", 1, NOW);

  assertEquals(calls.map((call) => call.url.searchParams.get("symbols")!.split(",").length).sort(), [100, 30]);
  assertEquals(Object.keys(result.failures).length, 100);
  assertEquals(Object.keys(result.series).length, 30);
  assertEquals(result.failures["us:T000"], "Alpaca returned HTTP 400");
  assertEquals(result.failures["us:T099"], "Alpaca returned HTTP 400");
  assertEquals(result.series["us:T100"].bars, [bar(nyMidnight(12), 50)]);
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
  assertEquals(calls[0].url.searchParams.get("symbols"), "AAPL"); // once, though it was listed twice
  assertEquals(Object.keys(result.series), ["us:AAPL"]);
  assertEquals(result.failures, {
    "us:MSFT,TSLA": "Alpaca has no data for MSFT,TSLA",
    "crypto:BTC/USD": "Alpaca has no data for BTC/USD",
  });
});

// ---------------------------------------------------------------------------------------
// Quotes

Deno.test("stock quotes: the trade's own time is the quote time; a zero bid or ask is left out; day volume only for the trade's day", async () => {
  const { provider, calls } = harness(() =>
    // Alpaca keys stock snapshots by symbol at the top level.
    json({
      AAPL: {
        latestTrade: { t: "2026-11-12T19:59:58.123456789Z", p: 228.5, s: 100, x: "V" },
        latestQuote: { t: "2026-11-12T19:59:59Z", bp: 0, ap: 228.6 },
        dailyBar: { t: stamp(nyMidnight(12)), o: 227, h: 229, l: 226.5, c: 228.5, v: 51_234 },
      },
      // 8 am in New York: the last trade is today's, the daily bar is still yesterday's.
      MSFT: {
        latestTrade: { t: "2026-11-12T13:00:00Z", p: 410 },
        latestQuote: { t: "2026-11-12T13:00:01Z", bp: 409.9, ap: 410.1 },
        dailyBar: { t: stamp(nyMidnight(11)), v: 99_999 },
      },
      TSLA: {
        latestTrade: { t: "2026-11-12T19:00:00Z", p: 300.25 },
        latestQuote: { t: "2026-11-12T19:00:00Z", bp: 300.2, ap: 0 },
        dailyBar: { t: stamp(nyMidnight(12)), v: 0 },
      },
      SPY: { latestTrade: { t: "2026-11-12T19:30:00-05:00", p: 590 } },
    })
  );

  const result = await provider.quotes([AAPL, MSFT, TSLA, SPY], NOW);

  assertEquals(calls.length, 1);
  assertEquals(calls[0].url.pathname, "/v2/stocks/snapshots");
  assertEquals(calls[0].url.searchParams.get("symbols"), "AAPL,MSFT,TSLA,SPY");
  assertEquals(calls[0].url.searchParams.get("feed"), "iex");
  assertEquals(calls[0].headers.get("APCA-API-KEY-ID"), KEY_ID);
  assertEquals(calls[0].headers.get("APCA-API-SECRET-KEY"), SECRET);
  assertNoSecrets(calls[0].raw);
  assertEquals(result.failures, {});

  const iex = { kind: "market", source: "Alpaca (IEX)", delaySeconds: 0 };
  const aapl = result.quotes["us:AAPL"];
  assertEquals(aapl, {
    instrumentID: "us:AAPL",
    last: 228.5,
    ask: 228.6,
    time: Date.UTC(2026, 10, 12, 19, 59, 58, 123),
    provenance: iex,
    dayVolume: 51_234,
  } as Quote);
  assert(aapl.time !== NOW, "the quote time is the venue's, not the fetch time");
  assert(!("bid" in aapl), "a zero bid is absent, not zero");

  assertEquals(result.quotes["us:MSFT"], { instrumentID: "us:MSFT", last: 410, bid: 409.9, ask: 410.1, time: Date.UTC(2026, 10, 12, 13), provenance: iex } as Quote);
  assert(!("dayVolume" in result.quotes["us:MSFT"]), "yesterday's volume is not today's");

  assertEquals(result.quotes["us:TSLA"], { instrumentID: "us:TSLA", last: 300.25, bid: 300.2, time: Date.UTC(2026, 10, 12, 19), provenance: iex } as Quote);

  // A time zone offset is honoured; with no quote or daily bar there is just the trade.
  assertEquals(result.quotes["us:SPY"], { instrumentID: "us:SPY", last: 590, time: Date.UTC(2026, 10, 13, 0, 30), provenance: iex } as Quote);
});

Deno.test("crypto quotes: read from under `snapshots`, keyed BTC/USD", async () => {
  const { provider, calls } = harness(() =>
    json({
      snapshots: {
        "BTC/USD": {
          latestTrade: { t: "2026-11-12T19:43:02.288500345Z", p: 70_854.4, s: 0.00011, tks: "B" },
          latestQuote: { t: "2026-11-12T19:59:29.320581427Z", bp: 70_762.368, ap: 70_780.86 },
          dailyBar: { t: "2026-11-12T00:00:00Z", v: 0.132473031 },
        },
      },
    })
  );

  const result = await provider.quotes([BTC, ETH], NOW);

  assertEquals(calls[0].url.pathname, "/v1beta3/crypto/us/snapshots");
  assertEquals(calls[0].url.searchParams.get("symbols"), "BTC/USD,ETH/USD");
  assertStringIncludes(calls[0].raw, "symbols=BTC%2FUSD%2CETH%2FUSD");
  assertEquals(calls[0].url.searchParams.get("feed"), null);
  assertEquals(result.quotes, {
    "crypto:BTC": {
      instrumentID: "crypto:BTC",
      last: 70_854.4,
      bid: 70_762.368,
      ask: 70_780.86,
      time: Date.UTC(2026, 10, 12, 19, 43, 2, 288),
      provenance: { kind: "market", source: "Alpaca (crypto)", delaySeconds: 0 },
      dayVolume: 0.132473031,
    },
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

Deno.test("ASX is unsupported: recorded as a failure with no request made", async () => {
  const { provider, calls } = harness(() => json({}));

  assertEquals(provider.supports(BHP), false);
  assertEquals(provider.supports(AAPL), true);
  assertEquals(provider.supports(SPY), true);
  assertEquals(provider.supports(BTC), true);

  const bars = await provider.bars([BHP], "day", 20, NOW);
  const quotes = await provider.quotes([BHP], NOW);
  assertEquals(bars, { series: {}, failures: { "asx:BHP": "ASX isn't supported by this data source" } });
  assertEquals(quotes, { quotes: {}, failures: { "asx:BHP": "ASX isn't supported by this data source" } });
  assertEquals(calls.length, 0);
});

Deno.test("ASX alongside a US stock: only the US stock is asked for", async () => {
  const { provider, calls } = harness(() => json({ AAPL: { latestTrade: { t: "2026-11-12T19:59:58Z", p: 228.5 } } }));

  const result = await provider.quotes([BHP, AAPL], NOW);

  assertEquals(calls.length, 1);
  assertEquals(calls[0].url.searchParams.get("symbols"), "AAPL");
  assertEquals(Object.keys(result.quotes), ["us:AAPL"]);
  assertEquals(result.failures, { "asx:BHP": "ASX isn't supported by this data source" });
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
  const result = await provider.bars([AAPL], "day", 5, NOW);
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

    assertEquals(calls.length, 3); // stock bars, crypto bars, stock snapshots: once each
    assertEquals(sleeps, []);
    assertEquals(bars.failures, { "us:AAPL": "Alpaca rejected the data credentials", "crypto:BTC": "Alpaca rejected the data credentials" });
    assertEquals(quotes.failures, { "us:AAPL": "Alpaca rejected the data credentials" });
    assertNoSecrets(bars);
    assertNoSecrets(quotes);
    assertNoSecrets(events);
  }
});

Deno.test("timeout: a request that hangs is aborted and reported as timed out", async () => {
  const { provider, calls, sleeps, events } = harness((call) =>
    new Promise<Response>((_resolve, reject) => {
      call.init.signal!.addEventListener("abort", () => reject(new DOMException("The operation was aborted.", "AbortError")));
    }), { timeoutMs: 5, maxAttempts: 2 });

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

  await provider.bars([AAPL, MSFT], "day", 5, NOW);

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
  const { provider } = harness(() => json({}));
  assertNoSecrets(JSON.stringify(provider));
  assertNoSecrets(Deno.inspect(provider, { depth: 10, showHidden: true }));
  assertNoSecrets(Object.values(provider).map(String).join(" "));
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
// snapshot()

function stubProvider(bars: MarketDataProvider["bars"], quotes: MarketDataProvider["quotes"]): MarketDataProvider {
  return { name: "stub", supports: () => true, bars, quotes };
}

Deno.test("snapshot: a bars failure is reported first; a quote failure only when the bars were fine", async () => {
  const provenance = marketProvenance("stub");
  const series = (instrument: Instrument): BarSeries => makeBarSeries(instrument, "day", [bar(nyMidnight(12), 100)], provenance, NOW);
  const quote = (instrument: Instrument): Quote => ({ instrumentID: `us:${instrument.symbol}`, last: 100, time: NOW - 1_000, provenance });
  const NVDA = usStock("NVDA");
  const requests: unknown[][] = [];

  const result = await snapshot(
    stubProvider(
      (instruments, timeframe, count, now) => {
        requests.push(["bars", instruments.map((instrument) => instrument.symbol), timeframe, count, now]);
        return Promise.resolve({
          series: { "us:AAPL": series(AAPL), "us:MSFT": series(MSFT) },
          failures: { "us:TSLA": "Alpaca returned HTTP 500", "us:NVDA": "Alpaca has no price history for NVDA" },
        });
      },
      (instruments, now) => {
        requests.push(["quotes", instruments.map((instrument) => instrument.symbol), now]);
        return Promise.resolve({
          quotes: { "us:AAPL": quote(AAPL), "us:NVDA": quote(NVDA) },
          failures: { "us:MSFT": "Alpaca has no live quote for MSFT", "us:TSLA": "The request timed out" },
        });
      },
    ),
    [AAPL, MSFT, TSLA, NVDA, AAPL],
    "day",
    30,
    NOW,
  );

  assertEquals(requests, [
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
  assertEquals(broken, { series: {}, quotes: {}, failures: { "us:AAPL": "Price history unavailable: The market data request failed" } });

  const quoteOnly = await snapshot(
    stubProvider(
      () => Promise.resolve({ series: { "us:AAPL": makeBarSeries(AAPL, "day", [bar(nyMidnight(12), 100)], marketProvenance("stub"), NOW) }, failures: {} }),
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
  });
});

Deno.test("snapshot through Alpaca: bars and quotes together, with ASX and a quiet symbol recorded", async () => {
  const { provider } = harness((call) => {
    switch (call.url.pathname) {
      case "/v2/stocks/bars":
        return json({ bars: { AAPL: [wireBar(nyMidnight(11), 105), wireBar(nyMidnight(12), 106)], MSFT: [wireBar(nyMidnight(12), 412)] }, next_page_token: null });
      case "/v2/stocks/snapshots":
        return json({ AAPL: { latestTrade: { t: "2026-11-12T19:59:58Z", p: 228.5 } } });
      case "/v1beta3/crypto/us/bars":
        return json({ message: "internal" }, 500);
      default:
        return json({ snapshots: { "BTC/USD": { latestTrade: { t: "2026-11-12T19:59:00Z", p: 70_000 } } } });
    }
  }, { maxAttempts: 1 });

  const result = await snapshot(provider, [AAPL, MSFT, BTC, BHP], "day", 2, NOW);

  assertEquals(Object.keys(result.series).sort(), ["us:AAPL", "us:MSFT"]);
  assertEquals(Object.keys(result.quotes).sort(), ["crypto:BTC", "us:AAPL"]);
  assertEquals(result.failures, {
    "us:MSFT": "Live quote unavailable: Alpaca has no live quote for MSFT",
    "crypto:BTC": "Price history unavailable: Alpaca returned HTTP 500",
    "asx:BHP": "Price history unavailable: ASX isn't supported by this data source",
  });
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
  const bars = await provider.bars([AAPL, BHP], "day", 3, NOW);
  const quotes = await provider.quotes([AAPL, BHP], NOW);

  assertEquals(bars.failures, {});
  assertEquals(quotes.failures, {});
  const aapl = bars.series["us:AAPL"];
  assertEquals(aapl.provenance, { kind: "fixture", source: "fixture", delaySeconds: 0 });
  assertEquals(aapl.provenance.kind, "fixture");
  assertEquals(aapl.bars, fixtureBars.slice(1)); // the last three
  assertEquals(aapl.instrument, AAPL);
  assertEquals(aapl.timeframe, "day");
  assertEquals(aapl.fetchedAt, NOW);
  assertEquals(bars.series["asx:BHP"].provenance.kind, "fixture");

  assertEquals(quotes.quotes["us:AAPL"], {
    instrumentID: "us:AAPL",
    last: 103.5,
    bid: 103.4,
    ask: 103.6,
    time: NOW - 2_000,
    provenance: { kind: "fixture", source: "fixture", delaySeconds: 0 },
    dayVolume: 12_345,
  });
  assertEquals(quotes.quotes["asx:BHP"], { instrumentID: "asx:BHP", last: 45.1, time: NOW - 5_000, provenance: { kind: "fixture", source: "fixture", delaySeconds: 0 } });

  const named = new FixtureDataProvider({ source: "golden-cross-case", series: { "us:AAPL": { timeframe: "day", bars: fixtureBars } } });
  assertEquals((await named.bars([AAPL], "day", 10, NOW)).series["us:AAPL"].provenance, { kind: "fixture", source: "golden-cross-case", delaySeconds: 0 });
});

Deno.test("fixture: a missing instrument or the wrong bar size is a failure", async () => {
  const provider = new FixtureDataProvider({ series: { "us:AAPL": { timeframe: "day", bars: fixtureBars } }, quotes: {} });

  const hourly = await provider.bars([AAPL, MSFT], "hour", 3, NOW);
  assertEquals(hourly, { series: {}, failures: { "us:AAPL": "No fixture price history for AAPL", "us:MSFT": "No fixture price history for MSFT" } });
  assertEquals(await provider.quotes([AAPL], NOW), { quotes: {}, failures: { "us:AAPL": "No fixture quote for AAPL" } });
  assertEquals((await provider.bars([AAPL], "day", 0, NOW)).failures, { "us:AAPL": "The number of bars asked for isn't valid" });
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
  assertEquals(bars.series["us:AAPL"].provenance, { kind: "fixture", source: "fixture", delaySeconds: 0 });
  assertEquals(bars.failures, Object.fromEntries(symbols.slice(1).map((symbol) => [`us:${symbol}`, `No fixture price history for ${symbol}`])));

  const quotes = await provider.quotes(instruments, NOW);
  assertEquals(quotes.quotes, { "us:AAPL": { instrumentID: "us:AAPL", last: 103.5, time: NOW, provenance: { kind: "fixture", source: "fixture", delaySeconds: 0 } } });
  assertEquals(Object.keys(quotes.failures).length, 7);

  // Not an object at all: an empty provider, not a crash.
  for (const junk of [null, undefined, "fixture", 7, [], { series: [], quotes: "x" }, { series: { "us:AAPL": { timeframe: "day", bars: [{ time: Number.NaN, open: 1, high: 1, low: 1, close: 1, volume: 1 }] } } }]) {
    const empty = new FixtureDataProvider(junk as never);
    assertEquals(await empty.bars([AAPL], "day", 5, NOW), { series: {}, failures: { "us:AAPL": "No fixture price history for AAPL" } });
    assertEquals(await empty.quotes([AAPL], NOW), { quotes: {}, failures: { "us:AAPL": "No fixture quote for AAPL" } });
  }
});

// ---------------------------------------------------------------------------------------
// providerFromEnv

const envOf = (values: Record<string, string>) => (name: string) => Object.hasOwn(values, name) ? values[name] : undefined;
const KEYS = { ALPACA_DATA_KEY_ID: KEY_ID, ALPACA_DATA_SECRET: SECRET };
const FIXTURE = { series: { "us:AAPL": { timeframe: "day", bars: fixtureBars } } };

Deno.test("providerFromEnv: a fixture with the flag on gives the fixture provider — even when real keys are set", async () => {
  const choice = providerFromEnv(envOf({ TRADING_ALLOW_FIXTURE_DATA: "1", ...KEYS }), { fixture: FIXTURE });
  assertEquals(choice.allowFixtureData, true);
  assertEquals(choice.reason, undefined);
  assert(choice.provider instanceof FixtureDataProvider);
  assertEquals((await choice.provider.bars([AAPL], "day", 2, NOW)).series["us:AAPL"].provenance.kind, "fixture");
});

Deno.test("providerFromEnv: a fixture without the flag gives nothing — never real data instead", () => {
  for (const flag of [undefined, "", "0", "true", "yes", " 1"]) {
    const values: Record<string, string> = { ...KEYS };
    if (flag !== undefined) values.TRADING_ALLOW_FIXTURE_DATA = flag;
    assertEquals(providerFromEnv(envOf(values), { fixture: FIXTURE }), { provider: null, allowFixtureData: false, reason: "Fixture data isn't allowed here." });
  }
});

Deno.test("providerFromEnv: both Alpaca keys give the Alpaca provider, wired to the given fetch and log", async () => {
  const seen: Headers[] = [];
  const events: Record<string, unknown>[] = [];
  const fake = ((_input: string | URL | Request, init?: RequestInit) => {
    seen.push(new Headers(init?.headers));
    return Promise.resolve(json({ AAPL: { latestTrade: { t: "2026-11-12T19:59:58Z", p: 228.5 } } }));
  }) as typeof fetch;

  const choice = providerFromEnv(envOf(KEYS), { fetch: fake, log: (event) => events.push(event) });

  assertEquals(choice.allowFixtureData, false);
  assertEquals(choice.reason, undefined);
  assert(choice.provider instanceof AlpacaDataProvider);
  assertEquals(choice.provider.name, "alpaca");
  const quotes = await choice.provider.quotes([AAPL], NOW);
  assertEquals(quotes.quotes["us:AAPL"].last, 228.5);
  assertEquals(quotes.quotes["us:AAPL"].provenance.kind, "market");
  assertEquals(seen[0].get("APCA-API-KEY-ID"), KEY_ID);
  assertEquals(seen[0].get("APCA-API-SECRET-KEY"), SECRET);
  assertEquals(events.length, 1);
  assertNoSecrets(choice);
  assertNoSecrets(events);

  // The flag alone doesn't change which provider real requests get.
  const flagged = providerFromEnv(envOf({ TRADING_ALLOW_FIXTURE_DATA: "1", ...KEYS }));
  assert(flagged.provider instanceof AlpacaDataProvider);
  assertEquals(flagged.allowFixtureData, true);
});

Deno.test("providerFromEnv: without both keys, market data isn't configured", () => {
  const cases: Record<string, string>[] = [{}, { ALPACA_DATA_KEY_ID: KEY_ID }, { ALPACA_DATA_SECRET: SECRET }, { ALPACA_DATA_KEY_ID: "", ALPACA_DATA_SECRET: SECRET }, { ALPACA_DATA_KEY_ID: KEY_ID, ALPACA_DATA_SECRET: "  " }];
  for (const values of cases) {
    assertEquals(providerFromEnv(envOf(values)), { provider: null, allowFixtureData: false, reason: "Market data isn't configured." });
  }
  assertEquals(providerFromEnv(envOf({ TRADING_ALLOW_FIXTURE_DATA: "1" })), { provider: null, allowFixtureData: true, reason: "Market data isn't configured." });
});

// ---------------------------------------------------------------------------------------
// The guard: this layer reads market data and can do nothing else.

Deno.test("source guard: no trading host, no order or account path, no write method, no clock", async () => {
  const sources = ["provider.ts", "alpaca.ts", "fixture.ts", "index.ts"];
  for (const name of sources) {
    const text = await Deno.readTextFile(new URL(`../_shared/market/${name}`, import.meta.url));
    assert(text.length > 0);

    const withoutDataHost = text.replaceAll("data.alpaca.markets", "");
    assert(!withoutDataHost.includes("api.alpaca.markets"), `${name} names a non-data Alpaca host`);
    // The only other Alpaca host a source may name is the documentation, in a comment.
    const otherHosts = [...withoutDataHost.matchAll(/([a-z0-9-]+)\.alpaca\.markets/gi)].map((match) => match[1].toLowerCase());
    assertEquals(otherHosts.filter((host) => host !== "docs"), [], `${name} names another Alpaca host`);
    for (const forbidden of ["/v2/orders", "/v2/account", "/v2/positions", "/v2/assets", "/v2/watchlists", "paper-api"]) {
      assert(!text.includes(forbidden), `${name} mentions ${forbidden}`);
    }
    assert(!/["'`](POST|PUT|PATCH|DELETE)["'`]/.test(text), `${name} uses a write method`);
    assert(!text.includes("Date.now"), `${name} reads the clock`);
    assertNoSecrets(text);
  }

  // Every path literal in the Alpaca provider is one of the four read-only data paths.
  const alpaca = await Deno.readTextFile(new URL("../_shared/market/alpaca.ts", import.meta.url));
  const paths = [...alpaca.matchAll(/"(\/v[^"]*)"/g)].map((match) => match[1]).sort();
  assertEquals(paths, ["/v1beta3/crypto/us/bars", "/v1beta3/crypto/us/snapshots", "/v2/stocks/bars", "/v2/stocks/snapshots"]);
  assertEquals([...alpaca.matchAll(/method:\s*"([A-Z]+)"/g)].map((match) => match[1]), ["GET"]);
});
