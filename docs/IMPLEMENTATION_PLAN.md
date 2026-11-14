# Implementation plan — agentic stock & crypto platform

Written 2026-11-13 against the owner's master brief ("transform Stock-Tracker into an agentic
stock and cryptocurrency investment platform"). It records what the brief asks for, what is already built, and what remains. It is updated
as work lands; status words mean exactly this:

- **Done** — implemented and covered by automated tests in this repository.
- **Built, needs credentials** — implemented and tested against mocks/fixtures; needs a provider key or deployment to run for real.
- **Simulation only** — works with simulated money by design.
- **Gated** — implemented but switched off server-side pending legal/provider/operational approval (see `REGULATORY_REVIEW.md`).
- **Not started** / **Deferred**.

## 1. What the repository is (audit)

Stock Tracker ships a native iOS app and a Next.js web app.

| Part | What it is | Notes |
|---|---|---|
| `Stock Tracker/` | Native **SwiftUI iPhone app** (plus widget and notification extensions) | Portfolio tracker for US/ASX stocks and crypto: real charts (`PriceHistoryService`), watchlists, alerts, news, SnapTrade read-only broker import, onboarding, paywall. Money invariant: stored values are USD (`FXRates.swift`). See repo `CLAUDE.md`. |
| `TradingCore/` | Local **Swift package**, the trading domain (no UI, no network) | Strategy specs as data, evaluator (completed bars only), 24-check `RiskEngine`, `PaperBroker` (spread, fees, partial fills, DAY/GTC/IOC/FOK), average-cost `Ledger`, hash-chained `AuditLog`, `Backtester` (next-bar-open fills), 13 venues with calendars. 140+ tests. |
| `supabase/functions/_shared/trading/` | **TypeScript port** of TradingCore for the server | Proven against shared vectors generated from Swift (`TradingCore/Tests/Vectors`). Strategy parsing and backtesting are in `_shared/studio/`. |
| `supabase/` | Postgres schema + Deno edge functions | `20261017000000` (watchlists, holdings, transactions, alerts, referrals, RLS). The practice-trading server (`trading-api`, `agent-scheduler`, migration `20261113120000`) is included, along with the provider OMS and server-side credential custody. |
| `web/` | Next.js web app | Uses the same Supabase backend and imports the shared TypeScript engine rather than re-implementing it. |

See [Design system](DESIGN_SYSTEM.md) for the shared component and token references.

Data providers in use: Alpaca market data (IEX feed on the free plan — not consolidated), Yahoo
v8 (ASX and international venues; unofficial), CoinGecko, FMP, Finnhub, Frankfurter FX,
SnapTrade (read-only aggregation). The replacement Supabase project is `opruuwczvrwklmwdtsaw` (Sydney). The local stack uses port 58321.

### Critical problems found before extending

1. **Historical credentials.** Release bundles contain only public Supabase configuration. The old fiscal.ai and SnapTrade values remain in Git history and require rotation at their providers.
2. **Hosted configuration.** Accounts, sync and server functions use the dedicated Stock Tracker project. See §9 for the credential proxy configuration.
3. **Practice trading stores money as `double precision`.** The practice server keeps doubles
   because the engine works in doubles and rounds to the cent itself (documented in its
   migration). Provider orders on this branch use `numeric(38,18)` and decimal strings end to end.

## 2. Server-side credential custody

The iOS app uses `SecureBackend` to call `snaptrade-proxy` and `ai-proxy` with its Supabase session. SnapTrade requests are signed in the Edge Function. User secrets are sealed in `secure_credentials` and bound to the authenticated owner. The AI proxy sets a fixed model policy and enforces a daily quota per user. Provider order credentials use the OMS vault. The iOS market-data proxy checks signed-in sessions, validates provider routes and applies a per-user quota. It serves Alpaca, Finnhub, FMP, Alpha Vantage and optional fiscal.ai.

## 3. Feature inventory against the brief

