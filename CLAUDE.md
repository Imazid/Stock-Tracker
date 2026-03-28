# Stock Tracker — Claude Code Notes

## Project Structure
- **Single target**: "Stock Tracker" — all `.swift` files in `Stock Tracker/` are auto-included
- **Widget extension**: `Stock Tracker Widget Extension/` (separate folder, separate target)
- **Build destination**: `iPhone 17, OS=26.2` (iPhone 16 not available)
- **Build command**:
  ```
  xcodebuild -project "Stock Tracker.xcodeproj" -scheme "Stock Tracker" \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,name=iPhone 17,OS=26.2" build
  ```

## Key Architecture
- `MarketData` — central `@MainActor ObservableObject`, injected via `@EnvironmentObject`
- `APIService.shared` — all network calls (Alpaca, CoinGecko, Alpha Vantage, NewsAPI)
- `QuoteService` — stock/crypto quote logic, price history routing
- `PortfolioService` — persistence, history generation
- `SecretsConfig` — keys from `Config/Secrets.plist` → Keychain (plist always wins)

## APIs
| Service | Purpose | Notes |
|---------|---------|-------|
| Alpaca `/v2/stocks/bars` | Stock price history | `feed=iex` required; Basic auth header |
| Alpaca `/v2/stocks/quotes/latest` | Live stock quotes | |
| CoinGecko `/api/v3/coins/{id}/market_chart` | **Crypto price history** | Routed via `QuoteService.fetchPriceHistory` |
| CoinGecko `/api/v3/simple/price` | Live crypto batch prices | |
| Alpha Vantage `SYMBOL_SEARCH` | Symbol search | Slow on demo key |
| NewsAPI `/v2/everything` | News | Returns 426 on device; falls back to mock |

## Price History Routing (QuoteService.fetchPriceHistory)
- `.crypto` assets → `api.fetchCryptoHistory(id: cgId, range:)` via CoinGecko
- `.stock` assets → `api.fetchHistoricalData(symbol:range:)` via Alpaca
- Both fall back to `generatePriceHistoryFallback` on error (synthetic random walk)

## Chart Details (AssetDetailView)
- **Line chart** (`ChartType.line`): area fill + line, smart Y-axis (never starts at 0)
- **Candlestick chart** (`ChartType.candle`): stocks only, `RuleMark` for wick + `BarMark(yStart:yEnd:)` for body
- **Displayed time ranges**: 1D, 1W, 1M, 3M, 6M, YTD, 1Y, 5Y
- **Alpaca bar granularity**:
  - 1D → 15-minute bars
  - 1W → hourly bars
  - 1M–1Y → daily bars
  - 5Y+ → weekly bars

## MarketStatusView
- Shows a single badge (NYSE or ASX) based on `@AppStorage("preferredMarket")` ("US" or "AU")
- Preference is set in **Settings → Preferences → Market Status**
- Updates live via `.onChange(of: preferredMarket)`

## PortfolioIntelligenceView (real data)
- **Allocation**: asset type split (stocks/crypto) + top holdings donut — from `marketData.portfolio`
- **Performance**: real unrealized P&L via `marketData.totalProfitLoss / totalProfitLossPercent`
- **Dividends**: filters holdings with `asset.dividend > 0`, shows annual/monthly income
- **Benchmark**: S&P 500 history line (`sp500History`) + portfolio return dashed reference line

## Common Swift / Build Pitfalls
- `StoreKit.Transaction` must be fully qualified (local `Transaction` model causes ambiguity)
- Any file using `AppLogger` needs explicit `import OSLog`
- `specifier:` in string interpolation deprecated → use `String(format:, value)`
- SourceKit "Cannot find X in scope" errors are almost always false positives — always build to confirm
- `withTaskGroup` not `withThrowingTaskGroup` for search operations in MarketData

## Keychain / Persistence
- `DataPersistenceManager` stores portfolio, watchlist, alerts, history → Keychain
- Bump `currentModelVersion` when any `Codable` struct stored in Keychain changes
- `Config/Secrets.plist` is gitignored; `Config/Secrets.plist.example` is the template

## CoinGecko Symbol → ID Map (QuoteService.coinGeckoIDMap)
BTC→bitcoin, ETH→ethereum, SOL→solana, ADA→cardano, BNB→binancecoin, XRP→ripple,
DOGE→dogecoin, DOT→polkadot, MATIC→matic-network, LINK→chainlink,
AVAX→avalanche-2, UNI→uniswap, LTC→litecoin, ATOM→cosmos
