# Stock Tracker Design Patterns

Confirmed by reading AppleStocksWatchlistView.swift, ThemeManager.swift,
AppleStocksDetailView.swift, QuickStatsSection.swift, ExpandableStatsSection.swift,
PositionSection.swift, ValuationMetrics.swift, StickyHeaderView.swift (Feb 2026).

---

## Color System

### Semantic Colors (always use these)
- Positive/gain: `appTheme.positiveColor` via `@Environment(\.theme) var appTheme`
- Negative/loss: `appTheme.negativeColor`
- Accent (blue): `appTheme.accentColor`
- Warning: `appTheme.warningColor` (.orange)
- Neutral: `appTheme.neutralColor` (.gray)

### Glass Colors
- Fill: `theme.glassBackground` — dark: white 8% opacity, light: gray 8% opacity
- Border: `theme.glassBorder` — dark: white 20% opacity, light: gray 15% opacity
- Glass gradient: `theme.glassGradient` — topLeading to bottomTrailing

### DO NOT hardcode
- `.green` / `.red` — use semantic colors
- `.blue` for icons/accents — use `appTheme.accentColor`
- `.purple` only acceptable for fixed categorical labels (sector/industry chips)

---

## Typography Scale

### Primary Display (main header)
- Symbol: `.system(size: 36, weight: .bold, design: .rounded)`
- Price: `.system(size: 48, weight: .bold, design: .rounded)` with `.monospacedDigit()`
- Day change dollar: `.title3.weight(.semibold)`

### Card Headers (section titles with icon)
- Interactive header (expandable): `.headline.weight(.semibold)`
- Static display header: `.headline.weight(.bold)` — but prefer `.semibold` for consistency

### Card Content
- Label in StatCard: `.caption2.weight(.semibold)` + `.tracking(0.5)` + `.uppercased()`
- Value in StatCard: `.subheadline.weight(.bold)` + `.monospacedDigit()`
- Row label in DetailRow: `.subheadline` foregroundColor `.secondary`
- Row value (plain): `.subheadline.weight(.semibold)` + `.monospacedDigit()`
- Row value (colored pill): `.caption.weight(.bold)` + `.monospacedDigit()`

### Pill badges / tags
- Text: `.caption.weight(.semibold)` (compact inline) or `.caption.weight(.bold)` (standalone pill)

---

## Corner Radii

| Surface | Value | Example |
|---|---|---|
| Showcase card (mover, featured) | 22 | TopMoverCard |
| Standard content card | 16 | WatchlistStatsCard, ValuationMetrics, ExpandableStatsSection |
| Small tile (3-column grid) | 14 | StatCard |
| Pill badge (capsule preferred) | Capsule() | EnhancedWatchlistRow change %, SearchResultRow |
| Compact inline badge | 6 | ExchangeBadge, StickyHeaderView change pill |
| Chart type toggle segment | 9 | chartTypeToggle |
| Chart type toggle container | 12 | chartTypeToggle |

Rule: use Capsule() for variable-width pill badges. Use cornerRadius(6) only for
fixed small badges that sit tightly next to other text elements.

---

## Border Treatment

### Standard glass card
```swift
.overlay(
    RoundedRectangle(cornerRadius: 16)
        .stroke(theme.glassBorder, lineWidth: 1)
)
```

### Dynamic tinted border (when card represents a position with gain/loss)
```swift
.overlay(
    RoundedRectangle(cornerRadius: 16)
        .stroke(glColor.opacity(0.35), lineWidth: 1.5)
)
```
Reference: TopMoverCard uses lineWidth: 2 at opacity 0.4. PositionSection uses 1.5 at 0.35.
Both are correct — the thinner/lower-opacity version suits data-dense cards; the thicker/brighter
version suits showcase cards.

---

## Spacing

### Card internal padding
- Standard card: `.padding(16)` or `.padding(18)` for position card
- Large showcase card: `.padding(20)` (TopMoverCard)
- Card internal item spacing: 12 (standard), 16 only for complex multi-block sections

### Between sections in scroll view
- Primary spacing (VStack in body): 24
- Between expandable sections: 12
- Below a card before the next section: 20

---

## Glass Card Recipe (standard)
```swift
.padding(16)
.background(theme.glassBackground)
.cornerRadius(16)
.overlay(
    RoundedRectangle(cornerRadius: 16)
        .stroke(theme.glassBorder, lineWidth: 1)
)
```
theme is constructed as: `let theme = Theme(colorScheme: colorScheme)`
appTheme is `@Environment(\.theme) var appTheme`

---

## Icon Circle Backing (section header icons)
```swift
ZStack {
    Circle()
        .fill(appTheme.accentColor.opacity(0.15))
        .frame(width: 32, height: 32)
    Image(systemName: iconName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(appTheme.accentColor)
}
```
Size: 32x32 for section headers (interactive), 28x28 for smaller static headers.
Do NOT use hardcoded Color.blue — use appTheme.accentColor.

---

## Animation

### Expand/collapse
- Spring: `.spring(response: 0.4, dampingFraction: 0.8)`
- Chevron rotation only: `.spring(response: 0.3, dampingFraction: 0.7)`
- Always wrap in `withAnimation(reduceMotion ? .none : animation)`

### Expand transition
- Preferred: `.opacity` or `.opacity.combined(with: .scale(scale: 0.97, anchor: .top))`
- Avoid: `.move(edge: .top)` — content appears to come from above the header (reversed direction)

### Sticky header
- `.easeInOut(duration: 0.2)` for show/hide

### Number updates
- `.contentTransition(.numericText())` + `.animation(.easeInOut(duration: 0.08), value: displayPrice)`

### Haptic
- Interactive accordion toggle: `UIImpactFeedbackGenerator(style: .light).impactOccurred()`

---

## Accessibility

### Reduce motion
- Import `@Environment(\.accessibilityReduceMotion) var reduceMotion`
- Wrap animations: `withAnimation(reduceMotion ? .none : .spring(...))`
- Use `motionSafeWithAnimation()` helper from AccessibilityHelpers.swift

### VoiceOver
- Use `.accessibilityElement(children: .combine)` on card containers
- Gain/loss values need dual encoding: icon + color (GainLossIndicator helper)
- Formatted string with sign prefix (%+.2f%%) counts as text-based dual encoding

### Colorblind support
- ALWAYS use `appTheme.positiveColor` / `appTheme.negativeColor`
- Never use Color.green / Color.red for semantic meaning

---

## Pill Badge Patterns

### Standalone change percentage (watchlist row, search result row)
```swift
Text(...)
    .font(.caption.weight(.bold))
    .foregroundColor(color)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().fill(color.opacity(0.2)))
```

### Compact inline badge (exchange, sticky header)
```swift
Text(...)
    .font(.caption.weight(.semibold))
    .foregroundColor(color)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(color.opacity(0.12))
    .cornerRadius(6)
```

### DetailRow colored value pill (metrics)
```swift
Text(value)
    .font(.caption.weight(.bold))
    .monospacedDigit()
    .foregroundColor(color)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(color.opacity(0.12))
    .clipShape(Capsule())  // NOT .cornerRadius(6)
```

---

## Sticky Header
- Background: `.ultraThinMaterial` in Rectangle shape (not glass card)
- Bottom separator: Rectangle height 0.5, Color.secondary.opacity(0.2)
- Transition: `.move(edge: .top).combined(with: .opacity)`
- Threshold: 100pt scroll offset
