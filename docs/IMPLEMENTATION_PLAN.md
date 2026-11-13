# Agentic Trading Platform — Implementation Plan and Status

_Last updated 2026-11-13. Status words in this file are exact: **Done** means implemented and covered by automated tests on this branch; **In flight** means work in progress elsewhere, not yet on this branch; **Gap** means not started._

## 1. What this repository is

Stock Tracker is a **native iOS app** (SwiftUI, iOS 26.1+, widget and notification extensions), not a web app. Everything below extends that stack rather than replacing it:

| Layer | Where | Notes |
|---|---|---|
| iOS app | `Stock Tracker/` | `MarketData` (central observable), `APIService` (Alpaca data, CoinGecko, Alpha Vantage, Finnhub, FMP, Yahoo), SnapTrade brokerage aggregation, AI chat, insights and copilot, watchlists, alerts, widgets, Live Activities, StoreKit tiers |
| Trading domain | `TradingCore/` (Swift package) | Deterministic and dependency-free: strategy spec, validator, parser and evaluator, indicators, backtester, 24-check risk engine, paper broker, ledger, order state machine, market calendars (US, ASX, international), agent pipeline, audit hash chain. `swift test` |
| Backend | `supabase/` | Postgres + RLS + Edge Functions (Deno). A **new, dedicated project** was created on 2026-11-13: org "Stock Tracker", project ref `opruuwczvrwklmwdtsaw`, region `ap-southeast-2`. No migrations or functions are applied to it yet (see §7) |
| UI tests | `Stock TrackerUITests/` | XCUITest suites (onboarding, lists, portfolio, broker flow, dark mode, large text, motion, performance) |

The original Supabase project no longer resolves (see the header of `supabase/migrations/20261017000000_stocktracker_schema.sql`), so the new project replaces it.

## 2. Architecture

```
 iOS app (SwiftUI)                         Supabase project (Sydney)
 ───────────────────────                   ─────────────────────────────────────────────
 Views ─▶ MarketData / TradingStore        Auth (email, Apple, TOTP MFA for step-up)
   │        │                              Postgres + RLS
   │        ├─ TradingCore (on device):    ├─ sync tables (watchlist, holdings, alerts…)
   │        │   paper trading, backtests,  ├─ secure_credentials  (sealed, service-role only)
   │        │   agents, risk, audit        ├─ ai_usage_daily + consume_ai_quota()
   │        │                              └─ trading tables (in flight, §4)
   │        └─ SecureBackend ──HTTPS+JWT──▶ Edge Functions
   │                                        ├─ snaptrade-proxy  ─▶ SnapTrade  (signed here)
   │                                        ├─ ai-proxy         ─▶ Gemini / OpenAI
   │                                        └─ trading-api, agent-scheduler (in flight)
   └─ APIService ─▶ market-data providers (keys still on device — §5 item 4)
```

**Invariants (enforced in code, not by convention):**

1. No language model can reach an order path. Agents and the copilot produce drafts and proposals; the deterministic risk engine and an explicit approval stand between any proposal and an order (`TradingEngine+Agents.swift`).
2. Live execution is impossible in this build. `LiveVenues.*.isExecutionEnabled = false` in TradingCore. The in-flight server work adds a database constraint (`live_trading_not_available_in_this_build`) and a live adapter registry that is empty and frozen. Turning live trading on is a reviewed change to all three layers plus the regulatory gate in `docs/REGULATORY_REVIEW.md`.
3. Provider secrets live on the server. After this branch, release builds contain no SnapTrade consumer key, SnapTrade user secret, OpenAI key or Gemini key (§5).
4. Strategies are data, not code. JSON is checked by `StrategyValidator`, and no generated code ever runs.
5. Money never mixes currencies without an explicit FX conversion, and each practice portfolio holds a single currency.

## 3. Spec module map

