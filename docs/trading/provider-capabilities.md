# Trading provider capabilities (research)

Researched 2026-11-13. Official sources only: provider docs, official OpenAPI specs, provider support sites, official GitHub repos, and live *public* market-data endpoints. This feeds adapter capability tables and the live-trading gate; nothing here enables live trading. Tags like [A1] point to **Sources** at the end. `UNCONFIRMED` means not verified from an official source in this pass: do not encode it as a capability.

## 1. Alpaca

Four distinct products [A8][A9][A22]:

| Product | Account holder | Auth | Base URL |
|---|---|---|---|
| Trading API (live) | The individual/business itself | `APCA-API-KEY-ID` + `APCA-API-SECRET-KEY` headers (or HTTP Basic) | `https://api.alpaca.markets` |
| Paper trading | Same user, simulated | Separate paper key pair | `https://paper-api.alpaca.markets` |
| Connect (OAuth2) | An existing Alpaca customer authorises a third-party app | Bearer token | same hosts as above |
| Broker API | End users onboarded under *your* correspondent | HTTP Basic correspondent key, or 15-minute client-credentials token | `https://broker-api.alpaca.markets`, sandbox `https://broker-api.sandbox.alpaca.markets` |

**Eligibility / Australia**
- Paper-only account: "Anyone globally", email only; IEX market data only [A7].
- Live account: Alpaca "support[s] brokerage accounts for individuals and business entities from around the world" [A14], but the official countries page says only "contact support ... regarding whether your country is supported" [A18]. Its non-US guide says "195+ countries", "Alpaca does not support every jurisdiction" (Canada named as ineligible) [A19]. **Australian-resident live eligibility: UNCONFIRMED** (no published list; not named as excluded).
- Business account: USD 30,000 minimum, "for trading purposes, but not for building apps/services" [A14].
- Crypto: "eligible international participants" plus listed US states [A20]; "select international jurisdictions" [A5]. **Australia: UNCONFIRMED.** Alpaca Crypto LLC describes itself as a FinCEN-registered MSB [A13]; no AUSTRAC registration is stated on any page read.

**Instruments**
- "Currently, Alpaca only supports trading of listed U.S. stocks and select cryptocurrencies" [A14]. The assets `exchange` enum is AMEX, ARCA, BATS, NYSE, NASDAQ, NYSEARCA, OTC, CRYPTO, TXSE, ERSX, CRXL, ASCX, INDEX [A15]; the multi-market clock lists US, European, Hong Kong, Japanese and Saudi markets only [A16]. **ASX securities are not offered** (confirmed).
- Crypto spot: "20+ unique crypto assets across 56 trading pairs", quoted in USD, BTC, USDT, USDC; no AUD pairs. No margin, no shorting, max USD 200k notional per order, 24/7 [A5].

**Order types and time in force** (`type` enum: market, limit, stop, stop_limit, trailing_stop; `time_in_force` enum: day, gtc, opg, cls, ioc, fok; `order_class`: simple, bracket, oco, oto for equities, simple only for crypto) [A1][A4]

| Context | Order types | TIF |
|---|---|---|
| Whole-share US equity | market, limit, stop, stop_limit; trailing_stop (single orders only) | day, gtc for all. ioc, fok, opg, cls only for market/limit and flagged "contact the sales team" [A1] |
| Fractional `qty` or `notional` | market, limit, stop, stop_limit (see conflict below) | **day only** [A1][A2] |
| Extended hours (`extended_hours=true`: 4:00-9:30, 16:00-20:00, overnight 20:00-4:00 ET) | **limit only** | day, gtc [A1][A13] |
| Crypto | market, limit, stop_limit | gtc, ioc (stop_limit: gtc only) [A1][A5][A6] |

- `qty` and `notional` are mutually exclusive (both sent: HTTP 400) [A2]. Notional orders cannot be replaced; cancel and resubmit [A1].
- Fractional sells are long only; no fractional short sales [A2]. Minimum fractional buy is USD 1 [A2].
- GTC orders are auto-cancelled 90 days after creation; read `expires_at` [A1].
- Bracket/OCO/OTO: TIF day or gtc, no extended hours [A1]. IPO symbols (asset attribute `ipo`) accept limit orders only before first trade [A1].
- Potential wash trades are rejected with HTTP 403 [A27].

