# Provider adapters: Alpaca and Coinbase

Code: `supabase/functions/_shared/brokers/`. Tests: `supabase/functions/tests/brokers_*.test.ts`. Run them with
`npx -y deno test --allow-read supabase/functions/tests/brokers_*.test.ts`. There are 66 tests, all against scripted
responses, so the suite makes no network calls.

This is engineering research, checked against the providers' official docs in November 2026. It isn't legal advice.

## What the layer does, and what it refuses

| File | Role |
|---|---|
| `types.ts` | The contract (`BrokerAdapter`), shared with `../oms`. |
| `http.ts` | Timeouts, retries and error mapping. `read()` retries calls that are safe to repeat; `sendOnce()` makes one attempt and reports `unknown` when it can't tell whether an order was created. |
| `decimal.ts` | Exact decimal-string arithmetic using BigInt. Money never becomes a JS `number`. |
| `validation.ts` | Request-shape checks against capabilities, plus the live guard. |
| `alpaca.ts` | The Alpaca Trading API v2 adapter (US stocks/ETFs and crypto; paper and live). |
| `coinbase.ts`, `coinbase_auth.ts` | The Coinbase Advanced Trade API v3 adapter (spot crypto; live, plus the static sandbox) and its CDP ES256 JWT signing. |
| `registry.ts` | `adapterFor`, `capabilitiesFor`, and plain-language permission explanations (`PROVIDERS`). |

Invariants the tests hold:

- **Order creation, replace and edit are never retried.** A timeout, network error or 5xx after the request left returns `{ outcome: "unknown" }` after exactly one request. The caller must call `findOrderByClientID` before doing anything else. Reads, cancels (both providers treat a repeated cancel as harmless) and Coinbase previews are retried: up to 3 attempts, exponential backoff with full jitter, honouring `Retry-After` up to 30 s. A longer `Retry-After` comes back as `rate_limited` with `retryAfterMs`.
- **Every order carries our `clientOrderID`.** It must be 1–48 characters of `[A-Za-z0-9-]` and is sent as each provider's `client_order_id`.
- **Live calls need an explicit opt-in.** In the `live` environment, `submit`, `replace` and `cancel` throw `environment_refused` before any request unless `AdapterContext.allowLive === true`. Only the order-management layer may set it, after the platform gate, approval and risk checks. Reads work in every environment.
- **Money values stay decimal strings, and nothing is invented.** Amounts stay exactly as the provider sent them. A value a provider doesn't give is left undefined, never estimated. Coinbase positions, for example, carry no cost or market value.
- **No secrets in errors.** Error messages come from the provider's response body only. The adapter's credentials are scrubbed out of them and long messages are truncated.
- **No transfer calls.** There is no transfer or withdrawal call. Coinbase keys that carry transfer permission are refused at `validate`.
- **No short selling or margin.** Every capability has `shortSelling: false, margin: false`. Alpaca balances report non-marginable buying power as "available".

## Alpaca (Trading API v2)

**Hosts and keys.** Paper uses `https://paper-api.alpaca.markets` and live uses `https://api.alpaca.markets`. Paper and live accounts have **separate keys**. Requests send the headers `APCA-API-KEY-ID` and `APCA-API-SECRET-KEY`.

**Alpaca has no read-only keys.** Every key can trade its account, so `validate` reports `["read", "trade"]`. A read-only connection is therefore enforced on our side: the connection is never granted `trade`.

### Endpoints

