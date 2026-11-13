# Stock Tracker — web app

Next.js (App Router, TypeScript) front end for the Stock Tracker platform: markets and charts,
watchlists, the Strategy Studio with real backtests, and the order review / connections screens
for provider order routing. It shares the trading engine with the iPhone app and the Supabase
edge functions instead of re-implementing it:

| Alias | Points at | What it is |
| --- | --- | --- |
| `@engine/*` | `../supabase/functions/_shared/trading/*` | TypeScript port of TradingCore (indicators, strategy spec + validator, calendars, catalog) |
| `@studio/*` | `../supabase/functions/_shared/studio/*` | Backtester + natural-language strategy parser (Swift parity ports) |
| `@oms/*` | `../supabase/functions/_shared/oms/*` | Contract for the `broker-orders` / `broker-connections` functions |
| `@brokers/*` | `../supabase/functions/_shared/brokers/*` | Provider adapter types (capabilities, order types) |

Don't copy engine code into `web/`. Turbopack's root is the repository (see `next.config.ts`).

## Run

```bash
cp .env.example .env.local   # all values optional
npm install
npm run dev                  # http://localhost:3000
npm run lint && npx tsc --noEmit && npm run build
```

Without any env vars the app runs with public market data (Yahoo, CoinGecko); sign-in,
watchlists, connections and orders show "not configured" states. With
`NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY` it uses the same Supabase project
(and the same `watchlist_assets` table) as the iPhone app. Order routing appears only when the
`broker-orders` / `broker-connections` functions are deployed — until then those pages say so.

## Routes

- `GET /api/markets/search?q=` · `GET /api/markets/instruments/:id` · `…/:id/quote` · `…/:id/candles?range=1D|5D|1M|3M|6M|1Y|5Y`
  — ids are canonical `venue:SYMBOL` (`asx:BHP`, `lse:VOD`, `crypto:BTC`). Every quote/candle response carries
  source, currency, observed time, real_time/delayed/indicative status, staleness and market open/closed.
- `POST /api/strategies/parse` · `POST /api/strategies/validate` · `POST /api/backtests` (stateless; echoes every
  input incl. `asOf`, dataset SHA-256s and engine version so a result can be reproduced exactly).
- `GET /api/status` — which integrations are configured (booleans only).

## Data honesty

Prices are never synthesised, interpolated or carried forward. A failed source falls back to the
next one; if all fail the UI says the price isn't available. Yahoo is unofficial: equities from it
are labelled delayed unless Yahoo states a zero delay; crypto from CoinGecko/Yahoo is labelled
indicative (an aggregate). Alpaca's free US feed is IEX — real time but one exchange, so its
volume is labelled single-venue.

## Not in this pass

Portfolio, AI Workspace, Agent Studio, Paper Trading and Activity are listed in the sidebar as
"Soon" (disabled). Strategy versions are saved in the browser only (no strategies table in the
committed schema yet). There is one watchlist (named lists need a schema change).
