# Stock Tracker design system

Stock Tracker uses semantic colors, tabular financial values, and visible data provenance on iPhone and web. Use the local platform tokens and shared components when adding a screen.

## Tokens

| Role | iPhone | Web |
| --- | --- | --- |
| Page and surfaces | `Theme.background`, `secondaryBackground`, `cardBackground` | `bg-bg`, `bg-surface`, `bg-surface-2`, `bg-surface-3` |
| Text | `Theme.primaryText`, `secondaryText` | `text-text`, `text-text-2`, `text-text-3` |
| Selection and primary action | `DS.accent`, `primaryFill`, `primaryLabel` | `primary`, `primary-hover`, `primary-text`, `primary-fg`, `primary-soft` |
| Gains, losses and warnings | `Theme.positiveColor`, `negativeColor`, `warningColor` | `up`, `down`, `warn` and their `-soft` fills |
| Number formatting | `DS.money`, `MoneyText`, `TradingFormat` | `tabular`, helpers in `web/src/lib/format.ts` |
| Spacing | `DS.Space` (4, 8, 12, 16, 24, 32 pt and a 20 pt page gutter) | Tailwind spacing scale, with 16 px card padding common |
| Shape | `DS.Radius.chip`, `card`, `sheet` (12, 20, 28 pt) | `rounded-md` for compact controls, `rounded-lg` for fields and buttons, `rounded-xl` for cards |
| Feedback and motion | `DS.quick`, `DS.spring`, `Haptics` | Focus outline, short color transitions and the `skeleton` class |

The native definitions live in [DesignSystem.swift](../Stock%20Tracker/DesignSystem.swift), [ThemeManager.swift](../Stock%20Tracker/ThemeManager.swift) and [DSGlass.swift](../Stock%20Tracker/DSGlass.swift). Native System mode follows the device. Web defaults to dark and provides a light palette in [globals.css](../web/src/app/globals.css).

## Components and states

| Use | iPhone | Web |
| --- | --- | --- |
| Titles, sections and financial metrics | `SectionHeader`, `MoneyText`, `TradingSection`, `.frostedCard()` | `PageHeader`, `Card`, `CardHeader` |
| Actions and choices | `PrimaryPillButtonStyle`, `SecondaryPillButtonStyle`, `QuietTextButtonStyle` | `Button`, `ButtonLink`, `Segmented` |
| Input and feedback | Native form controls, `EmptyStateCard`, `StatusLabel` | `Field`, `Input`, `Select`, `Notice`, `EmptyState`, `Skeleton` |
| Instruments and prices | `AdaptiveQuoteRow`, `QuoteNumbers`, `ChangePill`, `InstrumentLabel` | `InstrumentRow`, `ChangeText`, `StatusChip`, `SourceLine` |
| Charts | `PortfolioPerformanceChart`, `EquityCurveChart`, `PortfolioAllocationView` | `PriceChart`, `EquityChart`, `Sparkline`, `PortfolioHistory` |
| Order review and risk | `OrderTicketView`, `RiskReportView`, `PracticeChip` | Order and Practice routes, with explicit review and labelled simulation |
| Agent and assistant evidence | `EvidenceList`, `StatusLabel`, `AgentAvatar` | `AssistantChat` source list, Agent Studio run and proposal cards |

Use primary actions for the next step and secondary actions for supporting work. Use the buy and sell variants on order controls with visible labels. Give controls distinct disabled and loading states. A failed data request uses an unavailable state and a retry action where the request can be repeated. Use a skeleton while a request is pending. Keep empty holdings and unavailable holdings distinct.

## Financial data and accessibility

- Pair every market value with its currency. Show the provider, observation time and real-time, delayed or indicative status where market data is used. Use a stale label when applicable.
- Use a sign, direction icon or label with gain and loss colors. Keep practice and provider order status visible during confirmation and in activity.
- Use native semantic controls and Dynamic Type on iPhone. Give icon-only actions accessibility labels and verify important screens with VoiceOver, large text and Reduce Motion.
- Use links for navigation and buttons for actions on web. Keep the focus ring visible, provide label associations and useful chart summaries, and verify keyboard order and reduced motion. `Segmented` uses the radio group pattern with arrow-key selection.
- Portfolio history shows dated USD values with keyboard inspection and an expandable data table. Statement periods show investment change with a solid line and net external transfers with a dashed line.
- At phone widths, allow prices, status and source labels to wrap. Retain a readable order of asset, quantity, value and source when a row stacks.

The code provides reusable primitives. A full accessibility and contrast audit across all screens and states is still pending.