| Use | Endpoint | Verified against |
|---|---|---|
| Account, balances, blockers | `GET /v2/account` | https://docs.alpaca.markets/reference/getaccount-1 (fields: `status`, `cash`, `buying_power`, `non_marginable_buying_power`, `equity`, `trading_blocked`, `account_blocked`, `trade_suspended_by_user`, …) |
| Positions | `GET /v2/positions` | https://docs.alpaca.markets/reference/getallopenpositions |
| Create order | `POST /v2/orders` | https://docs.alpaca.markets/reference/postorder |
| Order rules and statuses | n/a | https://docs.alpaca.markets/docs/orders-at-alpaca |
| Crypto orders | n/a | https://docs.alpaca.markets/docs/crypto-orders |
| List orders | `GET /v2/orders` (`status`, `limit` ≤ 500, `after`/`until` exclusive, `direction`, `nested`) | https://docs.alpaca.markets/reference/getallorders-1 |
| Reconcile by our id | `GET /v2/orders:by_client_order_id?client_order_id=` | https://docs.alpaca.markets/reference/getorderbyclientorderid |
| Get order | `GET /v2/orders/{id}` | covered by the same reference |
| Cancel | `DELETE /v2/orders/{id}` (204 accepted; 422 means it can no longer be cancelled) | https://docs.alpaca.markets/reference/deleteorderbyorderid-1 |
| Replace | `PATCH /v2/orders/{id}` (returns a **new** order id linked by `replaces`) | https://docs.alpaca.markets/reference/patchorderbyorderid-1 |
| Fills | `GET /v2/account/activities/FILL` (`page_size` ≤ 100; `page_token` = id of the last item) | https://docs.alpaca.markets/reference/getaccountactivitiesbyactivitytype-1 |
| Paper behaviour | n/a | https://docs.alpaca.markets/docs/paper-trading |

### Rules encoded in `capabilities()`

