# Implementation plan — agentic stock & crypto platform

Written 2026-11-13 against the owner's master brief ("transform Stock-Tracker into an agentic
stock and cryptocurrency investment platform"). It records what the repository actually is, what
the brief asks for, what is already built, what this branch adds, and what remains. It is updated
as work lands; status words mean exactly this:

- **Done** — implemented and covered by automated tests in this repository.
- **Built, needs credentials** — implemented and tested against mocks/fixtures; needs a provider key or deployment to run for real.
- **Simulation only** — works with simulated money by design.
- **Gated** — implemented but switched off server-side pending legal/provider/operational approval (see `REGULATORY_REVIEW.md`).
- **Not started** / **Deferred**.

## 1. What the repository is (audit)

The brief assumed a Next.js web app. The repository is not one:

| Part | What it is | Notes |
|---|---|---|
| `Stock Tracker/` | Native **SwiftUI iPhone app** (plus widget and notification extensions) | Portfolio tracker for US/ASX stocks and crypto: real charts (`PriceHistoryService`), watchlists, alerts, news, SnapTrade read-only broker import, onboarding, paywall. Money invariant: stored values are USD (`FXRates.swift`). See repo `CLAUDE.md`. |
| `TradingCore/` | Local **Swift package**, the trading domain (no UI, no network) | Strategy specs as data, evaluator (completed bars only), 24-check `RiskEngine`, `PaperBroker` (spread, fees, partial fills, DAY/GTC/IOC/FOK), average-cost `Ledger`, hash-chained `AuditLog`, `Backtester` (next-bar-open fills), 13 venues with calendars. 140+ tests. |
| `supabase/functions/_shared/trading/` | **TypeScript port** of TradingCore for the server | Proven against shared vectors generated from Swift (`TradingCore/Tests/Vectors`). Not yet ported: `Backtester`, `StrategyParser`. |
| `supabase/` | Postgres schema + Deno edge functions | `20261017000000` (watchlists, holdings, transactions, alerts, referrals, RLS). The practice-trading server (`trading-api`, `agent-scheduler`, migration `20261113120000`) is being built in parallel and was not yet committed when this plan was written. |
| `web/` | **New** — Next.js web app (this branch, at the owner's request) | Uses the same Supabase backend and imports the shared TypeScript engine rather than re-implementing it. |

Data providers in use: Alpaca market data (IEX feed on the free plan — not consolidated), Yahoo
v8 (ASX and international venues; unofficial), CoinGecko, FMP, Finnhub, Frankfurter FX,
SnapTrade (read-only aggregation). The hosted Supabase project is gone (NXDOMAIN); a local stack
(`supabase/config.toml`, port 58321) is the only backend today.

### Critical problems found before extending

1. **Keys in the app bundle and in public history.** `Secrets.plist` ships in the IPA; historical
   keys are in the public repo's history. Action for the owner: rotate them; move provider calls
   behind server functions (this branch's broker functions never put keys on a device).
2. **No hosted backend.** Accounts, sync and every server function need a new Supabase project
   (`supabase link` + `db push`). Paid infrastructure: owner's decision.
3. **Practice trading stores money as `double precision`.** The practice server keeps doubles
   because the engine works in doubles and rounds to the cent itself (documented in its
   migration). Provider orders on this branch use `numeric(38,18)` and decimal strings end to end.

## 2. Ownership while two efforts run in parallel

| Area | Owner | Branch |
|---|---|---|
| iPhone app trading screens, TradingCore, TS engine port, practice server (`trading-api`, `agent-scheduler`, `20261113120000`) | the existing trading-platform session | `feature/agentic-trading-platform` and its subagent branch |
| Provider order management (OMS), credential vault, broker adapters, gates, provider migration, web app, these docs | this effort | `feature/trading-platform` (+ `-brokers`, `-web`, `-studio` working branches) |

Rules: neither side edits the other's files; this branch adds new directories (`_shared/oms`,
`_shared/vault`, `_shared/brokers`, `_shared/studio`, `web/`) and a later-timestamped migration
that applies with or without the practice migration.

## 3. Feature inventory against the brief

| Brief section | Status | Where |
|---|---|---|
| §3 Unified dashboard (stocks + crypto, AUD default, FX explicit) | iPhone: **Done** (USD stored, display currency). Web: in progress | `MarketData`, `FXRates`; `web/` |
| §3 Portfolio analytics (TWR/MWR, benchmarks, cost basis) | Cost basis, realised/unrealised, benchmark on iPhone **Done**; TWR/MWR **Not started** | `PortfolioTabViews`, `PriceHistoryService` |
| §4 Provider-agnostic connections | Contract + capability registry **Done**; Alpaca + Coinbase adapters **Built, needs credentials** (66 mocked-HTTP tests; never run against a real account); `broker-connections` function (connect/sync/revoke) **Built, needs credentials** | `_shared/brokers/`, `broker-connections/`, `docs/trading/provider-adapters.md` |
| §4 Encrypted credentials | **Done** (AES-256-GCM envelope, key ring, binding, rotation; no client can read the table) | `_shared/vault/`, migration `20261113180000` |
| §4 Reliability (retry, backoff, idempotent ingest, reconcile) | Adapters: retries on reads only, unknown submits never retried; idempotent fill keys **Done**; WebSocket streams **Not started** | `_shared/brokers/http.ts`, `broker_fills` unique key |
| §5 Markets, search, charts, indicators | iPhone **Done**. Web: in progress (lightweight-charts; indicators from the shared engine) | `web/` |
| §5 Watchlists | iPhone **Done**; web on the same table, in progress | `watchlist_assets` |
| §6 Agent workspace, multi-agent | iPhone agents + copilot (practice) **Done** in the other effort; web AI workspace **Not started** | `AgentsTabView`, `CopilotView` |
| §6 AI security (untrusted retrieved content, no model-placed orders) | Practice: LLMs never decide trades (`StrategyParser.decodeDraft`, validator). OMS: an agent can only *draft*; approval requires the owner's session; the adapter is reachable only through `execute.ts` | `TradingCore`, `_shared/oms/` |
| §7 Strategy builder (typed DSL, no generated code) | **Done** in TradingCore (`StrategySpec` JSON + validator); TS parser/backtester port in progress | `_shared/studio/` |
| §8 Paper trading | **Simulation only, Done** (iPhone; server in the other effort). Provider-hosted paper (Alpaca paper) via OMS: **Gated** (`provider_paper_execution`) | `PaperBroker`; `_shared/oms/` |
| §9 Backtesting | Swift **Done**; TS port in progress | `Backtester.swift`, `_shared/studio/backtester.ts` |
| §10 Controlled live execution | OMS lifecycle, immutable intent hash, approvals, step-up, idempotency, reconciliation **Done**; live: **Gated** (DB CHECK constraints + gate + adapter refusal) | `_shared/oms/`, migration |
| §11 Risk engine + kill switch | Practice: 24-check engine + kill switch **Done**. Provider orders: the same engine on a provider-built ledger plus restricted symbols, crypto cap, cash reserve, price-deviation guard; reserving orders counted; re-run under a per-user lock at submit; kill switch blocks manual provider orders too **Done** | `_shared/trading/risk.ts`, `_shared/oms/risk.ts`, `execute.ts` |
| §12 Data model | Practice tables (other effort); provider tables **Done** (see §5 below) | migrations |
| §13 API | `broker-connections` / `broker-orders` **Built, needs a hosted project** (type-checked; PgOmsStore proven on a throwaway Postgres; HTTP layer not yet run end to end) | `_shared/oms/api.ts`, `broker-orders/`, `broker-connections/` |
| §14 Premium UI | iPhone redesign **Done**; web in progress | |
| §15 Security / threat model | `THREAT_MODEL.md` | |
| §16 Australian regulation | `REGULATORY_REVIEW.md` (decisions) + `docs/trading/regulatory-au.md` (research, other effort) | |
| §17 Observability | Structured logs in functions; OMS events append-only; metrics/alerting **Not started** | |
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
| 2 Providers + data | Alpaca/Coinbase adapters; `broker-connections`; web markets/charts/watchlists | Adapter tests with mocked HTTP; web routes return labelled real data | In progress |
| 3 Agents (web) | AI workspace with read-only tools, source-backed answers, prompt-injection tests | Eval suite in repo; agents can't reach order submission | Not started |
| 4 Strategies + simulation | TS parser/backtester port; web Strategy Studio + backtests | Port tests mirror Swift cases; identical inputs → identical results | In progress |
| 5 Trading + risk | `broker-orders` function; risk mapping for provider accounts; reconciliation scheduler | End-to-end against mocked Alpaca paper: draft → risk → approve → submit → fill; all failure journeys of brief §18 | In progress |
| 6 Release readiness | Hosted backend, monitoring, deployment docs, accessibility pass | Owner sign-off; `REGULATORY_REVIEW.md` items answered before any live gate | Blocked on owner/legal |

## 7. Known gaps and follow-ups (found while integrating, 2026-11-13)

- **Engine port lag.** Commit `b0d2f19` changed the Swift core (exchange calendars, lots, transaction
  taxes); 6 parity tests in `parity.test.ts` / `engine.test.ts` fail on that commit by itself until
  the TypeScript port follows. Owned by the practice-trading effort.
- **Studio backtester vs Swift taxes.** `Backtester.swift` now adds UK/FR/HK/KR/IN transaction taxes
  via `PaperBroker.tax`; the TS port (`_shared/studio/backtester.ts`) predates that and has no tax
  until the TS `PaperBroker` gains `tax`/`taxBps`. US and crypto backtests are unaffected.
- **Two decimal helpers** (`_shared/brokers/decimal.ts`, `_shared/oms/decimal.ts`) and **two HTTP/auth
  helpers** (`_shared/server`, `_shared/oms/http.ts`) were written in parallel; fold each pair into one.
- **"Today" on the provider path** is the trailing 24 hours (conservative), not the exchange day.
- **Coinbase reconciliation** can only search the 500 most recent orders by client order id (the API
  has no lookup by client id).
- **No scheduler yet** for provider reconciliation or fill sync; both run on request.

## 8. Externally blocked

- Hosted Supabase project (owner; paid infra decision).
- Provider keys: Alpaca paper key for end-to-end runs; Coinbase CDP key for read tests.
- Live trading: everything in `REGULATORY_REVIEW.md` §3 and the go-live gate in
  `docs/trading/regulatory-au.md` §8.
- Market-data licensing for redistribution in a public web app (Alpaca IEX vs SIP entitlement,
  Yahoo's unofficial endpoints) — see `REGULATORY_REVIEW.md`.