| # | Module (spec §2) | Status | Where |
|---|---|---|---|
| 1 | Identity & permissions | **Done** (auth, TOTP MFA), step-up for trading **in flight** | `SupabaseAuthManager.swift`, `MFAManager.swift` |
| 2 | Connections | **Done**: SnapTrade read-only aggregation, now server-signed (this branch). **Gap**: direct Alpaca/Coinbase account adapters | `SnapTrade*.swift`, `supabase/functions/snaptrade-proxy` |
| 3 | Market data | **Done** (multi-provider, delayed or real-time labels, international venues). **Gap**: server-side market-data proxy | `APIService.swift`, `PriceHistoryService.swift`, `TradingMarketData.swift` |
| 4 | Portfolio engine | **Done** for tracked and synced holdings, FX, performance chart. **Gap**: TWR/MWR with cash flows, tax lots | `PortfolioService.swift`, `FXRates.swift` |
| 5 | Agent orchestrator | **Done** on device (deterministic pipeline, copilot with fixed tools). Server scheduler **in flight** | `TradingEngine+Agents.swift`, `CopilotEngine.swift` |
| 6 | Strategy engine | **Done** | `StrategySpec.swift`, `StrategyParser.swift`, `StrategyEvaluator.swift` |
| 7 | Backtesting | **Done** (no look-ahead, costs, benchmark) | `Backtester.swift`, `BacktesterTests.swift` |
| 8 | Paper trading | **Done** on device; server copy **in flight** | `PaperBroker`, `Ledger.swift`, `PracticePortfolioViews.swift` |
| 9 | Risk engine | **Done** (24 checks incl. kill switch, stale data, notional, exposure) | `Risk.swift`, `RiskEngineTests.swift` |
| 10 | Order management | **Done** for paper. Live is **deliberately disabled** | `Orders.swift`, `TradingEngine.swift` |
| 11 | Notifications | **Done** for price alerts. **Gap**: agent and order event push | `PriceAlert.swift`, notification extension |
| 12 | Audit & compliance | **Done**: audit hash chain on device. Server audit **in flight**. Compliance gates: **Gap** (§6) | `Audit.swift`, `docs/REGULATORY_REVIEW.md` |

### Work in flight in a parallel session (not on this branch)

As of 2026-11-13 13:16 AEDT, another Claude Code session had these local, uncommitted or unpushed changes in `~/Downloads/StockTracker`:

- `supabase/functions/_shared/trading/*`: a TypeScript port of TradingCore, checked against shared Swift vectors (commit `4779c15`, not pushed).
- `supabase/functions/trading-api`, `agent-scheduler`, `_shared/server/*` and `_shared/market/*`. The market code is an Alpaca **data-only** provider.
- `supabase/migrations/20261113120000_trading_platform.sql`, with tables `trading_accounts`, `orders`, `order_fills`, `risk_policies`, `trade_proposals`, `broker_connections`, `audit_events` and related ones.
- UI edits to `OrderTicketView`, `PracticePortfolioViews`, `TradingNavigation`, `TradingUI` and `ContentView`.

This branch avoids all of those files. Merge order: that work first, then this branch. They don't conflict; this branch's migration timestamp (`20261113150000`) sorts after theirs.

## 4. Feature inventory against the spec

| Spec area | Fully implemented & tested | Needs provider credentials | Simulation only | Restricted pending regulatory authorisation | Deferred |
|---|---|---|---|---|---|
| §3 Dashboard | Portfolio value, P&L, allocation, stock vs crypto split, movers, multi-currency display | Broker-synced balances (SnapTrade) | — | — | TWR/MWR with external cash flows, sector exposure |
| §4 Connections | SnapTrade read-only via server proxy | SnapTrade partner keys, set as function secrets | — | Trading connections (`SNAPTRADE_ALLOW_TRADE_CONNECTIONS` off) | Direct Alpaca and Coinbase account adapters, OAuth flows |
| §5 Markets & charts | Search, watchlists, line and candle charts, indicators, session-aware status | Alpaca, FMP, Finnhub, CoinGecko keys | — | — | Order book / level 2 |
| §6 AI workspace | Copilot over app data with fixed tools; AI chat via server proxy | Gemini or OpenAI key, set as function secrets | — | Personalised recommendations (§6 of the regulatory review) | Source-backed external research agent |
| §7 Strategy studio | NL to structured spec (rules-based parser), validator, versions | — | — | — | LLM-drafted specs beyond the parser |
| §8 Paper trading | Local simulator, fees and slippage, ledger, partial fills | — | **Yes**: all trading is paper | — | Provider-hosted paper accounts |
| §9 Backtesting | Deterministic, costs, benchmark, no look-ahead | Historical data keys | — | — | Survivorship-free universes |
| §10 Live orders | Order state machine, approval proposals | — | — | **Yes**: disabled at three layers | Live adapters (seam exists, empty) |
| §11 Risk | 24 deterministic checks, kill switch | — | — | — | Server-side concurrent reservation (in flight) |