- **Stocks.** Market, limit, stop and stop-limit orders, with `day` or `gtc`.
  - IOC, FOK, OPG and CLS are documented, but Alpaca must enable them for the account (they're marked "contact sales"), so they aren't offered.
  - Fractional quantities are day orders only. Notional orders are market and day only.
  - Notional orders can't be replaced.
- **Crypto.** Market, limit and stop-limit orders, with `gtc` or `ioc`. Symbols look like `BTC/USD`.
  - Notional orders are allowed. This adapter offers them as market orders only, because the docs don't say whether limit orders accept them.
  - Replace isn't offered for crypto, because the docs don't confirm it.
- **Order responses.** A 403 on order creation means "Buying power or shares is not sufficient" and maps to `insufficient_funds`. A 422 means invalid input. A message saying `client_order_id` isn't unique maps to `duplicate_client_order_id`. The OMS must then reconcile rather than resubmit.
- **Status mapping.** `new`, `accepted`, `accepted_for_bidding`, `done_for_day` and `stopped` map to `accepted` (the order is open). `pending_new`, `partially_filled`, `filled`, `canceled`, `expired`, `replaced`, `pending_cancel`, `pending_replace` and `rejected` map to the same name. `suspended`, `calculated`, `held` and any future status map to `unknown`, which forces reconciliation.
- **Account blockers.** These flags disable trading: `trading_blocked`, `account_blocked`, `trade_suspended_by_user`, and any status other than `ACTIVE` (`PAPER_ONLY` is accepted on paper). A `pattern_day_trader` flag, if present, is shown as a note but doesn't disable trading. Alpaca enforces day-trade limits itself.
- **Paper account.** Alpaca simulates fills against the NBBO. About 10% of eligible orders get a random partial fill, and order size isn't checked against displayed liquidity. No regulatory fees and no dividends are simulated. The default balance is $100k.

### Market data entitlements

These are relevant to how prices are shown next to an Alpaca ticket. Source: https://docs.alpaca.markets/docs/about-market-data-api

| | Basic (free) | Algo Trader Plus ($99/month) |
|---|---|---|
| Real-time stock data | IEX only, a small share of US volume | All US exchanges (SIP/CTA+UTP) |
| Websocket symbols | 30 | Unlimited |
| Historical calls | 200 per minute | 10,000 per minute |
| Historical restriction | The latest 15 minutes are unavailable | None |

The app currently uses the IEX feed for quotes, so a free-plan price must be labelled as IEX, not as the consolidated price.

## Coinbase (Advanced Trade API v3)

- **Base URL.** `https://api.coinbase.com/api/v3/brokerage`.
- **Auth.** A CDP API key JWT, created fresh for every request (`coinbase_auth.ts`), signed **ES256**. Ed25519 keys are not supported by Coinbase.
  - Header: `{alg, kid: key name, nonce, typ: "JWT"}`.
  - Claims: `{sub: key name, iss: "cdp", nbf, exp: nbf+120, uri: "METHOD api.coinbase.com/api/v3/brokerage/…"}`.
  - The downloaded key is a SEC1 PEM (`BEGIN EC PRIVATE KEY`). WebCrypto only imports PKCS#8, so the adapter re-wraps it. The test proves the re-wrap is byte-identical to WebCrypto's own PKCS#8 export.
  - Source: https://docs.cdp.coinbase.com/coinbase-app/authentication-authorization/api-key-authentication
- **Sandbox.** `https://api-sandbox.coinbase.com/api/v3/brokerage`. Its responses are "static and pre-defined", only Accounts and Orders endpoints exist, and **no authentication** is needed, so keys are never sent to it. Nothing executes. Source: https://docs.cdp.coinbase.com/coinbase-app/advanced-trade-apis/sandbox
- **No paper venue.** `capabilities("paper").executionAvailable` is `false`.
- **Portfolio-scoped keys.** Each portfolio needs its own CDP key, and a key sees only its own portfolio. `retail_portfolio_id` is deprecated on create, list and accounts for CDP keys, so it isn't sent. Source: https://docs.cdp.coinbase.com/coinbase-app/advanced-trade-apis/guides/portfolios

### Endpoints

All paths below are relative to `/api/v3/brokerage`.

| Use | Endpoint | Verified against |
|---|---|---|
| Key scopes | `GET /key_permissions` (`can_view`, `can_trade`, `can_transfer`, `portfolio_uuid`, `portfolio_type`) | https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/data-api/get-api-key-permissions |
| Portfolios | `GET /portfolios` (`name`, `uuid`, `type`, `deleted`) | https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/portfolios/list-portfolios |
| Accounts and balances | `GET /accounts` (`limit` ≤ 250, `cursor`, `has_next`; `available_balance` and `hold` are `{value, currency}`) | https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/accounts/list-accounts |
| Create order | `POST /orders` | https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/orders/create-order |
| Preview | `POST /orders/preview` | https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/orders/preview-orders |
| Cancel | `POST /orders/batch_cancel` | https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/orders/cancel-order |
| Edit | `POST /orders/edit` (`order_id`, `price`, `size`, `stop_price?`) | https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/orders/edit-order |
| List orders | `GET /orders/historical/batch` | https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/orders/list-orders |
| Get order | `GET /orders/historical/{order_id}` returns `{order}` | https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/orders/get-order |
| Fills | `GET /orders/historical/fills` | https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/orders/list-fills |

### Rules encoded in the adapter

- **Order configurations.**

  | Order | Time in force | Configuration |
  |---|---|---|
  | Market | IOC | `market_market_ioc` |
  | Market | FOK | `market_market_fok` |
  | Limit | GTC | `limit_limit_gtc` (`post_only: false`) |
  | Limit | IOC | `sor_limit_ioc` |
  | Limit | FOK | `limit_limit_fok` |
  | Stop-limit | GTC | `stop_limit_stop_limit_gtc` |

  - Sizes are `base_size` for a quantity or `quote_size` for a cash amount. Stop-limit takes `base_size` only.
  - A buy stop is sent as `STOP_DIRECTION_STOP_UP` and a sell stop as `STOP_DIRECTION_STOP_DOWN`.
  - Day orders and plain stop orders aren't offered.
- **Create responses always arrive as HTTP 200.**
  - `{success: true, success_response: {order_id}}` becomes `accepted` with status `pending_new`, to be reconciled.
  - `{success: false, error_response: {message, new_order_failure_reason}}` becomes `rejected`. `INSUFFICIENT_FUND(S)` maps to `insufficient_funds`, `PRODUCT_TRADING_HALTED` to `market_closed`, and geofencing or disabled trading to `forbidden`.
  - A duplicate `client_order_id` doesn't create a second order; Coinbase returns the existing one.
- **Reconciliation.** `orders/historical/batch` has **no `client_order_id` filter**. `findOrderByClientID` therefore pages through the 500 most recent orders (5 pages of 100) and matches locally.
- **Order statuses.**

  | Coinbase | Ours |
  |---|---|
  | `PENDING`, `QUEUED` | `pending_new` |
  | `OPEN` | `accepted`, or `partially_filled` when `filled_size > 0` |
  | `FILLED` | `filled` |
  | `CANCELLED` | `canceled` |
  | `EXPIRED` | `expired` |
  | `FAILED` | `rejected` |
  | `CANCEL_QUEUED` | `pending_cancel` |
  | `EDIT_QUEUED` | `pending_replace` |
  | `UNKNOWN_ORDER_STATUS` and anything new | `unknown` |

- **Fills.** `entry_id` is the fill id; `trade_id` isn't unique for adjusted fills. `commission` is the fee, in the product's quote currency.
- **Accounts and balances.** Coinbase "accounts" are per-currency wallets. `accounts()` returns one `BrokerAccount` per portfolio: the key's own portfolio if it is scoped, otherwise every portfolio that isn't deleted. `balances()` gives one row per wallet, with total = available + hold, computed exactly. `positions()` returns crypto wallets with a non-zero balance.
- **Validation.** A key with `can_transfer` is **refused**, and so is a key without `can_view`. A key without `can_trade` connects read-only, and its account carries the blocker "view-only". INTX portfolios are marked unsupported.

## Not verified (read before relying on it)

1. **Alpaca order not found.** The docs only define 200 for `GET /v2/orders:by_client_order_id`. We treat a 404 as "no such order".
2. **Alpaca crypto features.** The docs don't confirm replace for crypto orders or limit orders sized as notional, so neither is offered.
3. **Alpaca fees.** FILL activities carry no fee. Fees (crypto included) appear as separate account activities, which this adapter doesn't read yet.
4. **Alpaca date filters.** The activities `after` and `date` filters use `created_at`, which the schema says is null for trading activities. `since` is therefore also applied locally on `transaction_time`.
5. **Alpaca order pagination.** It walks back in time with an exclusive `until` timestamp. Two orders submitted in the same instant at a page edge could be skipped.
6. **Alpaca `pattern_day_trader`.** The field isn't in the current `GET /v2/account` schema. It's read only if present.
7. **Alpaca request bodies.** Decimal strings are sent for `qty`, `notional` and prices, as in Alpaca's own examples. This hasn't been checked against a live account.
8. **Coinbase quote-sized fills.** The docs don't say whether a fill's `size` is in base or quote units when `size_in_quote` is true. The adapter assumes a quote amount and converts to base units (`size ÷ price`, truncated at 18 places). This needs checking against a real fill before tax or ledger use.
9. **Coinbase edits.** The docs only imply that edits are for limit orders (`ONLY_LIMIT_ORDER_EDITS_SUPPORTED`).
10. **Coinbase JWT `uri` claim.** It excludes the query string, as Coinbase's SDKs do. The auth page doesn't say so explicitly.
11. **Coinbase page sizes.** The maximum `limit` for orders and fills isn't documented. The adapter caps it at 1000.
12. **Rate limits.** The rate-limit pages for both providers weren't reachable (404). The HTTP layer handles 429 and `Retry-After` generically.
13. **Streaming.** Neither adapter streams. Both providers offer websocket order updates, but reconciliation here works by polling.
14. **Live calls.** No call in this layer has been made against a real account, paper or live, because no credentials were available. Everything is proven against documented response shapes only.