**Precision, tick and minimums (read at runtime from `GET /v2/assets` or `/v2/assets/{symbol}`)** [A15]
- Equity price tick: limit/stop price >= USD 1.00 max 2 decimals; < USD 1.00 max 4 decimals, else error 42210000 [A1].
- Equity quantity: `qty` up to 9 decimals (extra truncated); `notional` up to 2 decimals for USD [A2]. Check `fractionable`, `tradable`, `shortable`, and attributes `fractional_eh_enabled`, `overnight_tradable`, `overnight_halted`, `ipo` per asset [A15][A13].
- Crypto: per-pair `min_order_size`, `min_trade_increment`, `price_increment` on the asset object ("could change in the future") [A5][A15]; max 9 decimals [A24].

**Environments and credentials**
- Paper base URL `https://paper-api.alpaca.markets`; "different API key from your live account"; same API spec; default USD 100k balance [A7]. Paper simulation: fills only when marketable, no NBBO size check, random partial fills 10% of the time, no dividends, no fees/slippage/queue position [A7].
- Market data (`data.alpaca.markets`) is called with the *same account credentials* as trading; live and paper credentials are separate and not interchangeable [A8]. **A key the app holds for "market data only" is also a trading key for that account.**

**Third-party authorisation (Connect / OAuth2)** [A9][A10][A11]
- Authorise at `https://app.alpaca.markets/oauth/authorize`, token at `https://api.alpaca.markets/oauth/token`. Scopes: `account:write`, `trading` ("Place, cancel or modify orders"), `data`. "Read-only endpoint access is assumed by default", so read and trade are separate grants. `env=live|paper`; one token covers at most one live and one paper account.
- "To allow live trading for other users, the app needs to be approved by Alpaca"; commercial apps "must disclose it in the registration form and receive written approval"; apps are approved by Alpaca Compliance. Token lifetime/refresh: UNCONFIRMED (not documented on the page).
- Via SnapTrade, Alpaca is "bring your own API keys": you still register an Alpaca Connect app; about 4 weeks [S3].

**Order lifecycle and streaming** [A1][A4][A12]
- Status enum: new, partially_filled, filled, done_for_day, canceled, expired, replaced, pending_cancel, pending_replace, accepted, pending_new, accepted_for_bidding, stopped, rejected, suspended, calculated, held. Cancelable until filled/canceled/expired.
- Partial fills: order carries `filled_qty` and `filled_avg_price`; stream sends `partial_fill` then `fill` events, each with `price`, `qty`, `position_qty`, `timestamp`.
- WebSocket `wss://api.alpaca.markets/stream` and `wss://paper-api.alpaca.markets/stream`, stream `trade_updates`; auth by key/secret or OAuth token. Paper stream uses binary frames. No webhook mechanism is documented for the Trading API; Broker API uses SSE event streams [A28].

**Rate limits**: Trading API "currently 200 requests per minute, per account", HTTP 429 (support article dated December 2022) [A17]. Broker API limits are per correspondent, not published; read `X-RateLimit-*` headers [A23].

**Clock/calendar**: `GET /v2/clock` (is_open, next_open, next_close), `GET /v2/calendar` (market days 1970-2029), `GET /v3/clock` (multi-market phases) [A16].

**Broker API (separate product, not needed for "user holds own account")** [A22][A23][A24][A25][A26]
- Use cases: fully-disclosed broker-dealer, omnibus, RIA, trading/investing app. KYC: in the trading-app and RIA setups "Alpaca is responsible for the account approval step" (you collect the data); fully-disclosed broker-dealers must be licensed locally and Alpaca "relies on your KYC process"; omnibus customers are not disclosed to Alpaca.
- Fractional "currently supported only for day orders"; crypto must be enabled by Sales and needs a per-account `crypto_agreement`; mandated on-screen crypto order disclosures.

**Conflicts inside Alpaca's own docs (resolve on paper before declaring)**
1. Fractional order types: the Fractional Trading page (updated 2026-10-28) and the TIF table say market, limit, stop, stop_limit with TIF day [A1][A2]; "About Trading API" says "We only allow market orders for fractional trading at the moment" [A3]; the OpenAPI `notional`/`qty` descriptions say market + day only [A4]; the Fractional page's own closing disclaimer says market orders in normal hours only [A2].
2. Notional precision: 2 decimals for USD [A2] vs "up to 9 decimal points" in the Order schema [A4].
3. Crypto TIF: gtc, ioc in docs [A1][A6]; one support article adds fok [A21].

## 2. SnapTrade