## 5. Security remediation (P0, before extending affected components)

| # | Finding | Status |
|---|---|---|
| 1 | Secrets committed to git: a fiscal.ai key in `.mcp.json`, plus SnapTrade consumer key, user id and user secret in `Stock Tracker/Info.txt` | Removed from this branch's tree in an earlier commit. **They are still on `main` and in history: rotate all of them** (fiscal.ai dashboard, SnapTrade dashboard: regenerate the consumer key, delete the hard-coded test user). Rewriting history is optional once they're rotated |
| 2 | SnapTrade consumer key and per-user `userSecret` shipped in the app | **Done (this branch)**: `snaptrade-proxy` signs server-side, user secrets are sealed with envelope encryption, and release builds use only the proxy. Existing Keychain identities move to the server once (`importLegacyUser`, proven against SnapTrade first) and are then deleted from the device |
| 3 | OpenAI and Gemini keys shipped in the app | **Done (this branch)**: `ai-proxy` with a per-user daily ceiling. Direct calls exist only in Debug builds with no server configured |
| 4 | Alpaca key pair shipped in the app (market data). Alpaca keys also authorise trading on the account they belong to | **Gap**. Until a market-data proxy exists, use keys from a **dedicated, unfunded paper account used for nothing else**. The in-flight server `_shared/market/alpaca.ts` is the natural home for that proxy |
| 5 | `Config/Secrets.plist` is bundled into the app, so every value in it ships | **Action for you**: once the proxies are deployed, delete `SnapTradeConsumerKey`, `OpenAIAPIKey` and `GeminiAPIKey` from your local `Secrets.plist`. `Secrets.plist.example` documents this |
| 6 | Debug tools that read keys were compiled into release (link already DEBUG-only) | **Done (this branch)**: `DebugView` and `SnapTradeClient` compile in Debug builds only. Dead `SnapTradeAuthManager` removed |
| 7 | Receipt validation endpoint is a placeholder (`Constants.URLs.receiptValidation`), so the server can't verify subscription tiers | **Gap**. Until it's fixed, the server's AI ceiling is an abuse limit, not the entitlement |
| 8 | `main` fails to link the widget extension | Fixed on the feature branch; resolved when it merges |

## 6. Remaining phases and acceptance criteria

**Phase A: deploy what exists (needs your go-ahead; see §7).**
Accept when `supabase db push` has applied the baseline, the in-flight trading migration and this branch's custody migration to `opruuwczvrwklmwdtsaw`, the functions are deployed with secrets set, and a signed-in device can link a brokerage read-only and chat with AI with no provider key in the build.

**Phase B: market-data proxy.** Move Alpaca, FMP, Finnhub and fiscal.ai calls behind an Edge Function with caching and per-user rate limits. Accept when the release build contains no market-data secret and charts still label delayed or real-time data correctly.

**Phase C: direct account connections (read-only).** Alpaca and Coinbase Advanced Trade account, balance, position and fill sync using `secure_credentials` (purpose `broker_api_key`), with paginated, idempotent sync cursors and rate-limit-aware retries. Accept when mocked-HTTP adapter tests pass, keys are validated as read-only (no withdrawal or transfer scopes), and synced positions reconcile against provider totals.

**Phase D: compliance gates.** A server-side `feature_flags` / compliance table, admin-only writes, read by every trading and advice path. Default: live trading off, automated live off, personalised recommendations off, AU only. Accept when every gate has a test showing that a client cannot flip it.

**Phase E: portfolio analytics.** TWR and MWR with external cash flows, tax-lot-ready transaction history, and an accountant export (CSV with AUD values at trade date).

**Phase F: live execution (only after the regulatory review is signed off).** Implement the live adapter behind the existing seam, with idempotent `client_order_id`, reconcile-before-retry on timeout, step-up MFA on approval, and approvals bound to an immutable intent hash. Accept with the end-to-end suite in spec §18 against provider sandboxes only.

## 7. Deployment (the new Supabase project)

Nothing has been applied or deployed yet. `scripts/deploy-backend.sh` performs the steps below with guard rails: it refuses Miraa project refs, makes you type the target ref, shows a dry run before pushing, and reads the DB password and KEK from the Keychain so neither is printed. The manual equivalent, for reference:

