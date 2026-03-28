# Tier Limits, Downgrade Handling & Paywall Redesign

**Date:** 2026-03-18
**Status:** Approved

## Context

The app has three subscription tiers (Free, Pro, Black) but limit enforcement is inconsistent — free users have no portfolio access at all, watchlist limits aren't always enforced, and there's no downgrade handling when users drop tiers. The paywall/upgrade views are visually bloated with excessive gradients, animations, and feature rows.

This spec addresses: consistent tier limits, graceful downgrade with a "choose your keepers" flow, and a clean comparison-table paywall redesign.

## Tier Limits

| Feature | Free | Pro | Black |
|---|---|---|---|
| Watchlist items | 10 | 50 | Unlimited |
| Portfolio holdings | 4 | 25 | Unlimited |
| Watchlist groups | 1 | 2 | Unlimited |
| Price alerts | 1 | 25 | Unlimited |
| Auto-refresh | Manual | 60s | Configurable (5-30s) |
| Chart timeframes | 1D/1W/1M | All | All |
| AI insights | None | 20/day | Unlimited |
| Benchmark vs S&P 500 | No | No | Yes |
| Ad-free | No | Yes | Yes |
| Cloud sync | Watchlist only | All data | All data |

**Key change:** Free users now get portfolio access (capped at 4 holdings). Previously portfolio was Pro-gated entirely. This gives free users a taste of portfolio features to drive upgrades.

## Downgrade Flow

### Detection

`SubscriptionManager.restoreEntitlements()` detects the new lower tier on app launch or StoreKit transaction update. After setting the new tier, it checks whether current asset counts exceed the new tier's limits.

### Keeper Selection Sheet

When a user is over-limit after a downgrade, a full-screen **"Choose Your Keepers"** modal appears. This is a one-time flow per downgrade event.

**Step 1 — Watchlist** (shown only if `watchlist.count > tier.watchlistLimit`):
- Header: "Your plan allows N watchlist items. You have X."
- Subheader: "Select N to keep. The rest will be removed."
- List of all current watchlist items with checkmark toggle
- Running counter: "7 of 10 selected"
- "Continue" button disabled until exactly N items selected

**Step 2 — Portfolio** (shown only if `portfolio.count > tier.portfolioLimit`):
- Same pattern: "Select N holdings to keep."
- Each row shows: symbol, name, shares, current value
- "Confirm" button disabled until exactly N items selected

**On confirm:**
- Unselected items are removed from watchlist/portfolio via existing `removeFromWatchlist`/`removeFromPortfolio` methods
- `needsKeeperSelection` flag is cleared
- App continues normally under new limits
- Sheet only appears once per downgrade (flag stored in UserDefaults)

### Ongoing Over-Limit Enforcement

If the user dismisses the app before completing keeper selection, or if items are somehow still over-limit:
- Over-limit items are **greyed out** — visible but excluded from live price refresh
- A persistent banner appears in the affected section: "X items over your plan limit. Remove items or upgrade."
- User cannot add new items while over the limit
- Greyed items show last-known price with a stale indicator

## Limit Enforcement Points

| Action | Check | Blocked behavior |
|---|---|---|
| Add to watchlist | `watchlist.count >= tier.watchlistLimit` | Show paywall |
| Add to portfolio | `portfolio.count >= tier.portfolioLimit` | Show paywall |
| Create watchlist group | `watchlistGroups.count >= tier.watchlistGroupLimit` | Show paywall |
| Create portfolio group | `portfolioGroups.count >= tier.portfolioGroupLimit` | Show paywall |
| Add price alert | `alerts.count >= tier.alertLimit` | Show paywall with quota |
| App launch after downgrade | `counts > new tier limits` | Show keeper picker |

## Paywall Redesign

Replace the current paywall with a clean comparison table.

### Layout

1. **Header**: Context line with the feature that triggered the paywall (e.g., "Unlock Portfolio Tracking")
2. **Billing toggle**: Monthly / Annual with "Save 33%" badge on annual
3. **Comparison table**: 3 columns (Free / Pro / Black)
4. **CTA row**: "Current Plan" (greyed) for active tier, "Subscribe" buttons for others
5. **Footer**: Restore purchases, terms & privacy links

### Feature Rows (10 max)

1. Watchlist items — 10 / 50 / Unlimited
2. Portfolio holdings — 4 / 25 / Unlimited
3. Price alerts — 1 / 25 / Unlimited
4. Auto-refresh — Manual / 60s / 5-30s
5. Chart timeframes — 3 / All / All
6. AI insights — dash / 20/day / Unlimited
7. Benchmark vs S&P 500 — dash / dash / checkmark
8. Ad-free — dash / checkmark / checkmark
9. Cloud sync — Watchlist / All / All
10. Multiple watchlists — 1 / 2 / Unlimited

### Style

- Clean dark card background, subtle borders
- Clear typography hierarchy (no excessive gradients or glow effects)
- Active tier column gets a subtle highlight border
- Recommended tier gets a "Popular" or "Best Value" badge
- No spring animations, no social proof section, no trust badges
- Monthly/annual prices shown clearly under each tier name

### FeatureLockView Update

Simplify to match new paywall aesthetic: icon + feature name + "Upgrade to [Tier]" button. Remove gradient backgrounds. Tapping opens the new comparison-table paywall.

## Files to Modify

| File | Change |
|---|---|
| `FeatureGate.swift` | Update limits: Free watchlist=10, portfolio=4; Pro watchlist=50, portfolio=25; verify all limits match spec |
| `Constants.swift` | Sync `FreeTier` constants with FeatureGate values |
| `SubscriptionManager.swift` | Add `needsKeeperSelection` published flag, downgrade detection in `restoreEntitlements()`, `checkDowngradeLimits()` method |
| `MarketData.swift` | Add `isOverWatchlistLimit`/`isOverPortfolioLimit` computed props, `activeWatchlistItems`/`greyedOutWatchlistItems` computed props |
| `PaywallView.swift` | Full rewrite as comparison table |
| `FeatureLockView` (in SubscriptionManager.swift) | Simplify design, connect to new paywall |
| **NEW** `TierKeeperSheet.swift` | "Choose Your Keepers" downgrade modal with watchlist + portfolio steps |
| `AppleStocksWatchlistView.swift` | Show over-limit banner, grey out excess items, check portfolio limit on add |
| `PortfolioView.swift` | Show over-limit banner, grey out excess holdings |
| `SearchSheet.swift` | Ensure add-to-watchlist checks updated limits |
| `Stock_TrackerApp.swift` | Present keeper sheet on launch when `needsKeeperSelection` is true |

## Data Flow

```
App Launch
  -> SubscriptionManager.restoreEntitlements()
  -> New tier detected (lower than before)
  -> checkDowngradeLimits()
     -> watchlist.count > newLimit OR portfolio.count > newLimit?
        YES -> needsKeeperSelection = true
        NO  -> continue normally
  -> Stock_TrackerApp observes needsKeeperSelection
     -> Presents TierKeeperSheet as fullScreenCover
        -> User picks keepers
        -> Unselected items removed
        -> needsKeeperSelection = false
        -> UserDefaults flag cleared
```

## Out of Scope

- Server-side enforcement (all limits are client-side)
- Migration of existing users' data on first launch with new limits (existing free users with >10 items will see the keeper picker on next launch)
- Refund/chargeback handling beyond what StoreKit 2 provides