**What the API does** [S1][S2]: one production host `https://api.snaptrade.com`. Equities: `POST /trade/place` (place directly), `POST /trade/impact` then `POST /trade/{tradeId}` (checked order), `POST /accounts/{id}/trading/replace` ("only supported on some brokerages"), `POST /accounts/{id}/trading/cancel` (all asset types), `GET /accounts/{id}/quotes`. Options: `/trading/options`, `/trading/options/impact`. Crypto: `/trading/crypto`, `/trading/crypto/preview`, `/trading/instruments/cryptocurrencyPairs` (pair search) and `.../{symbol}/quote`. A brokerage preview "is not available for every supported trading workflow".

**Read-only vs trade** [S1][S2]: connections are read-only by default. `connectionType` on `POST /snapTrade/login` is `read` (default), `trade`, or `trade-if-available`. Upgrade an existing connection by re-authorising with `reconnect=<connectionId>` and `connectionType=trade`. Each connection reports `type: read|trade`; each brokerage reports `allows_trading`. The launch checklist expects the user to explicitly choose read-only or trading [S7].

**Orders** [S2]
- Equity `order_type`: Limit, Market, StopLimit, Stop. `time_in_force`: Day, GTC, FOK, IOC, GTD (GTD "only available on certain brokerages", not for market orders). `trading_session`: REGULAR | EXTENDED (limit only, brokerage-specific) [S1].
- `units` may be decimal for fractional. `notional_value` "can only work with `Market` ... and `Day`" and only on certain brokerages.
- Crypto `type`: MARKET, LIMIT, STOP_LOSS_MARKET, STOP_LOSS_LIMIT, TAKE_PROFIT_MARKET, TAKE_PROFIT_LIMIT. TIF: GTC, FOK, IOC, GTD. `post_only` for LIMIT. Pairs are `BASE-QUOTE`.
- Status enum (best-effort mapping from broker statuses): NONE, PENDING, ACCEPTED, FAILED, REJECTED, CANCELED, PARTIAL_CANCELED, CANCEL_PENDING, EXECUTED, PARTIAL, REPLACE_PENDING, REPLACED, STOPPED, SUSPENDED, EXPIRED, QUEUED, TRIGGERED, ACTIVATED, PENDING_RISK_REVIEW, CONTINGENT_ORDER. Partial fill = `PARTIAL` with `filled_quantity` vs `total_quantity` [S6].
- Precision/tick/minimums: no SnapTrade-level rules endpoint was found for equities; the broker rejects invalid orders (HTTP 400). Per-broker order-type support lives in the support matrix at support.snaptrade.com/brokerages, which could not be read by tooling: **per-broker order types/TIF (including Stake AU) UNCONFIRMED.**

**Updates and limits**: poll order detail after placing ("A successful submission does not mean the order has filled") [S1]. Webhooks include `TRADE_UPDATE` ("experimental", contact support, only for trades placed through SnapTrade) and `TRADE_DETECTION` [S6]. 250 requests/minute per `clientId`; recommended max 1 trade per second per account; poll at >= 15 s intervals [S5][S1].

**Which brokers trade** (Broker Access Guide and integration pages) [S3][S4]

| Broker | Access | Notes |
|---|---|---|
| CommSec (AU) | **Read only** | Login credentials; "this integration does not support placing trades" |
| Stake Australia | **Read and Trade** | Login credentials (Stake has no public developer API) |
| Interactive Brokers (region list includes Australia) | **Read only** | Flex Query ID + token |
| Selfwealth, CMC Markets | **Not listed** | Not among the 46 integrations listed |
| moomoo | Read and Trade | Region listed as US, Canada only |
| Kraken, Coinbase, Binance | Read and Trade | Available on production approval |
| Alpaca, Tradier, TradeStation, Schwab (trading) | Read and Trade | Bring your own broker API keys; broker approval needed |

**Auth and commercial** [S7][S8][S9][S10]: Commercial integrations sign requests with `clientId` + `consumerKey` and hold a `userId`/`userSecret` per end user. No sandbox host: a free test key first ("Build" plan, up to 5 connections), production keys "after KYC approval" via a Production Access Application. Launch plan: USD 100/month platform fee plus USD 2 (real-time) or USD 1 (daily) per connected user. Pre-launch checklist requires compliance with SnapTrade's Application Compliance Policy and, for trading, "either clear user consent for automated trading or an order-confirmation flow that shows all available impact, fee, and commission information" [S7][S11]. Test brokers: "Alpaca Paper" and "Trading212 Practice" are distinct integrations [S3][S12].

## 3. Crypto exchanges for Australian residents

