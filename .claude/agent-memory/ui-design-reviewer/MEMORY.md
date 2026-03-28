# Stock Tracker UI Design Reviewer Memory

## Design System Source Files
- ThemeManager: `Stock Tracker/ThemeManager.swift`
- AccessibilityHelpers: `Stock Tracker/AccessibilityHelpers.swift`
- Reference watchlist view: `Stock Tracker/AppleStocksWatchlistView.swift`

## Quick Reference
See `design-patterns.md` for the full pattern catalog.

Key confirmed values:
- Glass card corner radii: 22 (showcase), 16 (standard content), 14 (small tiles)
- Glass card border: `theme.glassBorder` at `lineWidth: 1`
- Dynamic tinted border (gain/loss cards): `glColor.opacity(0.35)` at `lineWidth: 1.5`
- Pill badge shape: `Capsule()` for standalone badges, `cornerRadius(6)` for compact inline badges
- Semantic gain/loss: always `appTheme.positiveColor` / `appTheme.negativeColor` from `@Environment(\.theme)`
- Accent color: `appTheme.accentColor` (do NOT hardcode `.blue`)
- Section header font: `.headline.weight(.semibold)` for interactive headers; `.bold` for static display headers