```bash
supabase link --project-ref opruuwczvrwklmwdtsaw     # DB password: macOS Keychain item "supabase-stock-tracker-db"
supabase db push                                       # baseline + trading (when merged) + secret custody
supabase secrets set --project-ref opruuwczvrwklmwdtsaw \
  CREDENTIAL_KEKS="k1:$(openssl rand -base64 32)" CREDENTIAL_ACTIVE_KEK=k1 \
  SNAPTRADE_CLIENT_ID=… SNAPTRADE_CONSUMER_KEY=…  GEMINI_API_KEY=… OPENAI_API_KEY=…  AI_DAILY_LIMIT=50
supabase functions deploy snaptrade-proxy ai-proxy --project-ref opruuwczvrwklmwdtsaw
```

- **Save the KEK yourself** (for example in your password manager) before setting it: Supabase never shows a secret again, and losing every KEK makes every sealed credential unrecoverable. To rotate, add `k2:…`, set `CREDENTIAL_ACTIVE_KEK=k2`, rewrap rows (`rewrap()` in `_shared/secure/envelope.ts`), then drop `k1`.
- Then set `SupabaseURL` / `SupabaseAnonKey` in `Config/Secrets.plist`. The anon key is designed to be public.

## 8. Externally blocked

| Item | Blocked on |
|---|---|
| Rotating the leaked fiscal.ai and SnapTrade credentials | You, in those providers' dashboards |
| SnapTrade, Gemini and OpenAI function secrets | Your keys (never pasted into an agent session) |
| Live trading of any kind | Australian legal review (AFSL / digital-asset framework / AUSTRAC), provider approval, and the gates in Phase D |
| Real-time consolidated US equities data | A paid market-data entitlement (Alpaca's free feed is IEX-only) |
| Coinbase Advanced Trade | A CDP API key with view-only scope for read sync |
| Server-verified subscription tiers | An App Store Server API integration |

## 9. How to verify

CI (`.github/workflows/ci.yml`) runs everything below on every pull request and on pushes to `main` and `feature/**`:

| Job | What it proves | Local equivalent |
|---|---|---|
| `server` | Edge Functions lint, typecheck and unit tests (no network) | `npx -y deno test --no-check=remote --allow-read --allow-env supabase/functions/tests/` |
| `migrations` | Every migration applies to a fresh Supabase Postgres, and the custody rules hold: RLS denial, uniqueness, append-only log, cascade on account deletion, quota limit | `scripts/verify-migrations.sh` (throwaway container, removed on exit) |
| `trading-core` | The trading domain | `(cd TradingCore && swift test)` |
| `ios` | Release build and the UI test bundle compile from a **clean checkout** | `cp "Stock Tracker/SecretsConfig.swift.template" "Stock Tracker/SecretsConfig.swift"`, then `xcodebuild … build` |

A clean checkout now builds: `SecretsConfig.swift.template` is the real plist-reading implementation (a missing key reads as empty), not an outdated list of hard-coded strings.

## 10. Merge readiness

Merge order: the parallel session's server work → `feature/agentic-trading-platform` → this branch (`feature/agentic-trading-platform-backend`) → `main`. `main` is an ancestor of the feature branch, so that last step has no conflicts today.

| Gate | Status (2026-11-13) |
|---|---|
| Debug and Release iOS builds | Pass (local, Xcode 27.2) |
| UI test bundle compiles | Pass (`build-for-testing`) |
| Broker and onboarding UI tests | See the PR description for the run result |
| TradingCore tests | Pass: 142 tests |
| Edge Function tests, lint, typecheck | Pass: 27 tests |
| Migration behaviour checks | Written (`supabase/tests/secret_custody_checks.sql`). **Not yet run**: the Miraa guard hook in the authoring session blocks database clients. CI or `scripts/verify-migrations.sh` runs them |
| CI green on GitHub | **Unverified** until the first run. The `ios` job assumes a `macos-26` runner image |
| Build artefacts untracked (`build/`, 547 files) | Done |
| Backend deployed to `opruuwczvrwklmwdtsaw` | **Not yet**: run `scripts/deploy-backend.sh` (it refuses Miraa project refs and asks you to type the target ref) |
| Provider secrets set (SnapTrade, Gemini/OpenAI) | **You**: see the end of `deploy-backend.sh` |
| Leaked credentials rotated | **You**: §5 item 1 |

**Before the merged app ships:** deploy the backend and set the provider secrets. Release builds route SnapTrade and AI only through the server, so without a deployed backend both features show "not configured".