| Exchange | Official REST trading API | Key scopes (trade without withdraw?) | AUD pairs | Precision / minimum source | Sandbox | AU regulatory statement |
|---|---|---|---|---|---|---|
| **Kraken** | Yes, `https://api.kraken.com/0`, WS v2 `wss://ws.kraken.com/v2` [K6] | Granular: "Create & Modify Orders", "Cancel/Close Orders", "Query Funds" separate from "Withdraw Funds" [K1]. **Yes** | 14 AUD-quoted pairs returned for `country_code=AU` [K8]; FAQ lists BTC, ETH, USDT, USDC, XRP, LTC, ADA, BCH, XTZ, LINK /AUD [K7] | `GET /0/public/AssetPairs`: `pair_decimals`, `lot_decimals`, `ordermin`, `costmin`, `tick_size`, `status` [K3] | Spot: "UAT available on request via Account Manager"; `validate=true` dry-run on AddOrder; kraken-cli paper trading [K2][K6] | "registered Digital Currency Exchange Provider (DCE) with AUSTRAC ('Bit Trade Pty Ltd.', ABN 42 163 237 634)"; Bit Trade is an authorised representative of AFSL holder Beaufort Fiduciaries; derivatives wholesale only [K7] |
| **Coinbase Advanced Trade** | Yes, `https://api.coinbase.com/api/v3/brokerage` [C2] | CDP key: `view`, `trade`, `transfer`; portfolio and IP restrictions [C3][C4]. **Yes** | **1** AUD-quoted spot product (USDC-AUD) of 927 [C10] | `GET /market/products` (public): `base_increment`, `quote_increment`, `price_increment`, `base_min_size`, `quote_min_size`, `trading_disabled` [C7][C10] | Static mock at `https://api-sandbox.coinbase.com/api/v3/brokerage`, Accounts and Orders only, no auth [C5] | **UNCONFIRMED** (Coinbase licence pages refused automated access) |
| **Independent Reserve** | Yes, `https://api.independentreserve.com` [I1] | Roles: Full Access, Trade, Read Only, Restricted Withdrawals. Withdraw methods need Full Access or Restricted Withdrawals. **Yes (Trade role)** [I1] | AUD, USD, NZD, SGD [I3] | Decimal-places table in docs; `GetPrimaryCurrencyConfig2` (`DecimalPlaces.Order*`); `GetOrderMinimumVolumes` [I1] | None documented | "registered as a Digital Currency Exchange (DCE) with AUSTRAC: DCE-100461150-001" [I1] |
| **BTC Markets** | Yes, v3 at docs.btcmarkets.net [B1] | **UNCONFIRMED** (docs and support site refused automated access) | AUD exchange; pair list UNCONFIRMED | UNCONFIRMED | UNCONFIRMED | UNCONFIRMED |
| **Swyftx** | Yes, `https://api.swyftx.com.au` ("This API is in Beta") [W1] | Granular scopes: `app.orders.create/delete/read` separate from `app.funds.withdraw` [W1]. **Yes** | AUD is a primary asset [W1] | `GET /markets/assets/`: `minimum_order`, `price_scale`, `minimum_order_increment` [W1] | Demo mode `https://api.demo.swyftx.com.au` (orders, swap, history, balances) [W1] | Swyftx Pty Ltd, AFSL 568543; spot exchange "not provided under Swyftx's AFSL"; "registered with AUSTRAC as a Digital Currency Exchange (DCE) provider" [W2] |
| **CoinSpot** | Yes, v2 "(BETA)": full-access `/api/v2`, read-only `/api/v2/ro` [P1] | Full Access vs Read Only keys; withdrawal endpoints "must be ENABLED via the API key options". Trade-without-withdraw appears possible but is not stated explicitly [P1] | AUD default market [P1] | Amounts up to 8 decimals, AUD 2 decimals; no minimums endpoint [P1] | None documented | UNCONFIRMED (not on pages read) |
| **Binance** | Yes, `https://api.binance.com` [N1] | Per-key permissions; "By default, an API key cannot TRADE"; withdrawal needs an IP restriction [N1][N2]. **Yes** | 30 AUD symbols exist, **all status BREAK, none TRADING** [N3] | `GET /api/v3/exchangeInfo` filters: PRICE_FILTER, LOT_SIZE, NOTIONAL [N1] | Spot Testnet `https://testnet.binance.vision/api`, separate keys [N1] | **UNCONFIRMED** (Binance Australia's current registration and API availability not verified) |

**Per-exchange order details**
- Kraken [K2][K4][K5]: `ordertype` market, limit, iceberg, stop-loss, take-profit, stop-loss-limit, take-profit-limit, trailing-stop, trailing-stop-limit, settle-position. `timeinforce` GTC (default), IOC, GTD. Flags `post`, `viqc` (quote-currency volume, buy market only). Status: pending, open, closed, canceled, expired; partial fill = `vol_exec` < `vol`. WS `executions` channel needs a 15-minute token from `GetWebSocketsToken` (permission "Access WebSocket API") [K1]. Auth HMAC-SHA512 with nonce. REST counter max 15/20 by tier; AddOrder/CancelOrder use per-pair engine counters.
- Coinbase [C1][C2][C6][C7][C8]: spot, US futures and (non-US) derivatives share one API; spot only is relevant here. `order_configuration` keys `market_market_ioc`, `limit_limit_gtc`, `limit_limit_gtd`, `limit_limit_fok`, `sor_limit_ioc`, `stop_limit_stop_limit_gtc|gtd`, `trigger_bracket_gtc|gtd`. Market buy by `quote_size` or `base_size`. Status: PENDING, OPEN, FILLED, CANCELLED, EXPIRED, FAILED, QUEUED, CANCEL_QUEUED, EDIT_QUEUED, UNKNOWN_ORDER_STATUS; no partial status, read `filled_size`, `completion_percentage`, `average_filled_price`. Auth: ES256 JWT, 2-minute expiry. "API Key authentication should only be used to access your own account"; apps acting for other users use OAuth2 (`wallet:buys:create` for `POST /orders`) [C3][C4][C9]. User order stream `wss://advanced-trade-ws-user.coinbase.com`. REST rate limits: current official page not found, UNCONFIRMED; WS 8/s per IP.
- Independent Reserve [I1][I2]: `PlaceLimitOrder` (LimitBid/LimitOffer; `timeInForce` Gtc, Ioc, Fok, Moc), `PlaceMarketOrder` (MarketBid/MarketOffer, `allowedSlippagePercent`), `CancelOrder(s)`, `clientId` (max 36 chars, publicly visible). Status: Open, Filled, PartiallyFilled, PartiallyFilledAndCancelled, Cancelled, Expired, PartiallyFilledAndExpired, Failed, PartiallyFilledAndFailed. Auth: apiKey + nonce or expiry + HMAC-SHA256; `expiry` requires an IP-restricted key. Rate limits not stated on the API page: UNCONFIRMED.
- Swyftx [W1]: order types 1 MARKET_BUY, 2 MARKET_SELL, 3 LIMIT_BUY, 4 LIMIT_SELL, 5 STOP_LIMIT_BUY, 6 STOP_LIMIT_SELL; no TIF parameter; status is numeric 1-10 with no labels in the spec (UNCONFIRMED). API key is a refresh token exchanged at `POST /auth/refresh/` for a JWT valid one week; `GET /user/apiKeys/scope/` returns the key's scopes. Rate limits not in the spec: UNCONFIRMED.
- CoinSpot [P1]: `/my/buy`, `/my/sell` (order at a stated rate), `/my/buy/now`, `/my/sell/now`, `/my/swap/now`, cancel and edit endpoints; no TIF; HMAC-SHA512 + nonce; 1000 requests/minute.
- Binance [N1]: LIMIT, MARKET, STOP_LOSS, STOP_LOSS_LIMIT, TAKE_PROFIT, TAKE_PROFIT_LIMIT, LIMIT_MAKER; TIF GTC, IOC, FOK; status NEW, PENDING_NEW, PARTIALLY_FILLED, FILLED, CANCELED, PENDING_CANCEL, REJECTED, EXPIRED, EXPIRED_IN_MATCH; weight limits published in `exchangeInfo.rateLimits`.
- BTC Markets: only the legacy v1/v2 wiki was readable (2019: 50 calls/10 s default) [B2]. Everything about v3 is UNCONFIRMED.

**Recommendation: first integrations for AU users**
1. **Kraken**: official REST + WebSocket, order permissions separable from withdrawal, 14 AUD pairs, runtime precision endpoint, `validate=true` dry-run, and a stated AUSTRAC registration plus AFSL authorised-representative status. Gap: no self-service spot sandbox. Already reachable through SnapTrade as Read and Trade [S3], in which case SnapTrade rather than the app holds the user's credential (which Kraken permissions SnapTrade asks for: UNCONFIRMED).
2. **Independent Reserve**: Australian exchange, explicit "Trade" key role that cannot withdraw, AUD/USD/NZD/SGD, published AUSTRAC DCE number. Gap: no sandbox or documented rate limits, so test with minimum-size orders.
- Runner-up Swyftx (demo mode, granular scopes, AUD) is held back by "Beta, may change without notice" and unlabeled numeric statuses. Coinbase has the cleanest API but one AUD pair and unverified AU standing. Binance: no AUD pair is trading. BTC Markets and CoinSpot need a manual read of their docs first.

## 4. Comparison

| | Alpaca Trading/Connect | SnapTrade | Kraken | Independent Reserve | Coinbase Adv. | Swyftx |
|---|---|---|---|---|---|---|
| AU resident usable | UNCONFIRMED | Yes (Stake AU trade; CommSec/IBKR read) | Yes | Yes | UNCONFIRMED | Yes |
| Assets | US stocks/ETFs, crypto (USD) | Broker-dependent (ASX via Stake) | Crypto | Crypto | Crypto | Crypto |
| ASX | No | Via Stake AU only | No | No | No | No |
| Fractional | Yes (day only) | Broker-dependent | Native decimals | Native decimals | Native decimals | Native decimals |
| Sandbox | Paper (full) | None (Alpaca Paper as test broker) | UAT on request; `validate` | None | Static mock | Demo mode |
| Read vs trade separate | Yes (OAuth scope `trading`) | Yes (`connectionType`) | Yes | Yes (roles) | Yes | Yes |
| Withdraw excluded | Trading scope has no transfer | No money movement API | Yes | Yes (Trade role) | Yes (omit `transfer`) | Yes |
| Order stream | WebSocket `trade_updates` | Poll; experimental webhook | WS `executions` | WebSocket | WS user channel | Poll |
| Approval needed | Alpaca Compliance for live OAuth | Production key + KYC | None for own key | None for own key | OAuth app for others | None for own key |

## 5. Implications for adapter capability declarations

Declare only what is confirmed. Everything UNCONFIRMED stays `false`/absent until checked. Always read precision at runtime, never hard-code.

**AlpacaPaperAdapter / AlpacaLiveAdapter**
- `countries`: paper = any; live = `[]` until Alpaca confirms AU residents in writing.
- `assetClasses`: `usEquity`, `crypto` (USD-quoted). `asx: false`.
- `orderTypes` equity whole: market, limit, stop, stopLimit, trailingStop. Equity fractional/notional: **market only** until conflict 1 is settled on paper, then add limit/stop/stopLimit. Crypto: market, limit, stopLimit.
- `tifs` equity whole: day, gtc (omit ioc/fok/opg/cls: sales-gated). Fractional/notional: day. Extended hours: limit + day/gtc. Crypto: gtc, ioc.
- `fractional: true` only when asset `fractionable == true`; `notional: true` (2 decimals); `qtyDecimals: 9`; `shortFractional: false`; `replaceNotional: false`.
- `precisionSource`: `/v2/assets` (crypto increments; equity sub-penny rule 2/4 decimals).
- `permissions`: own keys = full account (no read-only key); OAuth = read by default, `trading` scope for orders. `environments`: paper, live as separate credentials and base URLs. `marketClock`: `/v2/clock`, `/v2/calendar`. `rateLimit`: 200/min. `maxOrderNotional` crypto: 200000 USD. `gtcExpiryDays`: 90.

**SnapTradeAdapter** (capabilities are per connection, not per provider)
- `canTrade = connection.type == "trade" && brokerage.allows_trading`. AU: Stake Australia trade; CommSec and IBKR read-only; Selfwealth/CMC unsupported.
- `orderTypes`: market, limit, stop, stopLimit (broker may reject). `tifs`: day, gtc, fok, ioc, gtd (broker-dependent). `notional`: market + day only, certain brokers. `extendedHours`: limit only, broker-dependent.
- `preview`: optional (`/trade/impact`), not universal. `streaming: false` (poll >= 15 s; `TRADE_UPDATE` experimental). `rateLimit`: 250/min per client, 1 trade/s/account.
- `environments`: production only; test with Alpaca Paper connection. `precisionSource`: none (broker validates).

**KrakenAdapter**
- `countries`: includes AU. `assetClasses`: crypto spot. `quoteCurrencies`: from `AssetPairs?country_code=AU`.
- `orderTypes`: market, limit, stopLoss, stopLossLimit, takeProfit, takeProfitLimit (+ trailing variants). `tifs`: gtc, ioc, gtd.
- `precisionSource`: `AssetPairs` (`pair_decimals`, `lot_decimals`, `ordermin`, `costmin`, `tick_size`; honour `status`).
- `permissions`: require key with Query Funds, Query Open/Closed Orders, Create & Modify Orders, Cancel/Close Orders, Access WebSocket API; **reject a key that can withdraw** (probe a withdraw-info call and expect `EGeneral:Permission denied`).
- `environments`: live only; `dryRun: true` via `validate=true`.

**IndependentReserveAdapter**
- `countries`: AU (also NZ, SG per fiat list). `quoteCurrencies`: AUD, USD, NZD, SGD.
- `orderTypes`: market, limit. `tifs`: gtc, ioc, fok, moc (limit only). `precisionSource`: `GetPrimaryCurrencyConfig2`, `GetOrderMinimumVolumes`.
- `permissions`: require the "Trade" role key. `environments`: live only.

**Deferred**: Coinbase (declare only after AU standing is verified; `permissions` via `GET /key_permissions`, reject `can_transfer == true`), Swyftx (demo + live; scopes via `GET /user/apiKeys/scope/`, reject `app.funds.withdraw`), CoinSpot, BTC Markets, Binance.

## Sources

All accessed 2026-11-13.

Alpaca
- [A1] Placing Orders: https://docs.alpaca.markets/us/docs/orders-at-alpaca
- [A2] Fractional Trading: https://docs.alpaca.markets/us/docs/fractional-trading
- [A3] About Trading API: https://docs.alpaca.markets/us/docs/trading-api
- [A4] Create an Order (OpenAPI): https://docs.alpaca.markets/us/reference/postorder
- [A5] Crypto Spot Trading: https://docs.alpaca.markets/us/docs/crypto-trading
- [A6] Crypto Orders: https://docs.alpaca.markets/us/docs/crypto-orders
- [A7] Paper Trading: https://docs.alpaca.markets/us/docs/paper-trading
- [A8] Authentication: https://docs.alpaca.markets/us/docs/authentication
- [A9] About Connect API: https://docs.alpaca.markets/us/docs/about-connect-api
- [A10] Using OAuth2 and Trading API: https://docs.alpaca.markets/us/docs/using-oauth2-and-trading-api
- [A11] Registering Your App: https://docs.alpaca.markets/us/docs/registering-your-app
- [A12] Websocket Streaming: https://docs.alpaca.markets/us/docs/websocket-streaming
- [A13] 24/5 Trading: https://docs.alpaca.markets/us/docs/245-trading-for-trading-api
- [A14] Trading Account: https://docs.alpaca.markets/us/docs/account-plans
- [A15] Get Assets (OpenAPI): https://docs.alpaca.markets/us/reference/get-v2-assets-1
- [A16] Clock and calendar: https://docs.alpaca.markets/us/reference/legacyclock , https://docs.alpaca.markets/us/reference/clock-1 , https://docs.alpaca.markets/us/reference/legacycalendar
- [A17] Support, API call limit: https://alpaca.markets/support/usage-limit-api-calls
- [A18] Support, Countries Alpaca is available: https://alpaca.markets/support/countries-alpaca-is-available
- [A19] Learn, live account as a non-US resident: https://alpaca.markets/learn/live-trading-account-non-us
- [A20] Support, Does Alpaca support cryptocurrency: https://alpaca.markets/support/alpaca-cryptocurrency
- [A21] Support, crypto order types: https://alpaca.markets/support/what-type-of-orders-are-supported-for-cryptocurrency and https://alpaca.markets/support/what-is-the-status-of-cryptocurrency-trading-on-alpaca
- [A22] Broker API: https://docs.alpaca.markets/us/docs/about-broker-api , https://docs.alpaca.markets/us/docs/use-cases , https://docs.alpaca.markets/us/docs/account-opening
- [A23] Broker API rate limits: https://docs.alpaca.markets/us/docs/broker-api-rate-limits
- [A24] Broker API crypto: https://docs.alpaca.markets/us/docs/crypto-trading-1
- [A25] Broker API trading: https://docs.alpaca.markets/us/docs/brokerapi-trading
- [A26] Getting Started with Broker API: https://docs.alpaca.markets/us/docs/getting-started-with-broker-api
- [A27] User Protection: https://docs.alpaca.markets/us/docs/user-protection
- [A28] Docs index (SSE trade events entry): https://docs.alpaca.markets/us/llms.txt

SnapTrade
- [S1] Trading with SnapTrade: https://docs.snaptrade.com/docs/trading-with-snaptrade
- [S2] OpenAPI specification: https://docs.snaptrade.com/openapi.yaml
- [S3] Broker Access Guide: https://docs.snaptrade.com/docs/broker-access-guide
- [S4] Integrations: https://snaptrade.com/brokerage-integrations and /commsec-api, /stake-aus-api, /ibkr-api, /moomoo-api under it
- [S5] Rate Limiting: https://docs.snaptrade.com/docs/ratelimiting
- [S6] Webhooks: https://docs.snaptrade.com/docs/webhooks
- [S7] Launch guide: https://docs.snaptrade.com/docs/launch-guide
- [S8] Personal vs Commercial: https://docs.snaptrade.com/docs/personal-vs-commercial
- [S9] Billing: https://docs.snaptrade.com/docs/billing
- [S10] Getting Started: https://docs.snaptrade.com/docs/getting-started
- [S11] Order impact and confirmation: https://docs.snaptrade.com/docs/order-impact-and-confirmation
- [S12] Brokerage Integrations (docs): https://docs.snaptrade.com/docs/integrations

Kraken
- [K1] API key permissions: https://docs.kraken.com/exchange/guides/rest/api-keys
- [K2] Add Order: https://docs.kraken.com/api-reference/trading/add-order
- [K3] Get Tradable Asset Pairs: https://docs.kraken.com/api-reference/market-data/get-tradable-asset-pairs
- [K4] Rate limits: https://docs.kraken.com/exchange/guides/rest/ratelimits and https://docs.kraken.com/exchange/guides/general/ratelimits
- [K5] Order lifecycle: https://docs.kraken.com/exchange/guides/general/order-lifecycle
- [K6] Exchange overview and docs index: https://docs.kraken.com/exchange/guides/overview , https://docs.kraken.com/llms.txt
- [K7] Australia FAQ (last updated 2 November 2026): https://support.kraken.com/au/articles/360046261932-australia-faq
- [K8] Live public call: https://api.kraken.com/0/public/AssetPairs?country_code=AU

Coinbase
- [C1] Advanced Trade overview: https://docs.cdp.coinbase.com/coinbase-app/advanced-trade-apis/overview
- [C2] REST endpoints: https://docs.cdp.coinbase.com/coinbase-app/advanced-trade-apis/rest-api
- [C3] Scopes and permissions: https://docs.cdp.coinbase.com/coinbase-app/advanced-trade-apis/rest-scopes
- [C4] API key authentication: https://docs.cdp.coinbase.com/coinbase-app/authentication-authorization/api-key-authentication
- [C5] Sandbox: https://docs.cdp.coinbase.com/coinbase-app/advanced-trade-apis/sandbox
- [C6] Order management: https://docs.cdp.coinbase.com/coinbase-app/advanced-trade-apis/guides/orders
- [C7] OpenAPI spec: https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/advanced-trade-spec.yaml
- [C8] WebSocket: https://docs.cdp.coinbase.com/coinbase-app/advanced-trade-apis/websocket/websocket-rate-limits , https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/introduction
- [C9] OAuth2 scopes: https://docs.cdp.coinbase.com/coinbase-app/oauth2-integration/oauth2-permissions
- [C10] Live public call: https://api.coinbase.com/api/v3/brokerage/market/products?product_type=SPOT

Independent Reserve
- [I1] API documentation: https://www.independentreserve.com/api
- [I2] OrderStatus enum (official client): https://github.com/independentreserve/dotNetApiClient/blob/master/src/DotNetClientApi/Data/OrderStatus.cs
- [I3] Live public call: https://api.independentreserve.com/Public/GetValidSecondaryCurrencyCodes

Others
- [B1] BTC Markets API repository: https://github.com/BTCMarkets/API (v3 docs at https://docs.btcmarkets.net returned HTTP 403 to tooling)
- [B2] BTC Markets legacy wiki FAQ: https://github.com/BTCMarkets/API/wiki/faq
- [W1] Swyftx API reference v1.292.2: https://docs.swyftx.com.au/
- [W2] Swyftx website footer: https://swyftx.com/au/
- [P1] CoinSpot API v2: https://www.coinspot.com.au/v2/api
- [N1] Binance Spot API docs: https://github.com/binance/binance-spot-api-docs (rest-api.md, enums.md, filters.md, testnet/rest-api.md)
- [N2] Binance API key FAQ: https://www.binance.com/en-AU/support/faq/detail/360002502072
- [N3] Live public call: https://api.binance.com/api/v3/exchangeInfo?permissions=SPOT