| Brief section | Status | Where |
|---|---|---|
| §3 Unified dashboard (stocks + crypto, AUD default, FX explicit) | iPhone: **Done** (USD stored, display currency). Web: overview with markets and watchlist **Done**; web portfolio shows synced positions, per-currency market contributions with data coverage and timestamps, and recent saved USD valuations | `MarketData`, `FXRates`; `web/src/app` |
| §3 Portfolio analytics (TWR/MWR, benchmarks, cost basis) | iPhone shows cost basis, realised/unrealised gains and a benchmark. Both clients show time-weighted, money-weighted and Modified Dietz returns from reconciled USD valuations and dated transfers. Time-weighted returns use post-transfer values for each transfer date. Contiguous periods with matching boundary values form the latest continuous history. Both clients can review SnapTrade cash activity and include eligible transfers with a source reference, including historical ECB conversion for supported foreign currencies. Scheduled SnapTrade imports cache the latest 90 days of activity for each linked account | `PortfolioTabViews`, `PortfolioPerformanceLedger`, `web/src/app/portfolio` |
| §4 Provider-agnostic connections | Contract + capability registry **Done**; Alpaca + Coinbase adapters **Built, needs credentials** (66 mocked-HTTP tests; never run against a real account); `broker-connections` function (connect/sync/revoke) **Built, needs credentials** | `_shared/brokers/`, `broker-connections/`, `docs/trading/provider-adapters.md` |
| §4 Encrypted credentials | **Done** (AES-256-GCM envelope, key ring, binding, rotation; no client can read the table) | `_shared/vault/`, migration `20261113180000` |
| §4 Reliability (retry, backoff, idempotent ingest, reconcile) | Adapters: retries on reads only, unknown submits never retried; idempotent fill keys **Done**; WebSocket streams **Not started** | `_shared/brokers/http.ts`, `broker_fills` unique key |
| §5 Markets, search, charts, indicators | iPhone **Done**. Web **Done** and verified with live data (US, ASX, LSE, TSE, crypto): candles/line/area, volume, SMA/EMA/Bollinger, RSI/MACD from the shared engine, provenance chips on every price | `web/src/app/markets`, `web/src/server/market` |
| §4 Explore | Web and iPhone show market indexes, sourced US and ASX movers, CoinGecko search trends, themed collections, and the account’s named lists and recent saves. Most watched appears only with sufficient distinct confirmed accounts. | `market-workspace/explore.ts`, `web/src/app/markets`, `MarketExploreView.swift` |
| §5 Watchlists | Create, rename and delete named lists on web and iPhone, with account sync and iPhone offline edits. Existing apps can still read and edit the default list. | `watchlist_assets`, `watchlist_groups`, `watchlist_group_assets`, `WatchlistSync.swift` |
| §6 Agent workspace, multi-agent | iPhone agents + copilot (practice) **Done** in the other effort. Web AI Workspace (`/ai` + side panel) **Built, needs an API key**: 8 read/prepare tools, sources with times, untrusted-data wrapping, never places orders; tools verified on live data, safety tests pass; no live model turn has run. Web Agent Studio lists agents, run evidence and pending proposals, and supports pause, resume, run and explicit practice approval | `web/src/server/agent`, `web/src/app/ai` |
| §6 AI security (untrusted retrieved content, no model-placed orders) | Practice: LLMs never decide trades (`StrategyParser.decodeDraft`, validator). OMS: an agent can only *draft*; approval requires the owner's session; the adapter is reachable only through `execute.ts` | `TradingCore`, `_shared/oms/` |
| §7 Strategy builder | Web Strategy Studio and iPhone agent drafts use plain-language parsing, editable buy and sell conditions, grouped rules, sizing, rebalancing targets and validation. The iPhone backtest report shows the tested rules. The web keeps unstarted draft versions in the browser. | `_shared/studio/`, `web/src/app/strategies`, `Stock Tracker/StrategyRuleEditor.swift` |
| §8 Paper trading | **Simulation only** on iPhone and web, with account-backed paper portfolios and order preview. Provider-hosted paper (Alpaca paper) via OMS: **Gated** (`provider_paper_execution`) | `PaperBroker`; `_shared/oms/` |
| §9 Backtesting | Swift **Done**; TS port + web backtests on real history **Done** (identical inputs gave an identical result fingerprint); results not stored server-side yet | `Backtester.swift`, `_shared/studio/backtester.ts`, `web/src/app/api/backtests` |
| §10 Controlled live execution | OMS lifecycle, immutable intent hash, approvals, step-up, idempotency, reconciliation **Done**; live: **Gated** (DB CHECK constraints + gate + adapter refusal) | `_shared/oms/`, migration |
| §11 Risk engine + kill switch | Practice: 24-check engine + kill switch **Done**. Provider orders: the same engine on a provider-built ledger plus restricted symbols, crypto cap, cash reserve, price-deviation guard; reserving orders counted; re-run under a per-user lock at submit; kill switch blocks manual provider orders too **Done** | `_shared/trading/risk.ts`, `_shared/oms/risk.ts`, `execute.ts` |
| §12 Data model | Practice tables (other effort); provider tables **Done** (see §5 below) | migrations |
| §13 API | `broker-connections` / `broker-orders` **Deployed** and authenticated list calls verified; provider account execution still requires provider credentials and approval | `_shared/oms/api.ts`, `broker-orders/`, `broker-connections/` |
| §14 Premium UI | iPhone redesign **Done**; web shell **Done** (12-section sidebar, ⌘K, dark/light, PRACTICE badge on every page; Portfolio, Agent Studio, Paper Trading and Activity are connected | `web/src/components` |
| §15 Security / threat model | `THREAT_MODEL.md` | |
| §16 Australian regulation | `REGULATORY_REVIEW.md` (decisions) + `docs/trading/regulatory-au.md` (research, other effort) | |
| §17 Observability | Structured function logs, append-only OMS events, recorded worker outcomes, scheduled alerts for overdue provider work, and 24-hour submission latency and outcomes. External paging remains open. | `DEPLOYMENT.md` §10, `provider_operations` |
| §18 Testing | Swift 140+, TS parity vectors; provider path: OMS 21, risk 9, vault 5, brokers 66, boundaries 1, Postgres integration 3, SQL behaviour checks; studio port 31; web e2e **Not started** | `supabase/functions/tests/`, `supabase/tests/` |

## 4. Architecture decisions

1. **Keep the native app; add the web app beside it.** The brief says reuse the existing stack;
   the owner additionally asked for the Next.js web app. Both talk to one Supabase backend.
2. **One trading engine, two languages, one specification.** Swift is the spec; the TypeScript
   port is checked against shared vectors. The web app imports the TS engine directly (path
   aliases), so charts, backtests and live evaluation use identical indicator maths.
3. **Two order paths that never mix.** `trading-api` = simulated fills in our own database.
   `broker-orders` = an order that goes to a provider (Alpaca paper now). Both reuse the same
   risk engine; only `broker-orders` can reach a provider, and only through `oms/execute.ts`.
4. **Defence in depth for real money.** Live is refused by (a) a CHECK constraint on
   `platform_gates`, `order_intents` and `broker_connections`, (b) the gate check in the
   pipeline, (c) the risk engine's authorization check (`accountPolicy.live` is forced off),
   (d) the adapter's own `allowLive` refusal. Turning live on is a migration plus a reviewed
   code change, never a flag flip.
5. **Approvals bind a hash.** The intent's material fields are canonicalised and hashed; the
   approval stores that hash; submission recomputes it from the stored row. A changed order can't
   ride on an old approval; the DB also refuses edits to hashed fields.
6. **Uncertainty stops execution.** Any submission whose outcome is unknown enters
   `reconciliation_required`; the only way out is a provider lookup by our client order id.
7. **Exact money on the provider path.** Decimal strings across the adapter boundary, BigInt
   arithmetic (`oms/decimal.ts`), `numeric(38,18)` in Postgres.

## 5. Database migration strategy

- Migrations are append-only, timestamped, idempotent (`if not exists`, guarded constraints).
- `20261113180000_provider_order_management.sql` applies alone (after the base schema) or after
  the practice migration, and re-applies cleanly; verified on a throwaway
  `supabase/postgres:17.6.1.165` container with `supabase/tests/provider_order_management.sql`.
- Hosted rollout (when a project exists): `supabase db push` on a branch database first, run the
  SQL checks, then production. Never `db reset` a shared stack.
- Later consolidation: fold `oms_events` into the practice `audit_events` hash chain once both
  are committed, with a migration that back-fills the chain.

## 6. Phases and acceptance criteria

| Phase | Deliverable | Acceptance | Status |
|---|---|---|---|
| 0 Audit | This plan, threat model, regulatory review | Docs in `docs/`, reviewed by owner | Done (this branch) |
| 1 Foundation | Adapter contract, OMS core, vault, gates, migration | Deno + SQL tests green; negative controls fail when a safeguard is removed | Done |
| 2 Providers + data | Alpaca/Coinbase adapters; `broker-connections`; web markets/charts/watchlists | Adapter tests with mocked HTTP; web routes return labelled real data | Done (needs credentials / hosted project to run for real) |
| 3 Agents (web) | AI workspace with read-only tools, source-backed answers, prompt-injection tests | Safety tests in repo; agents can't reach order submission; live-model eval suite still to write and run (billed) | Built; live run blocked on an API key |
| 4 Strategies + simulation | TS parser/backtester port; web Strategy Studio + backtests | Port tests mirror Swift cases; identical inputs → identical results | Web Strategy Studio starts review-required practice agents through the hosted trading API |
| 5 Trading + risk | `broker-orders` function; risk mapping for provider accounts; reconciliation scheduler | Mocked provider pipeline and scheduled reconciliation with Postgres; actual provider execution still needs an eligible test account | Provider maintenance reads orders and imports fills. Execution remains gated |
| 6 Release readiness | Hosted backend, monitoring, deployment docs, accessibility pass | Owner sign-off; `REGULATORY_REVIEW.md` items answered before any live gate | Blocked on owner/legal |

## 7. Known gaps and follow-ups (found while integrating, 2026-11-13)

- The web lot report applies user-entered stock splits and reverse splits from broker statements. Each adjustment is scoped to one holding and effective before trades dated that Sydney day. USD and AUD acquisition costs remain attached to their original lots. Fractional cash payments and other corporate actions still need separate records.
- Web Portfolio and the iPhone Income tab share the statement-confirmed cash ledger for dividends, distributions and payments in lieu. The ledger preserves the payment currency, optional gross amount, withholding and AUD franking credits. A reviewed SnapTrade event can supply an immutable reference and reported amount. Currency totals and the preliminary cash income export use the selected Sydney payment dates. Payments stay within the portfolio for performance reconciliation. The iPhone also displays estimated yield-based income.
- Web Portfolio and the iPhone Income tab share dividend reinvestments with the payment date, acquisition date, shares, and original amounts from the statement. Both income CSVs include the dividend and the amount applied to shares, with cash received left blank. Both clients can attach a reviewed SnapTrade reinvestment to a new or existing statement record. A saved reference is immutable and unique per owner. The CSVs retain reported metadata alongside the confirmed amounts. The FIFO report uses the acquisition date and handles same-day timestamped trades first. These entries adjust report lots. Position balances are maintained in the existing holdings workflow.

- The web lot report supports statement-confirmed transfers between two synced holdings of the same listed stock. It removes the shares from the sending holding on the sending date, carries original acquisition dates and fees, and posts the lots to the receiving holding on receipt. It tracks in-transit basis, supports replacing an exact matching receiving snapshot, and flags insufficient source history or a split during transit. Synced SnapTrade holdings carry a masked account label. A complete refresh updates account quantities together and retains prior snapshots and trade history for reconciliation. Older combined broker positions that match several accounts require review before import.

- The synced transaction CSV includes original amounts when recorded and labels the USD bookkeeping multiplier as an app reference or fallback rate. FIFO records keep position snapshots and purchases with missing costs in quantity order and leave their basis blank. The optional AUD export uses recorded currency amounts and the latest common ECB observation on or before each Sydney trade date within seven days. It includes the rate and observation date. Original AUD inputs require no FX lookup. Existing USD-only rows retain empty source amounts. Broker execution FX and missing historical amounts require additional source records.

- **Engine port lag — resolved.** The TS port caught up with core `b0d2f19` (calendars, lots,
  transaction taxes) in the practice effort's `e1039ec`; parity tests pass again, and the studio
  backtester now charges the same transaction taxes as `Backtester.swift`.
- **Two decimal helpers** (`_shared/brokers/decimal.ts`, `_shared/oms/decimal.ts`) and **two HTTP/auth
  helpers** (`_shared/server`, `_shared/oms/http.ts`) were written in parallel; fold each pair into one.
- **"Today" on the provider path** is the trailing 24 hours (conservative), not the exchange day.
- **Coinbase reconciliation** can only search the 500 most recent orders by client order id (the API
  has no lookup by client id).
- **Provider maintenance** checks pending orders and imports fills using leased, bounded jobs. Manual sync shares the fill checkpoint. Provider event streaming remains pending.
- **Web market-data adapters** (`web/src/server/market`) duplicate part of `_shared/market`; merge into one.
- **Assistant runs aren't persisted** (no AgentRun/AgentToolEvent tables for the web assistant); turns are logged only in the browser.
- **The ported strategy parser** maps "buy ETH when RSI drops below 30" to the crypto trend template rather than RSI rules (Swift behaviour, carried over; the screen lists the assumption).

## 8. Externally blocked

- Provider keys: Alpaca paper key for end-to-end runs; Coinbase CDP key for read tests.
- Live trading: everything in `REGULATORY_REVIEW.md` §3 and the go-live gate in
  `docs/trading/regulatory-au.md` §8.
- Market-data licensing for redistribution in a public web app (Alpaca IEX vs SIP entitlement,
  Yahoo's unofficial endpoints) — see `REGULATORY_REVIEW.md`.

## 9. Credential custody rollout and verification

| # | Finding | Status |
|---|---|---|
| 1 | Secrets committed to git: a fiscal.ai key in `.mcp.json`, plus SnapTrade consumer key, user id and user secret in `Stock Tracker/Info.txt` | Removed from the current tree. **They are still in Git history: rotate them** (fiscal.ai dashboard, SnapTrade dashboard: regenerate the consumer key, delete the hard-coded test user). Rewriting history is optional once they're rotated |
| 2 | SnapTrade consumer key and per-user `userSecret` shipped in the app | **Done**: `snaptrade-proxy` signs server-side, user secrets are sealed with envelope encryption, and release builds use only the proxy. Existing Keychain identities move to the server once (`importLegacyUser`, proven against SnapTrade first) and are then deleted from the device |
| 3 | OpenAI and Gemini keys shipped in the app | **Done**: `ai-proxy` with a per-user daily ceiling. Direct calls exist only in Debug builds with no server configured |
| 4 | Alpaca market data previously needed a key pair on the device | **Done**. Release requests use the authenticated market-data proxy. An unsigned session can use public fallback data where available |
| 5 | The source `Config/Secrets.plist` previously shipped with provider keys | **Done**. The release build writes a new resource containing the public Supabase URL and client key |
| 6 | Debug tools that read keys were compiled into release (link already DEBUG-only) | **Done**: `DebugView` and `SnapTradeClient` compile in Debug builds only. Dead `SnapTradeAuthManager` removed |
| 7 | Receipt validation endpoint is a placeholder (`Constants.URLs.receiptValidation`), so the server can't verify subscription tiers | **Gap**. Until it's fixed, the server's AI ceiling is an abuse limit, not the entitlement |

The hosted project applied the provider OMS as `20261113180000` and credential custody as `20261113190000`. Use `scripts/deploy-backend.sh` for SnapTrade and AI function configuration. Keep an offline copy of each credential encryption key. For rotation, add the next key to `CREDENTIAL_KEKS`, set `CREDENTIAL_ACTIVE_KEK`, and rewrap rows before removing the old key.

CI runs Edge Function lint, typechecking and tests, throwaway Postgres migration checks, TradingCore tests, and clean iOS builds. See [DEPLOYMENT.md](DEPLOYMENT.md) for the web app and the OMS setup.

## 10. Verification and production dependencies

- Hosted project `opruuwczvrwklmwdtsaw` contains the provider OMS, credential custody and market-data quota migrations. Its functions serve authenticated Alpaca data, the SnapTrade directory, provider account and order lists, and native AI chat.
- Provider keys are configured server-side. The tested Finnhub news and Alpha Vantage quote routes returned data. FMP reported its upstream rate limit. The previously exposed fiscal.ai credential requires rotation before configuration.
- Public distribution requires confirmed market-data display rights, an App Store release with working legal and support URLs, and the decisions in [Regulatory review](REGULATORY_REVIEW.md). Real-money execution, automated live execution and custody are disabled.
- Portfolio returns use reconciled opening and closing values, including cash, and dated external transfers. All inputs use USD. Time-weighted return links changes in value between end-of-day transfer dates. Money-weighted return solves the dated cash flows over the period and is shown when the calculation can establish a unique result. Modified Dietz remains available when transfer-day values are missing. The web Portfolio exports synced transaction records and preliminary USD FIFO lot records, including purchase IDs, sales, fees, open lots and unmatched quantities. The performance editor reviews paginated SnapTrade income, fees, transfers and corporate events in their reported currency. Users select the cash flows that cross their portfolio boundary. For supported foreign cash, the ECB reference rate, observation date and original amount are preserved with the USD value. The most recent common observation within seven calendar days is used. Reference rates can differ from the rate actually applied by a broker. Remaining engineering work includes scheduled activity imports for additional providers, corporate-action adjustments, original-currency acquisition records and tax reporting, and production monitoring. The web assistant can use Anthropic or OpenAI. Account data is shared with the model only after explicit opt-in.
