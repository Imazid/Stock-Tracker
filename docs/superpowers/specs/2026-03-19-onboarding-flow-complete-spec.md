# Stock Tracker: Complete Onboarding Flow Specification

**Date:** 2026-03-19
**Status:** Draft
**Platform:** iOS (primary), Android (cross-platform notes included)
**Locale:** en-AU (default)
**Version:** 1.0

---

## 1. Executive Summary

This specification defines a complete, production-ready onboarding flow for Stock Tracker, a mobile stock and cryptocurrency tracking application targeting Australian and US investors.

**Current state:** The app has a 5-screen onboarding (Welcome, Features, Market Selection, Portfolio Setup, Notifications) with no account creation, no email/SSO sign-up, and no verification flow. Biometric lock happens post-onboarding via the existing `AuthManager`.

**Proposed state:** A redesigned 8-phase onboarding with account creation (email + SSO), OTP verification, value-led permission requests, enhanced watchlist/portfolio setup with import flows, contextual feature discovery, and retention hooks. The flow is designed for progressive disclosure: users reach core value (watchlist tracking) within 90 seconds, with advanced features revealed contextually.

**Key design principles:**
- **Value before commitment**: Users see live data before being asked to create an account
- **Progressive disclosure**: Only show what's needed now; defer complexity
- **Contextual permissions**: Ask for notifications after a user sets a price alert, not upfront
- **Platform-native**: Apple HIG patterns on iOS, Material 3 on Android
- **Accessible by default**: WCAG 2.1 AA, colorblind-safe, VoiceOver/TalkBack-ready
- **No dark patterns**: Every prompt has "Not now" / "Skip"; no deceptive copy

**Estimated completion times by variant:**
| Variant | Time to first value | Full completion |
|---------|-------------------|-----------------|
| Minimal | ~45s | ~90s |
| Guided (recommended) | ~60s | ~3 min |
| Gamified | ~60s | ~4 min |

---

## 2. Sources & Guideline Alignment Checklist

### Apple Human Interface Guidelines (HIG)

| Requirement | Compliance | Notes |
|-------------|-----------|-------|
| Onboarding should be brief and optional | YES | Core value reachable by step 3; all steps skippable |
| Sign in with Apple button styling | YES | `ASAuthorizationAppleIDButton` with `.signIn` style, `.black`/`.white` for dark/light |
| Notification pre-prompt before OS prompt | YES | Custom explanation screen shown before `UNUserNotificationCenter.requestAuthorization` |
| Biometric prompt with clear purpose | YES | Shown after user has data; explains "protect your portfolio" |
| Safe area respect | YES | All CTAs above home indicator; no content under status bar |
| Dynamic Type support | YES | All text uses semantic styles (`title`, `body`, `caption`) |
| Reduce Motion support | YES | All animations have `@Environment(\.accessibilityReduceMotion)` fallbacks |
| Minimum touch targets 44x44pt | YES | All interactive elements >= 44pt |

### Material Design 3 (Android)

| Requirement | Compliance | Notes |
|-------------|-----------|-------|
| Sign in with Google branding | YES | Use `com.google.android.gms.auth.api.identity` with official button |
| Edge-to-edge layout | YES | Content behind system bars with insets |
| Material You dynamic colour | PARTIAL | Support system accent; fallback to brand palette |
| Predictive back gesture | YES | Back navigation works throughout onboarding |
| 48dp minimum touch targets | YES | All interactive elements >= 48dp |

### Accessibility (WCAG 2.1 AA)

| Requirement | Compliance | Notes |
|-------------|-----------|-------|
| 4.5:1 contrast ratio (normal text) | YES | Verified via `ContrastChecker` in codebase |
| 3:1 contrast ratio (large text/UI) | YES | All accent colours tested against dark backgrounds |
| Focus order matches visual order | YES | VoiceOver focus order specified per screen |
| Error identification non-colour-only | YES | Icons + text + border colour for validation errors |
| Colorblind-safe gain/loss indicators | YES | Uses existing `GainLossIndicator` with dual encoding (icon + colour) |
| Screen reader labels for all controls | YES | `accessibilityLabel` specified per interactive element |

### Permission Best Practices

| Permission | When requested | Value shown first? |
|-----------|---------------|-------------------|
| Notifications | After first price alert created, OR after onboarding alert screen | YES — notification preview card shown |
| Biometrics (Face ID) | After account creation + first asset added | YES — "Protect your portfolio" context |
| Camera | Never in onboarding | N/A |
| Location | Never | N/A |
| Tracking (ATT) | 2.5s after onboarding complete (existing) | N/A |

---

## 3. Onboarding Variants

### Comparison Table

| Aspect | A: Minimal | B: Guided (Recommended) | C: Gamified |
|--------|-----------|------------------------|-------------|
| **Screens** | 4 | 8 | 10 |
| **Time to first value** | ~45s | ~60s | ~60s |
| **Full completion time** | ~90s | ~3 min | ~4 min |
| **Account creation** | Optional (deferred) | Inline (step 2) | Inline (step 2) |
| **Watchlist setup** | Quick-pick chips | Search + suggestions + preview | Search + suggestions + progress bar |
| **Portfolio import** | Deferred to main app | Inline (manual + CSV + broker) | Inline + "investment profile" quiz |
| **Feature discovery** | None (contextual coach marks later) | Interactive feature cards | Animated walk-through with rewards |
| **Permissions** | Deferred | Contextual (post-value) | Contextual + streak incentive |
| **Personalisation** | Market only | Market + interests + display prefs | Market + interests + risk profile |
| **Retention hooks** | 0 | 3 (alert nudge, suggestions, prefs) | 5 (badges, streaks, challenges) |
| **Recommended for** | Power users, re-installs | New users, growth cohort | Younger demographic, engagement focus |
| **Development effort** | Low | Medium | High |
| **Risk** | Low engagement, high drop-off | Balanced | Over-engineering; may feel patronising to experienced investors |

### Variant A: Minimal

**Flow:** Welcome Hero -> Market Selection -> Quick Watchlist Pick -> Done (with deferred account nudge)

**Pros:** Fastest to value; lowest friction; simplest implementation
**Cons:** No account creation means no cloud sync; no portfolio setup means lower activation; no retention hooks

### Variant B: Guided (Recommended)

**Flow:** Welcome Hero -> Account Creation (email/SSO) -> OTP Verification -> Market Selection -> Feature Value Tour -> Watchlist Setup (search + suggestions) -> Portfolio Setup (manual/import/broker) -> Permissions (notifications + biometrics)

**Pros:** Balanced friction/value; account created early enables sync; portfolio setup drives engagement; retention hooks built-in
**Cons:** Longer than minimal; some users may skip account creation

### Variant C: Gamified

**Flow:** Same as Guided + Investment Profile Quiz + Progress Tracker + Achievement Badges + Daily Challenge Nudge

**Pros:** Higher engagement for younger users; completion incentives; shareable moments
**Cons:** Complex to build; may feel patronising to serious investors; badge fatigue; higher maintenance
**Note:** Finance apps targeting professional/semi-professional users should avoid gamification that trivialises investing.

### Recommendation

**Use Variant B (Guided)** for the production launch. The minimal variant can be A/B tested against it. Gamification elements can be introduced later as a retention layer, not an onboarding requirement.

---

## 4. Full Screen-by-Screen Specifications

### Phase 1: First Launch

---

#### Screen OB-010: Splash / Cold Launch

**Purpose:** Brand moment while app initialises; loads StoreKit products and restores entitlements.

**Entry:** App launch (cold start)
**Exit:** Auto-dismiss after 1.8s -> OB-020 (if `!hasCompletedOnboarding`) or Main App

**Layout:**
- Full-screen, centred vertically
- Background: `theme.background` (existing `SplashView`)
- No interactive elements

**Key UI elements:**
- App icon: `chart.line.uptrend.xyaxis` (SF Symbol, thin weight)
- App name: "Stock Tracker" (semibold)

**Microcopy:** None (silent brand moment)

**Animation:**
- Icon: opacity 0 -> 1, duration 600ms, `easeIn`
- Text: opacity 0 -> 1, duration 600ms, `easeIn`, delay 200ms
- **Reduce-motion fallback:** Instant display, no animation

**Accessibility:**
- VoiceOver: "Stock Tracker, loading" (announced once)
- Focus: None (non-interactive)

**Edge cases:**
- **Offline:** Splash still shows; app continues offline with cached data
- **Slow launch (>3s):** Show subtle activity indicator at bottom after 2s

**Analytics:**
| Event | Properties |
|-------|-----------|
| `app_launched` | `is_first_launch: Bool`, `app_version: String`, `os_version: String` |

---

#### Screen OB-020: Welcome Hero

**Purpose:** Establish emotional connection; show the "promise" of the app through an animated portfolio value counter and chart.

**Entry:** After splash (first launch only, `!hasCompletedOnboarding`)
**Exit:** Tap "Get Started" -> OB-030

**Layout:**
- Full-screen, dark background (`Color.black`)
- Radial gradient glow behind chart area (blue, opacity 0.24)
- Vertical stack: portfolio counter -> chart canvas -> headline -> CTA
- CTA sticky at bottom with 60pt bottom padding

**Key UI elements:**
| Element | Component | State |
|---------|-----------|-------|
| Portfolio counter | Animated number (`$47,284`) | Counts from 0 to target over 1.65s |
| Daily change badge | HStack (arrow + text) | `+$1,284 (2.79%) today` in green |
| Chart canvas | Custom `WelcomeChartCanvas` | Catmull-Rom spline, draws L-to-R |
| Floating price badge | `WelcomePriceBadge` | Springs in at chart peak |
| Headline | "Invest with Clarity" | Static after fade-in |
| Subtitle | "Track every position..." | Static after fade-in |
| Primary CTA | `OnboardingButton` | "Get Started" |

**Microcopy:**
- Title: "Invest with Clarity"
- Subtitle: "Track every position. See every move.\nAll in one place."
- CTA: "Get Started"

**Animation specs:**
| Element | Trigger | Duration | Easing | Delay |
|---------|---------|----------|--------|-------|
| Content fade | `onAppear` | 550ms | `easeOut` | 50ms |
| Chart draw | `onAppear` | 1650ms | `easeInOut` | 300ms |
| Value counter | `onAppear` | 1650ms | `easeOut` | 300ms |
| Price badge | After chart | 450ms | `spring(0.45, 0.60)` | 1850ms |
| **Reduce-motion:** All elements appear instantly, no chart animation |

**Haptics:** None (passive screen)

**Accessibility:**
- VoiceOver order: Daily change -> Headline -> Subtitle -> CTA
- Chart: `accessibilityLabel("Animated portfolio growth chart showing upward trend")`
- Counter: `accessibilityLabel("Portfolio value forty-seven thousand two hundred eighty-four dollars")`
- CTA: `accessibilityHint("Begins the setup process")`
- Touch target: CTA button height 54pt, full-width minus 80pt horizontal padding

**Edge cases:**
- **Small screens (iPhone SE):** Chart height reduced to 140pt; font scale reduced to 0.85
- **Landscape:** Not supported in onboarding; lock to portrait

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_welcome_viewed` | `variant: String` |
| `onboarding_welcome_cta_tapped` | `time_on_screen_ms: Int` |

---

#### Screen OB-025: Feature Value Tour

**Purpose:** Show three core value propositions (Watchlist, Portfolio, AI) via swipeable cards with interactive previews.

**Entry:** After OB-020 "Get Started"
**Exit:** "Continue" -> OB-030 | "Skip intro" -> OB-030

**Layout:**
- Full-screen, dark background
- Header: "Built for investors who want clarity" + subtitle
- Swipeable `TabView` with 3 feature cards (370pt height)
- Custom page dots below carousel
- CTAs at bottom: "Continue" (primary) + "Skip intro" (secondary)

**Key UI elements:**
| Element | Details |
|---------|---------|
| Feature card: Watchlist | Mock rows: AAPL, NVDA, TSLA, MSFT with prices + change badges |
| Feature card: Portfolio | Total value counter, sparkline chart, allocation chips |
| Feature card: AI Insights | Chat bubble mockup with typing dots -> response reveal |
| Page dots | Capsule indicators (active: 20pt wide, inactive: 7pt) |

**Microcopy:**
- Header: "Built for investors who want clarity"
- Subheader: "Three views. One clear picture."
- Card 1: Watchlist — "Live prices, right when you need them"
- Card 2: Portfolio — "See your real value at a glance"
- Card 3: AI Insights — "Your portfolio, explained simply"
- CTA: "Continue"
- Secondary: "Skip intro"

**Animation specs:**
| Element | Duration | Easing |
|---------|----------|--------|
| Card entrance | 550ms | `spring(0.55, 0.78)` |
| Page dot transition | 300ms | `spring(0.3, 0.7)` |
| AI typing dots | 450ms loop | `easeInOut`, repeat |
| AI response reveal | 400ms | `easeInOut`, delay 2000ms |
| **Reduce-motion:** Cards appear instantly; AI response shown immediately |

**Accessibility:**
- Cards are individually focusable via VoiceOver
- Swipe gesture between cards announced: "Page 1 of 3, Watchlist"
- Mock data rows have descriptive labels: "Apple, price 178 dollars 50, up 1.24 percent"
- Skip button: `accessibilityHint("Skips the feature introduction and continues setup")`

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_features_viewed` | `card_viewed: [Int]`, `time_on_screen_ms: Int` |
| `onboarding_features_skipped` | `last_card_viewed: Int` |
| `onboarding_features_completed` | `all_cards_swiped: Bool` |

---

### Phase 2: Account Creation

---

#### Screen OB-030: Account Creation

**Purpose:** Create an account for cloud sync, personalisation, and data backup. Explicitly optional — users can skip and use the app locally.

**Entry:** After OB-020 or OB-025
**Exit:** SSO success -> OB-040 (OTP) or OB-050 (Market) | Email submit -> OB-040 | "Continue without account" -> OB-050

**Layout:**
- Full-screen, dark background
- Vertical stack: Icon + headline -> SSO buttons -> divider -> email form -> skip link
- Keyboard-aware: content scrolls up when keyboard appears
- CTA area sticks above keyboard

**Key UI elements:**
| Element | Component | State |
|---------|-----------|-------|
| Shield icon | `lock.shield.fill` with gradient | Static |
| Sign in with Apple | `ASAuthorizationAppleIDButton` | `.signIn` style, 50pt height, full-width |
| Continue with Google | Google branding button (official spec) | Google logo left-aligned, 50pt height |
| OR divider | Horizontal rule with "or" label | Static |
| Email field | `TextField` with email keyboard | Empty / Filled / Error |
| Password field | `SecureField` with visibility toggle | Empty / Filled / Error |
| Create Account button | `OnboardingButton` | Disabled until valid email + password |
| Skip link | Text button | "Continue without an account" |
| Privacy note | Caption text | Static |

**Microcopy:**
- Headline: "Secure your portfolio"
- Subtitle: "Sign in to sync your data across devices and keep your watchlist safe."
- Apple button: "Sign in with Apple" (Apple's required copy)
- Google button: "Continue with Google"
- Divider: "or"
- Email placeholder: "Email address"
- Password placeholder: "Create a password"
- Password helper: "At least 8 characters"
- CTA: "Create Account"
- Skip: "Continue without an account"
- Privacy: "Your data is encrypted and stored securely. We never sell your information."
- **Error — invalid email:** "Please enter a valid email address"
- **Error — weak password:** "Password must be at least 8 characters"
- **Error — email taken:** "An account with this email already exists. Try signing in instead."
- **Error — network failure:** "Couldn't connect. Check your internet and try again."
- **Error — Apple Sign In cancelled:** (no error shown, return to screen)
- **Error — Google Sign In failed:** "Google sign-in failed. Try again or use email instead."

**Primary CTA:** "Create Account" (disabled until valid)
**Secondary CTAs:** "Sign in with Apple", "Continue with Google", "Continue without an account"

**Validation rules:**
- Email: RFC 5322 basic validation (`[^@]+@[^@]+\.[^@]+`)
- Password: >= 8 characters
- Real-time validation on field blur; inline error below field

**Animation specs:**
| Element | Duration | Easing |
|---------|----------|--------|
| Screen entrance | 550ms | `spring(0.55, 0.82)` |
| SSO button press | 200ms | `spring(0.3, 0.6)` (scale 0.96) |
| Error shake | 400ms | `spring(0.3, 0.4)` (x offset -8, 8, -4, 0) |
| Loading spinner | Continuous | Indeterminate |
| **Reduce-motion:** No entrance animation; error text appears without shake |

**Haptics:**
- SSO button tap: `UIImpactFeedbackGenerator(.medium)`
- Create Account tap: `UIImpactFeedbackGenerator(.medium)`
- Validation error: `UINotificationFeedbackGenerator(.error)`
- Success: `UINotificationFeedbackGenerator(.success)`

**Accessibility:**
- Focus order: Headline -> Apple button -> Google button -> Email -> Password -> Create Account -> Skip
- Apple button: `accessibilityLabel("Sign in with Apple")`
- Email field: `accessibilityLabel("Email address")`, `accessibilityHint("Enter your email to create an account")`
- Password visibility toggle: `accessibilityLabel("Show password")` / `accessibilityLabel("Hide password")`
- Error messages: Announced via `UIAccessibility.post(notification: .announcement)`
- Skip link: `accessibilityHint("Skips account creation. You can create an account later in Settings.")`

**Edge cases:**
| Case | Behaviour |
|------|----------|
| Offline | SSO buttons hidden; email form shows "Account creation requires internet. Continue without an account to get started." |
| Apple Sign In — no email shared | Accept; use Apple's relay email. Note in account settings. |
| Existing account (email) | Show "Already have an account? Sign in" link -> sign-in variant of same screen |
| Rate limited | "Too many attempts. Try again in a few minutes." |
| Keyboard covers CTA | ScrollView shifts content up; CTA remains above keyboard |

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_account_viewed` | - |
| `onboarding_account_apple_tapped` | - |
| `onboarding_account_google_tapped` | - |
| `onboarding_account_email_submitted` | `email_valid: Bool` |
| `onboarding_account_created` | `method: "apple" | "google" | "email"`, `time_on_screen_ms: Int` |
| `onboarding_account_skipped` | `time_on_screen_ms: Int` |
| `onboarding_account_error` | `error_type: String`, `method: String` |

---

#### Screen OB-035: Phone Number (Optional)

**Purpose:** Collect phone number for account recovery and optional 2FA. Explicitly optional with clear explanation of use.

**Entry:** After successful account creation (OB-030) — only shown for email sign-ups, not SSO
**Exit:** Submit -> OB-040 (OTP) | "Skip" -> OB-040 (email OTP) or OB-050

**Layout:**
- Full-screen, dark background
- Centred content: icon + headline + phone input + explanation + CTAs
- Country code picker (auto-detected, defaulting to +61 for en-AU)

**Key UI elements:**
| Element | Component |
|---------|-----------|
| Phone icon | `phone.badge.plus` with blue gradient |
| Country picker | Dropdown with flag + code |
| Phone field | `TextField` with phone pad keyboard |
| Explanation card | Info card with lock icon |
| CTA | "Continue" |
| Skip | "Skip — I'll use email only" |

**Microcopy:**
- Headline: "Add a recovery number"
- Subtitle: "Optional. Used only for account recovery and two-factor authentication."
- Field placeholder: "Mobile number"
- Explanation card: "We'll send a one-time code to verify this number. It won't be shared with anyone or used for marketing."
- CTA: "Continue"
- Skip: "Skip — I'll use email only"

**Accessibility:**
- Phone field: `accessibilityLabel("Mobile phone number")`, keyboard type `.phonePad`
- Country picker: `accessibilityLabel("Country code selector, currently Australia plus 61")`

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_phone_viewed` | - |
| `onboarding_phone_submitted` | `country_code: String` |
| `onboarding_phone_skipped` | - |

---

#### Screen OB-040: OTP Verification

**Purpose:** Verify email (or phone) ownership via a 6-digit one-time code.

**Entry:** After account creation (email) or phone submission
**Exit:** Code verified -> OB-050 | Auto-advance on correct code

**Layout:**
- Full-screen, dark background
- Centred: icon + headline + code input + resend link + back link
- Code input: 6 individual digit cells, auto-advance on entry

**Key UI elements:**
| Element | Component | State |
|---------|-----------|-------|
| Mail icon | `envelope.badge.shield.half.filled` with purple gradient | Static |
| OTP cells | 6x `TextField` (single digit each) | Empty / Filled / Error / Success |
| Resend link | Text button with countdown timer | Disabled for 30s, then "Resend code" |
| Back link | "Wrong email?" | Returns to OB-030 |

**Microcopy:**
- Headline: "Check your email"
- Subtitle: "We sent a 6-digit code to **user@example.com**"
- OTP field label: (implicit — cells are self-explanatory)
- Resend (countdown): "Resend code in 0:28"
- Resend (active): "Didn't get it? Resend code"
- Back: "Wrong email? Go back"
- **Error — wrong code:** "That code doesn't match. Check your email and try again."
- **Error — expired:** "This code has expired. We've sent a new one."
- **Error — too many attempts:** "Too many attempts. Please wait 5 minutes."
- **Success:** (auto-advance with success haptic; green checkmark animation on cells)

**Animation specs:**
| Element | Duration | Easing |
|---------|----------|--------|
| Cell focus ring | 200ms | `easeInOut` |
| Error shake (all cells) | 400ms | `spring(0.3, 0.4)` |
| Success checkmark | 300ms | `spring(0.4, 0.65)` |
| Auto-advance to next screen | 800ms delay after success | - |
| **Reduce-motion:** No shake; error text only; success text only |

**Haptics:**
- Each digit entered: `UIImpactFeedbackGenerator(.light)`
- Error: `UINotificationFeedbackGenerator(.error)`
- Success: `UINotificationFeedbackGenerator(.success)`

**Accessibility:**
- OTP cells: Combined `accessibilityLabel("Verification code, 6 digits")` with `.textContentType(.oneTimeCode)` for auto-fill
- Auto-fill from SMS/email should work via iOS `textContentType`
- Resend: `accessibilityLabel("Resend verification code")`, `accessibilityHint("Sends a new code to your email")`

**Edge cases:**
| Case | Behaviour |
|------|----------|
| Paste full code | All 6 cells fill simultaneously; auto-verify |
| Partial paste | Fill from cursor position |
| Offline | "You'll need internet to verify. Check your connection." |
| Code not received (>60s) | Show "Check your spam folder" helper text |
| Multiple resends (>3) | Rate limit: "Too many resend attempts. Wait 5 minutes." |

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_otp_viewed` | `verification_type: "email" | "phone"` |
| `onboarding_otp_submitted` | `attempt_number: Int` |
| `onboarding_otp_verified` | `time_to_verify_ms: Int` |
| `onboarding_otp_resent` | `resend_count: Int` |
| `onboarding_otp_error` | `error_type: String` |

---

### Phase 3: Personalisation

---

#### Screen OB-050: Market Selection

**Purpose:** Set preferred market(s) so the app shows relevant trading hours, currency, and popular symbols.

**Entry:** After OB-040 (verified) or OB-030 (skipped account)
**Exit:** "Continue" -> OB-060

**Layout:**
- Full-screen, dark background
- Globe icon with cyan glow -> headline -> 3 option cards (US / AU / Both) -> CTA
- Cards are radio-select (single selection)

**Key UI elements:**
| Element | Details |
|---------|---------|
| Globe icon | `globe.americas.fill` with cyan/blue gradient, radial glow |
| US option | Flag emoji, "US Markets", "NYSE, NASDAQ, Crypto" |
| AU option | Flag emoji, "Australian Markets", "ASX, Chi-X" |
| Both option | Globe emoji, "Both", "All markets, all sessions" |
| Radio indicator | Circle with inner fill dot on selection |
| CTA | "Continue" |

**Microcopy:**
- Headline: "Which markets do you follow?"
- Subtitle: "We'll show relevant market hours and session data for you."
- CTA: "Continue"

**Animation specs:**
| Element | Duration | Easing | Delay |
|---------|----------|--------|-------|
| Globe scale-in | 600ms | `spring(0.6, 0.78)` | 100ms |
| Content fade + slide | 600ms | `spring(0.6, 0.78)` | 100ms |
| Card stagger | 500ms each | `spring(0.5, 0.8)` | +80ms per card |
| Selection ring | 300ms | `spring(0.3, 0.7)` | - |
| **Reduce-motion:** All elements appear instantly |

**Haptics:**
- Card selection: `UIImpactFeedbackGenerator(.light)`
- CTA tap: `UIImpactFeedbackGenerator(.medium)`

**Persistence:** Saves to `@AppStorage("preferredMarket")` — "US", "AU", or "US" (for Both, with UI handling)

**Accessibility:**
- Focus order: Headline -> US card -> AU card -> Both card -> CTA
- Cards: `accessibilityLabel("US Markets, NYSE NASDAQ Crypto")`, `accessibilityTrait(.isButton)`
- Selected card: `accessibilityAddTraits(.isSelected)`

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_market_viewed` | - |
| `onboarding_market_selected` | `market: "US" | "AU" | "BOTH"` |
| `onboarding_market_completed` | `market: String`, `time_on_screen_ms: Int` |

---

### Phase 4: Watchlist Setup

---

#### Screen OB-060: Watchlist Builder

**Purpose:** Help users add their first watchlist items so the app has immediate value on first launch.

**Entry:** After OB-050
**Exit:** "Continue" (with >= 1 stock) -> OB-070 | "I'll do this later" -> OB-070

**Layout:**
- Full-screen, dark background
- Header section: headline + subtitle
- Tab bar: Watchlist | Broker | Crypto (existing `SetupTabBar`)
- Content area: search field + popular suggestions + added items
- CTAs at bottom: "Continue" (primary, disabled if 0 items) + "I'll do this later" (secondary)

**Key UI elements — Watchlist Tab:**
| Element | Component | State |
|---------|-----------|-------|
| Search field | Glass-style `TextField` | Empty / Focused / Searching |
| Popular stocks | Horizontal scroll of `StockPillButton` | AAPL, GOOGL, MSFT, TSLA, AMZN, NVDA |
| Added counter | "Added (3)" label | Updates on add/remove |
| Added pills | Horizontal scroll of `AddedStockPill` | Symbol + X remove button |
| CTA | `OnboardingButton` | "Continue" (disabled if 0 added) |
| Skip | Text button | "I'll do this later" |

**Key UI elements — Broker Tab:**
| Element | Component |
|---------|-----------|
| Broker list | `OnboardingConnectionCard` for each broker (CommSec, Alpaca, IBKR, Fidelity, Schwab, TD Ameritrade, E*TRADE, Robinhood, Webull) |
| Connection badge | Green success banner after connect |

**Key UI elements — Crypto Tab:**
| Element | Component |
|---------|-----------|
| Exchange list | `OnboardingConnectionCard` for each exchange (Coinbase, Kraken, Binance, Binance US, Gemini, CoinSpot, CoinJar) |
| Connection badge | Green success banner after connect |

**Microcopy:**
- Headline: "Build your portfolio"
- Subtitle: "Pick stocks to watch, or connect your brokerage or crypto exchange"
- Search placeholder: "Search stocks or funds"
- Popular label: "Popular stocks"
- Added label: "Added (N)"
- CTA: "Continue"
- Skip: "I'll do this later"
- Broker connected: "Broker connected! Your holdings will sync automatically when you open the app."
- Crypto connected: "Exchange connected! Your crypto will sync automatically when you open the app."

**Post-watchlist success moment:** When first stock is added, brief confetti-like particle burst from the pill (6 small circles, 300ms, fade out). Haptic: `UINotificationFeedbackGenerator(.success)`.

**Suggestions logic:**
- If market == AU: Show BHP.AX, CBA.AX, CSL.AX, NAB.AX, WBC.AX, ANZ.AX first
- If market == US: Show AAPL, GOOGL, MSFT, TSLA, AMZN, NVDA
- If market == Both: Show mix of both

**Edge cases:**
| Case | Behaviour |
|------|----------|
| Search returns 0 results | "No results for '[query]'. Check the symbol or try another." |
| Offline | Search disabled; show popular pills only with note "Search requires internet" |
| Broker connect error | Alert: "Connection Error" with dismiss button |
| SnapTrade loading | Full-screen overlay with spinner + loading message |

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_watchlist_viewed` | `tab: String` |
| `onboarding_stock_added` | `symbol: String`, `source: "search" | "suggestion"` |
| `onboarding_stock_removed` | `symbol: String` |
| `onboarding_broker_connected` | `broker: String` |
| `onboarding_exchange_connected` | `exchange: String` |
| `onboarding_watchlist_completed` | `stock_count: Int`, `broker_connected: Bool`, `crypto_connected: Bool` |
| `onboarding_watchlist_skipped` | - |

---

### Phase 5: Portfolio Setup

---

#### Screen OB-070: Portfolio Add Flow

**Purpose:** Help users enter their first portfolio holdings via manual entry, CSV import, or broker sync.

**Entry:** After OB-060 (if user has added watchlist items)
**Exit:** "Continue" -> OB-080 | "I'll do this later" -> OB-080

**Layout:**
- Full-screen, dark background
- Header: briefcase icon + headline
- Three method cards: Manual Entry | CSV Upload | Broker Import
- Each card expands inline when tapped
- CTAs at bottom

**Key UI elements:**
| Element | Component | State |
|---------|-----------|-------|
| Manual entry card | Briefcase icon + "Add manually" | Collapsed / Expanded (shows symbol + shares + cost fields) |
| CSV upload card | Doc icon + "Import CSV" | Collapsed / Expanded (shows file picker) |
| Broker sync card | Building icon + "Connect broker" | Collapsed / Redirect to broker OAuth |

**Microcopy:**
- Headline: "Add your holdings"
- Subtitle: "See your real portfolio value. You can always add more later."
- Manual card: "Add manually" / "Enter your stock positions one by one"
- CSV card: "Import from CSV" / "Upload a spreadsheet from your broker"
- Broker card: "Connect your broker" / "Automatically sync your holdings (read-only)"
- **CSV format note:** "Expected columns: Symbol, Shares, Average Cost. We support exports from CommSec, Sharesight, and most brokers."
- **CSV error — parse failure:** "We couldn't read some rows. Review the issues below."
- **CSV error — no valid rows:** "No valid holdings found. Check the file format and try again."
- **Broker trust note:** "Connections are read-only. We can see your positions but can never place trades or move funds."
- CTA: "Continue"
- Skip: "I'll do this later"

**Manual entry fields:**
| Field | Keyboard | Validation |
|-------|----------|-----------|
| Symbol | `.characters` (auto-cap) | Required, max 10 chars |
| Shares | `.decimalPad` | Required, > 0 |
| Average cost | `.decimalPad` | Required, > 0 |

**CSV import flow:**
1. User taps "Import CSV" -> system file picker (`.csv` UTType)
2. App parses file; shows progress indicator
3. **Success:** "12 holdings imported" with green checkmark
4. **Partial failure:** "10 of 12 rows imported. 2 issues found." + expandable issue list
5. **Full failure:** "Couldn't parse this file." + format help

**CSV issue review UX:**
- Each issue row shows: row number, raw text, error description
- User can dismiss individual issues or "Import valid rows only"
- Example issue: "Row 5: 'GOOGL' — missing share count"

**Edge cases:**
| Case | Behaviour |
|------|----------|
| Large CSV (>500 rows) | Show progress bar; warn "This may take a moment" |
| Duplicate symbols in CSV | Merge into single holding (sum shares, weighted avg cost) |
| Unknown symbols in CSV | Import with warning badge; user can resolve later |
| CSV encoding issues | Try UTF-8, then Latin-1 fallback |

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_portfolio_viewed` | - |
| `onboarding_portfolio_manual_added` | `symbol: String` |
| `onboarding_portfolio_csv_imported` | `total_rows: Int`, `valid_rows: Int`, `error_rows: Int` |
| `onboarding_portfolio_broker_connected` | `broker: String` |
| `onboarding_portfolio_completed` | `holding_count: Int`, `method: String` |
| `onboarding_portfolio_skipped` | - |

---

### Phase 6: Permissions

---

#### Screen OB-080: Notification Permission

**Purpose:** Request notification permission with clear value proposition (price alerts).

**Entry:** After OB-070 or OB-060 (if portfolio skipped)
**Exit:** "Enable Price Alerts" -> OS prompt -> OB-090 | "Not now" -> OB-090

**Layout:**
- Full-screen, dark background
- Bell icon with purple glow + ring animation
- Mock notification card (existing `AlertNotificationCard`)
- Headline + subtitle
- Fine print about refresh frequency
- CTAs: "Enable Price Alerts" (primary) + "Not now" (secondary)

**Key UI elements:**
| Element | Component |
|---------|-----------|
| Bell icon | `bell.fill` with purple gradient, radial glow, ring animation |
| Notification preview | `AlertNotificationCard` — mock push notification |
| Headline | "Stay informed, not overwhelmed" |
| Fine print | "Prices refresh every 15 min while markets are open." |
| CTA | "Enable Price Alerts" |
| Skip | "Not now" |

**Microcopy:**
- Headline: "Stay informed, not overwhelmed"
- Subtitle: "Get alerts only when prices hit your targets. No spam, no noise."
- CTA: "Enable Price Alerts"
- Skip: "Not now"
- Fine print: "Prices refresh every 15 min while markets are open."
- Mock notification: "AAPL reached $180 — your target price"

**Pre-prompt -> OS prompt flow:**
1. User taps "Enable Price Alerts"
2. App calls `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])`
3. OS prompt appears
4. Regardless of grant/deny, proceed to OB-090

**If user taps "Not now":** Skip OS prompt entirely. A contextual prompt will appear later when user creates their first price alert.

**Animation specs:**
| Element | Duration | Easing | Delay |
|---------|----------|--------|-------|
| Bell spring-in | 650ms | `spring(0.65, 0.70)` | 100ms |
| Bell ring (3 rocks) | 880ms total | `spring(0.22, 0.45)` | 650ms |
| Notification card slide-up | 600ms | `spring(0.60, 0.80)` | 1300ms |
| Content fade | 550ms | `easeOut` | 1000ms |
| **Reduce-motion:** All elements instant; no bell ring |

**Haptics:**
- Bell ring: `UIImpactFeedbackGenerator(.light)` x3 at ring peaks
- CTA tap: `UIImpactFeedbackGenerator(.medium)`

**Accessibility:**
- Bell animation: `accessibilityHidden(true)` (decorative)
- Notification preview: `accessibilityLabel("Example notification: AAPL reached 180 dollars, your target price")`
- CTA: `accessibilityHint("Opens the system notification permission dialog")`
- Skip: `accessibilityHint("Skips notification setup. You can enable notifications later in Settings.")`

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_notifications_viewed` | - |
| `onboarding_notifications_enabled` | `granted: Bool` |
| `onboarding_notifications_skipped` | - |

---

#### Screen OB-090: Biometrics (App Lock)

**Purpose:** Offer Face ID/Touch ID app lock after user has data worth protecting.

**Entry:** After OB-080 (only if user created account OR added watchlist items)
**Exit:** "Enable Face ID" -> OS biometric prompt -> OB-100 | "Not now" -> OB-100

**Layout:**
- Full-screen, dark background
- Face ID icon with green glow
- Headline + subtitle
- Privacy note card
- CTAs

**Key UI elements:**
| Element | Component |
|---------|-----------|
| Biometric icon | `faceid` (or `touchid` on older devices) with green gradient |
| Headline | "Protect your portfolio" |
| Privacy card | Lock icon + "Your data stays on this device..." |
| CTA | "Enable Face ID" / "Enable Touch ID" |
| Skip | "Not now" |

**Microcopy:**
- Headline: "Protect your portfolio"
- Subtitle: "Lock the app so only you can see your investments."
- Privacy note: "Your biometric data stays on your device. Stock Tracker never stores or transmits it."
- CTA: "Enable Face ID" (dynamic based on `LAContext.biometryType`)
- Skip: "Not now"
- **No biometrics available:** Skip this screen entirely

**Flow:**
1. Check `LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` on appear
2. If not available, auto-skip to OB-100
3. If available, show screen
4. On CTA tap: set `UserDefaults.standard.useBiometrics = true` + evaluate policy
5. Proceed regardless of result

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_biometrics_viewed` | `biometry_type: "faceID" | "touchID"` |
| `onboarding_biometrics_enabled` | `biometry_type: String` |
| `onboarding_biometrics_skipped` | - |

---

### Phase 7: Completion

---

#### Screen OB-100: Onboarding Complete

**Purpose:** Celebrate completion; transition to main app with a success moment.

**Entry:** After OB-090 (or OB-080 if biometrics skipped)
**Exit:** Auto-dismiss after 2s -> Main App | Tap anywhere -> Main App

**Layout:**
- Full-screen, dark background
- Large checkmark animation -> "You're all set" headline -> summary stats
- Auto-dismiss after 2 seconds

**Key UI elements:**
| Element | Component |
|---------|-----------|
| Success checkmark | Animated circle + checkmark path draw |
| Headline | "You're all set" |
| Summary | "N stocks on your watchlist" / "Portfolio tracking enabled" |
| Subtle text | "Tap to continue" |

**Microcopy:**
- Headline: "You're all set"
- Summary (dynamic): "5 stocks on your watchlist" or "Portfolio connected via CommSec" or "Watchlist ready — add stocks anytime"
- Tap hint: "Tap anywhere to continue"

**Animation specs:**
| Element | Duration | Easing | Delay |
|---------|----------|--------|-------|
| Circle draw | 500ms | `easeOut` | 0ms |
| Checkmark draw | 300ms | `spring(0.3, 0.6)` | 400ms |
| Text fade | 400ms | `easeOut` | 600ms |
| Auto-dismiss | - | `easeOut(0.6)` | 2000ms |
| **Reduce-motion:** Static checkmark + text, no draw animation |

**Haptics:** `UINotificationFeedbackGenerator(.success)` on appear

**Persistence:** Sets `UserDefaults.standard.hasCompletedOnboarding = true`

**Analytics:**
| Event | Properties |
|-------|-----------|
| `onboarding_completed` | `total_time_ms: Int`, `screens_viewed: Int`, `screens_skipped: Int`, `account_created: Bool`, `method: String?`, `watchlist_count: Int`, `portfolio_count: Int`, `notifications_enabled: Bool`, `biometrics_enabled: Bool`, `market: String` |

---

### Phase 8: Post-Onboarding Feature Discovery

---

#### Screen OB-110: Contextual Coach Marks (Deferred)

**Purpose:** Guide users to key features after they've started using the app. Not shown during onboarding — triggered by user actions in the main app.

**Trigger conditions:**
| Coach Mark | Trigger | Shows on |
|-----------|---------|----------|
| "Set a price alert" | User views stock detail for 3rd time | Stock detail view, pointing at bell icon |
| "Swipe to add to portfolio" | User has 5+ watchlist items, 0 portfolio items | Watchlist row, edge hint |
| "Try AI insights" | User is Pro/Black, hasn't used AI after 3 sessions | AI tab, tab bar highlight |
| "Customise your watchlist" | User has 10+ items | Watchlist header, pointing at edit button |
| "Explore chart timeframes" | User taps a chart for 2nd time | Chart area, pointing at time range pills |

**Design:**
- Spotlight overlay (dimmed background, cutout around target)
- Tooltip card below/above target
- "Got it" dismiss button
- Shown once per coach mark (flag stored in UserDefaults)
- Respects `accessibilityReduceMotion`: spotlight appears instantly

**Microcopy examples:**
- Alert nudge: "Set a price alert and we'll notify you when it hits your target."
- Portfolio swipe: "Swipe left on any stock to quickly add it to your portfolio."
- AI: "Ask our AI assistant about your portfolio performance."

**Analytics:**
| Event | Properties |
|-------|-----------|
| `coach_mark_shown` | `mark_id: String`, `trigger: String` |
| `coach_mark_dismissed` | `mark_id: String`, `time_visible_ms: Int` |

---

## 5. Design System Tokens

### Colour Palette

#### Light Mode (existing Theme struct)
| Token | Hex | Usage |
|-------|-----|-------|
| `background` | `#FAF8F5` (Antique white) | Primary background |
| `secondaryBackground` | `#F3EFE8` | Cards, grouped sections |
| `cardBackground` | `#EDE8E0` | Elevated cards |
| `primaryText` | System `.label` | Headlines, body |
| `secondaryText` | System `.secondaryLabel` | Captions, hints |
| `separator` | System `.separator` | Dividers |

#### Dark Mode (existing Theme struct)
| Token | Hex | Usage |
|-------|-----|-------|
| `background` | System `.systemBackground` | Primary background |
| `secondaryBackground` | System `.secondarySystemBackground` | Cards |
| `cardBackground` | System `.secondarySystemGroupedBackground` | Elevated cards |
| `primaryText` | System `.label` | Headlines, body |
| `secondaryText` | System `.secondaryLabel` | Captions, hints |

#### Onboarding-Specific (dark-only)
| Token | Hex | Usage |
|-------|-----|-------|
| `onboardingBackground` | `#000000` | Onboarding screens |
| `onboardingGlow` | Varies per screen (blue/green/cyan/purple) | Radial gradient background |
| `onboardingCardBg` | `rgba(255,255,255,0.07)` | Feature cards, input containers |
| `onboardingCardBorder` | `rgba(255,255,255,0.09)` | Card stroke (1px) |

#### Semantic Colours
| Token | Standard | Deuteranopia | Protanopia |
|-------|---------|-------------|-----------|
| `positive` | `#40E080` | `#4A90D9` (Blue) | `#4A90D9` (Blue) |
| `negative` | `#FF5C5C` | `#FF8C00` (Orange) | `#FFD700` (Yellow) |
| `warning` | System `.orange` | System `.orange` | System `.orange` |
| `accent` | System `.blue` | System `.blue` | System `.blue` |
| `neutral` | System `.gray` | System `.gray` | System `.gray` |

**Colour-blind safety:** All gain/loss indicators use dual encoding via `GainLossIndicator` (existing): colour + directional arrow icon (`arrow.up.right` / `arrow.down.right`).

### Typography Scale

| Semantic Style | iOS | Android | Usage |
|---------------|-----|---------|-------|
| `displayLarge` | `.system(size: 52, weight: .bold, design: .rounded)` | `displayLarge` (57sp) | Portfolio counter |
| `headline1` | `.system(size: 34, weight: .bold, design: .rounded)` | `headlineLarge` (32sp) | Screen headlines |
| `headline2` | `.system(size: 30, weight: .bold, design: .rounded)` | `headlineMedium` (28sp) | Section headers |
| `title` | `.title3.bold()` | `titleLarge` (22sp) | Card titles |
| `body` | `.body` | `bodyLarge` (16sp) | Descriptions |
| `subheadline` | `.subheadline` | `bodyMedium` (14sp) | Secondary text |
| `caption` | `.caption` | `bodySmall` (12sp) | Labels, helper text |
| `caption2` | `.caption2` | `labelSmall` (11sp) | Fine print |
| `monoDigit` | `.monospacedDigit()` modifier | `Roboto Mono` | Prices, OTP cells |

### Iconography

| Usage | iOS (SF Symbols) | Android (Material) |
|-------|-----------------|-------------------|
| Watchlist | `chart.line.uptrend.xyaxis` | `show_chart` |
| Portfolio | `briefcase.fill` | `work` |
| AI | `sparkles` | `auto_awesome` |
| Settings | `gearshape.fill` | `settings` |
| Alert/Bell | `bell.fill` | `notifications` |
| Lock | `lock.fill` | `lock` |
| Shield | `lock.shield.fill` | `security` |
| Search | `magnifyingglass` | `search` |
| Globe | `globe.americas.fill` | `public` |
| Plus | `plus.circle.fill` | `add_circle` |
| Check | `checkmark.circle.fill` | `check_circle` |
| Close | `xmark.circle.fill` | `cancel` |
| Arrow up-right | `arrow.up.right` | `trending_up` |
| Arrow down-right | `arrow.down.right` | `trending_down` |
| Face ID | `faceid` | (custom biometric icon) |

### Spacing System (4pt / 8pt grid)

| Token | Value | Usage |
|-------|-------|-------|
| `space-xs` | 4pt | Inline spacing, icon-to-label gaps |
| `space-sm` | 8pt | Tight element spacing |
| `space-md` | 12pt | Standard element spacing |
| `space-lg` | 16pt | Card padding, section gaps |
| `space-xl` | 24pt | Major section spacing |
| `space-2xl` | 32pt | Screen-level padding |
| `space-3xl` | 40pt | Horizontal CTA padding |
| `space-4xl` | 60pt | CTA bottom padding (above home indicator) |

### Component Radii

| Token | Value | Usage |
|-------|-------|-------|
| `radius-sm` | 6pt | Small pills, badges |
| `radius-md` | 14pt | Input fields, small cards |
| `radius-lg` | 16pt | Standard cards |
| `radius-xl` | 18pt | Option cards, notification preview |
| `radius-2xl` | 20pt | Pill buttons, stock pills |
| `radius-3xl` | 24pt | Feature cards |

### Elevation / Shadows

| Token | Values | Usage |
|-------|--------|-------|
| `shadow-glow` | `color: accent.opacity(0.14), radius: 32, y: 10` | Feature cards |
| `shadow-cta` | `color: blue.opacity(0.4), radius: 15, y: 8` | CTA buttons |
| `shadow-badge` | `color: green.opacity(0.35), radius: 14` | Price badges |
| `shadow-notification` | `color: black.opacity(0.25), radius: 20, y: 8` | Mock notification card |

### Motion Tokens

| Token | Duration | Easing | Usage |
|-------|----------|--------|-------|
| `motion-instant` | 0ms | - | Reduce-motion fallback |
| `motion-fast` | 200ms | `easeInOut` | Micro-interactions (button press, toggle) |
| `motion-normal` | 300-400ms | `spring(0.3, 0.7)` | Page dots, selection changes |
| `motion-entrance` | 550ms | `spring(0.55, 0.82)` | Screen content fade-in |
| `motion-chart` | 1650ms | `easeInOut` | Chart draw animation |
| `motion-celebration` | 450ms | `spring(0.45, 0.60)` | Badge pop-in, checkmark |
| `motion-ring` | 220ms per rock | `spring(0.22, 0.45)` | Bell ring |

**Reduce-motion:** All animated properties snap to their final values. `@Environment(\.accessibilityReduceMotion)` checked on every animated view. Uses existing `motionSafeWithAnimation()` utility.

---

## 6. Analytics Plan

### Event Taxonomy

Prefix: `onboarding_` for all events during onboarding flow.

**Standard properties on ALL events:**
```json
{
  "session_id": "uuid",
  "user_id": "uuid | null",
  "platform": "ios | android",
  "app_version": "1.0.0",
  "os_version": "18.0",
  "device_model": "iPhone16,2",
  "onboarding_variant": "guided",
  "screen_id": "OB-030",
  "timestamp_iso": "2026-03-19T10:30:00+11:00"
}
```

### Per-Screen Event Summary

| Screen | View Event | Action Events |
|--------|-----------|--------------|
| OB-010 Splash | `app_launched` | - |
| OB-020 Welcome | `onboarding_welcome_viewed` | `onboarding_welcome_cta_tapped` |
| OB-025 Features | `onboarding_features_viewed` | `onboarding_features_skipped`, `onboarding_features_completed` |
| OB-030 Account | `onboarding_account_viewed` | `onboarding_account_created`, `onboarding_account_skipped`, `onboarding_account_error` |
| OB-035 Phone | `onboarding_phone_viewed` | `onboarding_phone_submitted`, `onboarding_phone_skipped` |
| OB-040 OTP | `onboarding_otp_viewed` | `onboarding_otp_verified`, `onboarding_otp_resent`, `onboarding_otp_error` |
| OB-050 Market | `onboarding_market_viewed` | `onboarding_market_completed` |
| OB-060 Watchlist | `onboarding_watchlist_viewed` | `onboarding_stock_added`, `onboarding_stock_removed`, `onboarding_broker_connected`, `onboarding_watchlist_completed`, `onboarding_watchlist_skipped` |
| OB-070 Portfolio | `onboarding_portfolio_viewed` | `onboarding_portfolio_manual_added`, `onboarding_portfolio_csv_imported`, `onboarding_portfolio_completed`, `onboarding_portfolio_skipped` |
| OB-080 Notifications | `onboarding_notifications_viewed` | `onboarding_notifications_enabled`, `onboarding_notifications_skipped` |
| OB-090 Biometrics | `onboarding_biometrics_viewed` | `onboarding_biometrics_enabled`, `onboarding_biometrics_skipped` |
| OB-100 Complete | `onboarding_completed` | - |

### Funnel Definition

```
onboarding_welcome_viewed
  -> onboarding_features_viewed (or skipped)
    -> onboarding_account_viewed
      -> onboarding_account_created | onboarding_account_skipped
        -> onboarding_market_completed
          -> onboarding_watchlist_completed | onboarding_watchlist_skipped
            -> onboarding_portfolio_completed | onboarding_portfolio_skipped
              -> onboarding_notifications_enabled | onboarding_notifications_skipped
                -> onboarding_completed
```

### Key Metrics

| Metric | Definition | Target |
|--------|-----------|--------|
| Onboarding completion rate | `onboarding_completed` / `onboarding_welcome_viewed` | > 70% |
| Account creation rate | `onboarding_account_created` / `onboarding_account_viewed` | > 40% |
| Watchlist activation rate | Users with >= 1 stock at completion | > 60% |
| Portfolio activation rate | Users with >= 1 holding at completion | > 25% |
| Notification opt-in rate | `onboarding_notifications_enabled` / `onboarding_notifications_viewed` | > 45% |
| Time to complete | Median `total_time_ms` in `onboarding_completed` | < 180s |
| Drop-off screen | Screen with highest exit rate | Identify and iterate |

---

## 7. Experimentation Plan (A/B Tests)

### Test 1: Account creation placement

**Hypothesis:** Moving account creation after watchlist setup (value-first) will increase overall completion rate because users have already invested time.
**Variants:** A) Account before watchlist (current spec) | B) Account after watchlist | C) Account deferred to post-onboarding
**Primary metric:** `onboarding_completed` rate
**Guardrail metrics:** Account creation rate, D7 retention
**Segment:** All new users

### Test 2: Watchlist pre-population

**Hypothesis:** Pre-selecting 3-5 popular stocks (with opt-out) will increase watchlist activation rate vs starting empty.
**Variants:** A) Empty state + suggestions | B) 5 pre-selected stocks (user can remove)
**Primary metric:** Watchlist items at D1
**Guardrail metrics:** Onboarding completion rate, satisfaction (in-app rating prompt)
**Segment:** All new users

### Test 3: Feature tour format

**Hypothesis:** A single auto-playing carousel is faster than the current 3-card swipeable tour and reduces drop-off.
**Variants:** A) Swipeable cards (current) | B) Auto-play with 3s per slide | C) No feature tour (straight to setup)
**Primary metric:** Time on feature tour screen
**Guardrail metrics:** Onboarding completion rate, feature discovery coach mark engagement
**Segment:** All new users

### Test 4: SSO prominence

**Hypothesis:** Making Apple/Google SSO the only visible options initially (with "Use email instead" expandable) will increase account creation rate.
**Variants:** A) All options visible (current spec) | B) SSO only, email hidden behind link
**Primary metric:** Account creation rate
**Guardrail metrics:** Email sign-up rate, support tickets
**Segment:** All new users

### Test 5: Notification timing

**Hypothesis:** Showing notification permission after user adds first price alert (contextual) will yield higher opt-in than during onboarding.
**Variants:** A) During onboarding (current) | B) Deferred to first price alert creation
**Primary metric:** Notification opt-in rate
**Guardrail metrics:** Price alert creation rate, D7 notification opt-in
**Segment:** All new users

### Test 6: Onboarding length

**Hypothesis:** Minimal 4-screen onboarding (variant A) will have higher completion but lower D7 activation than the full 8-screen guided flow.
**Variants:** A) Minimal (4 screens) | B) Guided (8 screens)
**Primary metric:** D7 retention
**Guardrail metrics:** Onboarding completion rate, watchlist count at D1
**Segment:** Split 50/50

### Test 7: Market selection default

**Hypothesis:** Auto-detecting locale (AU users -> AU market) and confirming rather than asking will reduce screen time without reducing satisfaction.
**Variants:** A) Three-choice selection (current) | B) "We've set you to Australian Markets" with change link
**Primary metric:** Time on market screen
**Guardrail metrics:** Market preference changes in settings (D7)
**Segment:** AU locale users

### Test 8: CTA copy

**Hypothesis:** Action-oriented CTA copy ("Add your first stock") outperforms generic ("Continue") for watchlist setup.
**Variants:** A) "Continue" | B) "Add your first stock" | C) "Let's go"
**Primary metric:** Watchlist items added during onboarding
**Guardrail metrics:** Onboarding completion rate
**Segment:** All new users

### Test 9: Portfolio setup inclusion

**Hypothesis:** Including portfolio setup in onboarding increases D7 portfolio usage but may decrease onboarding completion.
**Variants:** A) Portfolio in onboarding (current) | B) Portfolio deferred to main app coach mark
**Primary metric:** D7 portfolio feature usage
**Guardrail metrics:** Onboarding completion rate
**Segment:** All new users

### Test 10: Social proof on welcome

**Hypothesis:** Adding "Join 50,000+ Australian investors" to the welcome screen increases "Get Started" tap rate.
**Variants:** A) Current welcome (no social proof) | B) With investor count badge
**Primary metric:** Welcome -> next screen conversion rate
**Guardrail metrics:** Time on welcome screen
**Segment:** All new users
**Note:** Only test with real, verifiable numbers. Fake numbers are a dark pattern.

---

## 8. Privacy / Security Microcopy Pack

### Watchlist / Portfolio Data

| Context | Copy |
|---------|------|
| Account creation screen | "Your data is encrypted and stored securely. We never sell your information." |
| Broker connect (trust) | "Connections are read-only. We can see your positions but can never place trades or move funds." |
| CSV import | "Your file is processed on-device. We don't upload or store the original CSV." |
| Cloud sync explanation | "Sync keeps your watchlist and portfolio backed up. Data is encrypted in transit and at rest." |
| Data deletion | "You can delete your account and all associated data at any time in Settings." |

### Notification Safety

| Context | Copy |
|---------|------|
| Pre-prompt | "Get alerts only when prices hit your targets. No spam, no noise." |
| Content safety note | "Notifications show stock symbols and price levels. No account balances or portfolio values are shown in notifications." |
| Settings description | "We send push notifications for price alerts and market events you've opted in to. Nothing else." |

### Import / Connect Trust

| Context | Copy |
|---------|------|
| Broker connect detail | "We use SnapTrade to securely connect to your broker. The connection is read-only — Stock Tracker can view your positions but cannot execute trades, transfer funds, or modify your account." |
| Broker data note | "Your broker credentials are handled by SnapTrade and never stored on our servers." |
| CSV upload | "Your spreadsheet is parsed locally on your device. The file is not uploaded to any server." |

### Analytics Transparency

| Context | Copy |
|---------|------|
| Settings -> Privacy | "We collect anonymous usage data to improve the app. This includes which features you use and how often, but never your portfolio values, holdings, or personal details." |
| First launch (if analytics opt-in required) | "Help us improve Stock Tracker by sharing anonymous usage data. You can change this anytime in Settings." |

### Biometrics

| Context | Copy |
|---------|------|
| Biometrics prompt | "Your biometric data stays on your device. Stock Tracker never stores or transmits it." |
| Settings toggle | "When enabled, Face ID is required to open the app. Your biometric data never leaves your device." |

---

## 9. Localisation Notes

### en-AU Specifics

| Category | en-AU Convention | Implementation |
|---------|-----------------|----------------|
| Currency | AUD ($) by default | `preferredCurrency` defaults to "AUD" if locale is en-AU |
| Date format | DD/MM/YYYY | Use `DateFormatter.dateStyle = .medium` with locale |
| Number format | 1,000.00 (comma thousands, dot decimal) | Standard en-AU locale |
| Market terminology | "ASX", "CommSec", "Chi-X" are familiar | Prioritise AU brokers in AU locale |
| Spelling | "colour", "favourite", "analyse" | Use en-AU string variants |
| Time zone | AEST/AEDT | Auto-detect; show market hours in local time |
| Popular symbols | BHP.AX, CBA.AX, CSL.AX | Show AU symbols first for AU locale |

### Translation Readiness

| Concern | Guidance |
|---------|---------|
| String length | German/French expand ~30%. Allow 40% expansion room. Use `minimumScaleFactor(0.8)` on constrained text. |
| Pluralisation | Use iOS `.stringsdict` / Android `plurals.xml`. Example: "1 stock" vs "5 stocks". Already prepared in `Localizable.xcstrings`. |
| RTL support | All layout uses `leading`/`trailing` (not `left`/`right`). `HStack` respects RTL automatically. Test with Arabic/Hebrew pseudo-locale. |
| Market symbols | Ticker symbols are NOT localised. "AAPL" is "AAPL" everywhere. Exchange names may vary (e.g., "Bourse" for French stock exchange). |
| Number formatting | Use `NumberFormatter` with device locale. Don't hardcode decimal separators. |
| Currency | Always use `Locale.current.currencyCode` for default. Prices should use `currencyCode` from the asset's exchange. |
| Date/time | All dates via `Date.FormatStyle` or `DateFormatter` with locale. Never hardcode format strings. |
| Button text | Keep CTAs short (max 20 chars en-AU). Test with longest expected translation. |
| Legal text | Privacy policy and terms must be professionally translated, not machine-translated. |

### String Keys (sample)

```
"onboarding.welcome.title" = "Invest with Clarity";
"onboarding.welcome.subtitle" = "Track every position. See every move.\nAll in one place.";
"onboarding.welcome.cta" = "Get Started";
"onboarding.account.title" = "Secure your portfolio";
"onboarding.account.subtitle" = "Sign in to sync your data across devices and keep your watchlist safe.";
"onboarding.account.skip" = "Continue without an account";
"onboarding.market.title" = "Which markets do you follow?";
"onboarding.notifications.title" = "Stay informed, not overwhelmed";
"onboarding.notifications.cta" = "Enable Price Alerts";
"onboarding.notifications.skip" = "Not now";
"onboarding.complete.title" = "You're all set";
```

---

## 10. Developer Handoff JSON

### JSON Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "OnboardingScreen",
  "type": "object",
  "required": ["id", "name", "purpose", "phase", "layout", "components", "copy", "states", "analytics", "accessibility", "motion"],
  "properties": {
    "id": { "type": "string", "pattern": "^OB-\\d{3}$" },
    "name": { "type": "string" },
    "purpose": { "type": "string" },
    "phase": { "type": "string", "enum": ["launch", "account", "personalisation", "setup", "permissions", "completion", "discovery"] },
    "entry": { "type": "string" },
    "exit": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "action": { "type": "string" },
          "target": { "type": "string" },
          "condition": { "type": "string" }
        }
      }
    },
    "layout": {
      "type": "object",
      "properties": {
        "background": { "type": "string" },
        "orientation": { "type": "string", "enum": ["portrait", "landscape", "both"] },
        "scrollable": { "type": "boolean" },
        "safeArea": { "type": "string" },
        "stickyElements": { "type": "array", "items": { "type": "string" } }
      }
    },
    "components": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "type": { "type": "string" },
          "props": { "type": "object" },
          "states": { "type": "array", "items": { "type": "string" } }
        }
      }
    },
    "copy": {
      "type": "object",
      "properties": {
        "title": { "type": "string" },
        "subtitle": { "type": "string" },
        "primaryCTA": { "type": "string" },
        "secondaryCTA": { "type": "string" },
        "errors": { "type": "object" },
        "helpers": { "type": "object" }
      }
    },
    "states": {
      "type": "object",
      "properties": {
        "default": { "type": "string" },
        "loading": { "type": "string" },
        "error": { "type": "string" },
        "empty": { "type": "string" },
        "offline": { "type": "string" }
      }
    },
    "analytics": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "event": { "type": "string" },
          "trigger": { "type": "string" },
          "properties": { "type": "object" }
        }
      }
    },
    "accessibility": {
      "type": "object",
      "properties": {
        "focusOrder": { "type": "array", "items": { "type": "string" } },
        "labels": { "type": "object" },
        "hints": { "type": "object" },
        "traits": { "type": "object" }
      }
    },
    "motion": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "element": { "type": "string" },
          "trigger": { "type": "string" },
          "duration_ms": { "type": "integer" },
          "easing": { "type": "string" },
          "delay_ms": { "type": "integer" },
          "reduceMotionFallback": { "type": "string" }
        }
      }
    }
  }
}
```

### Sample Screen Definitions (8 screens)

```json
[
  {
    "id": "OB-010",
    "name": "Splash",
    "purpose": "Brand moment during cold launch initialisation",
    "phase": "launch",
    "entry": "App cold start",
    "exit": [
      { "action": "auto_dismiss", "target": "OB-020", "condition": "!hasCompletedOnboarding" },
      { "action": "auto_dismiss", "target": "MainApp", "condition": "hasCompletedOnboarding" }
    ],
    "layout": {
      "background": "theme.background",
      "orientation": "portrait",
      "scrollable": false,
      "safeArea": "all",
      "stickyElements": []
    },
    "components": [
      { "id": "app_icon", "type": "SFSymbol", "props": { "name": "chart.line.uptrend.xyaxis", "weight": "thin", "size": 60 }, "states": ["default"] },
      { "id": "app_name", "type": "Text", "props": { "text": "Stock Tracker", "style": "headline2" }, "states": ["default"] }
    ],
    "copy": { "title": "Stock Tracker", "subtitle": null, "primaryCTA": null, "secondaryCTA": null, "errors": {}, "helpers": {} },
    "states": { "default": "Show icon and name centred", "loading": "Same as default (initialisation happens silently)", "error": "N/A", "empty": "N/A", "offline": "Same as default" },
    "analytics": [
      { "event": "app_launched", "trigger": "onAppear", "properties": { "is_first_launch": "Bool", "app_version": "String" } }
    ],
    "accessibility": {
      "focusOrder": [],
      "labels": { "app_icon": "Stock Tracker app icon" },
      "hints": {},
      "traits": {}
    },
    "motion": [
      { "element": "app_icon", "trigger": "onAppear", "duration_ms": 600, "easing": "easeIn", "delay_ms": 0, "reduceMotionFallback": "instant" },
      { "element": "app_name", "trigger": "onAppear", "duration_ms": 600, "easing": "easeIn", "delay_ms": 200, "reduceMotionFallback": "instant" }
    ]
  },
  {
    "id": "OB-020",
    "name": "Welcome Hero",
    "purpose": "Emotional hook showing portfolio value promise",
    "phase": "launch",
    "entry": "After splash, first launch only",
    "exit": [
      { "action": "tap_cta", "target": "OB-025", "condition": "always" }
    ],
    "layout": {
      "background": "Color.black + radialGradient(blue, 0.24)",
      "orientation": "portrait",
      "scrollable": false,
      "safeArea": "all",
      "stickyElements": ["primary_cta"]
    },
    "components": [
      { "id": "value_counter", "type": "AnimatedCounter", "props": { "target": 47284.50, "format": "currency_usd", "duration_ms": 1650 }, "states": ["animating", "complete"] },
      { "id": "change_badge", "type": "Badge", "props": { "text": "+$1,284 (2.79%) today", "color": "positive", "icon": "arrow.up.right" }, "states": ["default"] },
      { "id": "chart_canvas", "type": "WelcomeChartCanvas", "props": { "dataPoints": "catmullRom", "drawDuration_ms": 1650 }, "states": ["drawing", "complete"] },
      { "id": "price_badge", "type": "WelcomePriceBadge", "props": { "text": "+2.79%" }, "states": ["hidden", "visible"] },
      { "id": "headline", "type": "Text", "props": { "text": "onboarding.welcome.title", "style": "headline1" }, "states": ["default"] },
      { "id": "subtitle", "type": "Text", "props": { "text": "onboarding.welcome.subtitle", "style": "body", "opacity": 0.52 }, "states": ["default"] },
      { "id": "primary_cta", "type": "OnboardingButton", "props": { "title": "onboarding.welcome.cta" }, "states": ["default", "pressed"] }
    ],
    "copy": {
      "title": "Invest with Clarity",
      "subtitle": "Track every position. See every move.\nAll in one place.",
      "primaryCTA": "Get Started",
      "secondaryCTA": null,
      "errors": {},
      "helpers": {}
    },
    "states": {
      "default": "Animated entrance sequence plays",
      "loading": "N/A",
      "error": "N/A",
      "empty": "N/A",
      "offline": "Same as default (no network needed)"
    },
    "analytics": [
      { "event": "onboarding_welcome_viewed", "trigger": "onAppear", "properties": { "variant": "String" } },
      { "event": "onboarding_welcome_cta_tapped", "trigger": "cta_tap", "properties": { "time_on_screen_ms": "Int" } }
    ],
    "accessibility": {
      "focusOrder": ["change_badge", "headline", "subtitle", "primary_cta"],
      "labels": { "chart_canvas": "Animated portfolio growth chart showing upward trend", "value_counter": "Portfolio value forty-seven thousand two hundred eighty-four dollars" },
      "hints": { "primary_cta": "Begins the setup process" },
      "traits": { "primary_cta": "isButton" }
    },
    "motion": [
      { "element": "content_opacity", "trigger": "onAppear", "duration_ms": 550, "easing": "easeOut", "delay_ms": 50, "reduceMotionFallback": "instant" },
      { "element": "chart_canvas", "trigger": "onAppear", "duration_ms": 1650, "easing": "easeInOut", "delay_ms": 300, "reduceMotionFallback": "instant" },
      { "element": "value_counter", "trigger": "onAppear", "duration_ms": 1650, "easing": "easeOut", "delay_ms": 300, "reduceMotionFallback": "instant" },
      { "element": "price_badge", "trigger": "chart_complete", "duration_ms": 450, "easing": "spring(0.45,0.60)", "delay_ms": 1850, "reduceMotionFallback": "instant" }
    ]
  },
  {
    "id": "OB-030",
    "name": "Account Creation",
    "purpose": "Create account for sync, personalisation, backup",
    "phase": "account",
    "entry": "After OB-020 or OB-025",
    "exit": [
      { "action": "sso_success", "target": "OB-050", "condition": "Apple/Google auth succeeds" },
      { "action": "email_submit", "target": "OB-040", "condition": "Valid email + password" },
      { "action": "skip", "target": "OB-050", "condition": "User taps skip" }
    ],
    "layout": {
      "background": "Color.black",
      "orientation": "portrait",
      "scrollable": true,
      "safeArea": "all",
      "stickyElements": []
    },
    "components": [
      { "id": "shield_icon", "type": "SFSymbol", "props": { "name": "lock.shield.fill", "gradient": ["blue", "purple"] }, "states": ["default"] },
      { "id": "apple_sso", "type": "ASAuthorizationAppleIDButton", "props": { "style": ".signIn", "height": 50 }, "states": ["default", "loading"] },
      { "id": "google_sso", "type": "GoogleSignInButton", "props": { "height": 50 }, "states": ["default", "loading"] },
      { "id": "divider", "type": "LabelledDivider", "props": { "text": "or" }, "states": ["default"] },
      { "id": "email_field", "type": "TextField", "props": { "placeholder": "Email address", "keyboard": "email" }, "states": ["empty", "filled", "error"] },
      { "id": "password_field", "type": "SecureField", "props": { "placeholder": "Create a password" }, "states": ["empty", "filled", "error"] },
      { "id": "create_cta", "type": "OnboardingButton", "props": { "title": "Create Account" }, "states": ["disabled", "enabled", "loading"] },
      { "id": "skip_link", "type": "TextButton", "props": { "title": "Continue without an account" }, "states": ["default"] },
      { "id": "privacy_note", "type": "Text", "props": { "style": "caption", "opacity": 0.4 }, "states": ["default"] }
    ],
    "copy": {
      "title": "Secure your portfolio",
      "subtitle": "Sign in to sync your data across devices and keep your watchlist safe.",
      "primaryCTA": "Create Account",
      "secondaryCTA": "Continue without an account",
      "errors": {
        "invalid_email": "Please enter a valid email address",
        "weak_password": "Password must be at least 8 characters",
        "email_taken": "An account with this email already exists. Try signing in instead.",
        "network": "Couldn't connect. Check your internet and try again.",
        "google_failed": "Google sign-in failed. Try again or use email instead."
      },
      "helpers": {
        "password_hint": "At least 8 characters",
        "privacy": "Your data is encrypted and stored securely. We never sell your information."
      }
    },
    "states": {
      "default": "All fields empty, SSO buttons visible, CTA disabled",
      "loading": "Spinner on active SSO/CTA button, other inputs disabled",
      "error": "Error message below relevant field, red border",
      "empty": "N/A",
      "offline": "SSO buttons hidden, email form with offline message"
    },
    "analytics": [
      { "event": "onboarding_account_viewed", "trigger": "onAppear", "properties": {} },
      { "event": "onboarding_account_created", "trigger": "success", "properties": { "method": "String", "time_on_screen_ms": "Int" } },
      { "event": "onboarding_account_skipped", "trigger": "skip_tap", "properties": { "time_on_screen_ms": "Int" } },
      { "event": "onboarding_account_error", "trigger": "error", "properties": { "error_type": "String", "method": "String" } }
    ],
    "accessibility": {
      "focusOrder": ["headline", "apple_sso", "google_sso", "email_field", "password_field", "create_cta", "skip_link"],
      "labels": { "apple_sso": "Sign in with Apple", "email_field": "Email address", "password_field": "Create a password" },
      "hints": { "email_field": "Enter your email to create an account", "skip_link": "Skips account creation. You can create an account later in Settings." },
      "traits": { "apple_sso": "isButton", "skip_link": "isButton" }
    },
    "motion": [
      { "element": "screen_entrance", "trigger": "onAppear", "duration_ms": 550, "easing": "spring(0.55,0.82)", "delay_ms": 0, "reduceMotionFallback": "instant" },
      { "element": "error_shake", "trigger": "validation_error", "duration_ms": 400, "easing": "spring(0.3,0.4)", "delay_ms": 0, "reduceMotionFallback": "none" }
    ]
  },
  {
    "id": "OB-040",
    "name": "OTP Verification",
    "purpose": "Verify email ownership via 6-digit code",
    "phase": "account",
    "entry": "After email account creation",
    "exit": [
      { "action": "code_verified", "target": "OB-050", "condition": "Correct OTP entered" }
    ],
    "layout": {
      "background": "Color.black",
      "orientation": "portrait",
      "scrollable": false,
      "safeArea": "all",
      "stickyElements": []
    },
    "components": [
      { "id": "mail_icon", "type": "SFSymbol", "props": { "name": "envelope.badge.shield.half.filled", "gradient": ["purple", "blue"] }, "states": ["default"] },
      { "id": "otp_cells", "type": "OTPInput", "props": { "digits": 6, "textContentType": "oneTimeCode" }, "states": ["empty", "filling", "error", "success"] },
      { "id": "resend_link", "type": "TimerButton", "props": { "cooldown_s": 30 }, "states": ["countdown", "active"] },
      { "id": "back_link", "type": "TextButton", "props": { "title": "Wrong email? Go back" }, "states": ["default"] }
    ],
    "copy": {
      "title": "Check your email",
      "subtitle": "We sent a 6-digit code to **{email}**",
      "primaryCTA": null,
      "secondaryCTA": null,
      "errors": {
        "wrong_code": "That code doesn't match. Check your email and try again.",
        "expired": "This code has expired. We've sent a new one.",
        "too_many": "Too many attempts. Please wait 5 minutes."
      },
      "helpers": {
        "resend_countdown": "Resend code in {time}",
        "resend_active": "Didn't get it? Resend code",
        "spam_hint": "Check your spam folder"
      }
    },
    "states": {
      "default": "Empty OTP cells, resend on countdown",
      "loading": "Verifying spinner after 6th digit",
      "error": "Red cells, error message, cells cleared",
      "empty": "N/A",
      "offline": "Message: internet required to verify"
    },
    "analytics": [
      { "event": "onboarding_otp_viewed", "trigger": "onAppear", "properties": { "verification_type": "String" } },
      { "event": "onboarding_otp_verified", "trigger": "success", "properties": { "time_to_verify_ms": "Int" } },
      { "event": "onboarding_otp_resent", "trigger": "resend_tap", "properties": { "resend_count": "Int" } },
      { "event": "onboarding_otp_error", "trigger": "error", "properties": { "error_type": "String" } }
    ],
    "accessibility": {
      "focusOrder": ["headline", "otp_cells", "resend_link", "back_link"],
      "labels": { "otp_cells": "Verification code, 6 digits" },
      "hints": { "resend_link": "Sends a new code to your email" },
      "traits": {}
    },
    "motion": [
      { "element": "cell_focus_ring", "trigger": "focus_change", "duration_ms": 200, "easing": "easeInOut", "delay_ms": 0, "reduceMotionFallback": "instant" },
      { "element": "error_shake", "trigger": "wrong_code", "duration_ms": 400, "easing": "spring(0.3,0.4)", "delay_ms": 0, "reduceMotionFallback": "none" },
      { "element": "success_check", "trigger": "verified", "duration_ms": 300, "easing": "spring(0.4,0.65)", "delay_ms": 0, "reduceMotionFallback": "instant" }
    ]
  },
  {
    "id": "OB-050",
    "name": "Market Selection",
    "purpose": "Set preferred market for relevant data and UI",
    "phase": "personalisation",
    "entry": "After OB-040 or OB-030 skip",
    "exit": [
      { "action": "tap_cta", "target": "OB-060", "condition": "always" }
    ],
    "layout": {
      "background": "Color.black",
      "orientation": "portrait",
      "scrollable": false,
      "safeArea": "all",
      "stickyElements": ["primary_cta"]
    },
    "components": [
      { "id": "globe_icon", "type": "SFSymbol", "props": { "name": "globe.americas.fill", "gradient": ["cyan", "blue"], "glowRadius": 64 }, "states": ["default"] },
      { "id": "us_card", "type": "MarketOptionCard", "props": { "flag": "us", "title": "US Markets", "subtitle": "NYSE, NASDAQ, Crypto" }, "states": ["selected", "unselected"] },
      { "id": "au_card", "type": "MarketOptionCard", "props": { "flag": "au", "title": "Australian Markets", "subtitle": "ASX, Chi-X" }, "states": ["selected", "unselected"] },
      { "id": "both_card", "type": "MarketOptionCard", "props": { "flag": "globe", "title": "Both", "subtitle": "All markets, all sessions" }, "states": ["selected", "unselected"] },
      { "id": "primary_cta", "type": "OnboardingButton", "props": { "title": "Continue" }, "states": ["default"] }
    ],
    "copy": {
      "title": "Which markets do you follow?",
      "subtitle": "We'll show relevant market hours and session data for you.",
      "primaryCTA": "Continue",
      "secondaryCTA": null,
      "errors": {},
      "helpers": {}
    },
    "states": {
      "default": "US pre-selected (or AU if locale is en-AU)",
      "loading": "N/A",
      "error": "N/A",
      "empty": "N/A",
      "offline": "Same as default"
    },
    "analytics": [
      { "event": "onboarding_market_viewed", "trigger": "onAppear", "properties": {} },
      { "event": "onboarding_market_completed", "trigger": "cta_tap", "properties": { "market": "String", "time_on_screen_ms": "Int" } }
    ],
    "accessibility": {
      "focusOrder": ["headline", "us_card", "au_card", "both_card", "primary_cta"],
      "labels": { "us_card": "US Markets, NYSE NASDAQ Crypto", "au_card": "Australian Markets, ASX Chi-X", "both_card": "Both, All markets all sessions" },
      "hints": {},
      "traits": { "us_card": "isButton", "au_card": "isButton", "both_card": "isButton" }
    },
    "motion": [
      { "element": "globe_icon", "trigger": "onAppear", "duration_ms": 600, "easing": "spring(0.6,0.78)", "delay_ms": 100, "reduceMotionFallback": "instant" },
      { "element": "card_stagger", "trigger": "onAppear", "duration_ms": 500, "easing": "spring(0.5,0.8)", "delay_ms": 180, "reduceMotionFallback": "instant" },
      { "element": "selection_ring", "trigger": "card_tap", "duration_ms": 300, "easing": "spring(0.3,0.7)", "delay_ms": 0, "reduceMotionFallback": "instant" }
    ]
  },
  {
    "id": "OB-060",
    "name": "Watchlist Builder",
    "purpose": "Add first watchlist items for immediate app value",
    "phase": "setup",
    "entry": "After OB-050",
    "exit": [
      { "action": "tap_cta", "target": "OB-070", "condition": "addedStocks.count >= 1" },
      { "action": "skip", "target": "OB-070", "condition": "user taps skip" }
    ],
    "layout": {
      "background": "Color.black",
      "orientation": "portrait",
      "scrollable": true,
      "safeArea": "all",
      "stickyElements": ["bottom_ctas"]
    },
    "components": [
      { "id": "tab_bar", "type": "SetupTabBar", "props": { "tabs": ["Watchlist", "Broker", "Crypto"] }, "states": ["default"] },
      { "id": "search_field", "type": "GlassTextField", "props": { "placeholder": "Search stocks or funds" }, "states": ["empty", "focused", "searching"] },
      { "id": "popular_chips", "type": "HorizontalScroll", "props": { "items": "StockPillButton[]" }, "states": ["default"] },
      { "id": "added_pills", "type": "HorizontalScroll", "props": { "items": "AddedStockPill[]" }, "states": ["empty", "populated"] },
      { "id": "primary_cta", "type": "OnboardingButton", "props": { "title": "Continue" }, "states": ["disabled", "enabled"] },
      { "id": "skip_link", "type": "TextButton", "props": { "title": "I'll do this later" }, "states": ["default"] }
    ],
    "copy": {
      "title": "Build your portfolio",
      "subtitle": "Pick stocks to watch, or connect your brokerage or crypto exchange",
      "primaryCTA": "Continue",
      "secondaryCTA": "I'll do this later",
      "errors": { "search_empty": "No results for '{query}'. Check the symbol or try another." },
      "helpers": { "popular_label": "Popular stocks", "added_label": "Added ({count})" }
    },
    "states": {
      "default": "Empty search, popular chips visible, CTA disabled",
      "loading": "Skeleton loaders in search results",
      "error": "No results message",
      "empty": "Popular chips + encouragement text",
      "offline": "Search disabled, popular pills only, note: Search requires internet"
    },
    "analytics": [
      { "event": "onboarding_watchlist_viewed", "trigger": "onAppear", "properties": { "tab": "String" } },
      { "event": "onboarding_stock_added", "trigger": "add_tap", "properties": { "symbol": "String", "source": "String" } },
      { "event": "onboarding_watchlist_completed", "trigger": "cta_tap", "properties": { "stock_count": "Int", "broker_connected": "Bool" } },
      { "event": "onboarding_watchlist_skipped", "trigger": "skip_tap", "properties": {} }
    ],
    "accessibility": {
      "focusOrder": ["headline", "tab_bar", "search_field", "popular_chips", "added_pills", "primary_cta", "skip_link"],
      "labels": { "search_field": "Search stocks or funds" },
      "hints": { "skip_link": "Skips watchlist setup. You can add stocks later from the main screen." },
      "traits": {}
    },
    "motion": [
      { "element": "stock_add", "trigger": "add_tap", "duration_ms": 300, "easing": "spring(0.3,0.7)", "delay_ms": 0, "reduceMotionFallback": "instant" },
      { "element": "tab_switch", "trigger": "tab_tap", "duration_ms": 200, "easing": "easeInOut", "delay_ms": 0, "reduceMotionFallback": "instant" }
    ]
  },
  {
    "id": "OB-080",
    "name": "Notifications",
    "purpose": "Request notification permission with price alert value prop",
    "phase": "permissions",
    "entry": "After OB-070 or OB-060",
    "exit": [
      { "action": "enable_tap", "target": "OB-090", "condition": "always (after OS prompt)" },
      { "action": "skip", "target": "OB-090", "condition": "user taps Not now" }
    ],
    "layout": {
      "background": "Color.black",
      "orientation": "portrait",
      "scrollable": false,
      "safeArea": "all",
      "stickyElements": ["bottom_ctas"]
    },
    "components": [
      { "id": "bell_icon", "type": "AnimatedBell", "props": { "gradient": ["purple", "blue"], "ringCount": 3 }, "states": ["animating", "idle"] },
      { "id": "notification_card", "type": "AlertNotificationCard", "props": {}, "states": ["hidden", "visible"] },
      { "id": "primary_cta", "type": "OnboardingButton", "props": { "title": "Enable Price Alerts" }, "states": ["default"] },
      { "id": "skip_link", "type": "TextButton", "props": { "title": "Not now" }, "states": ["default"] }
    ],
    "copy": {
      "title": "Stay informed, not overwhelmed",
      "subtitle": "Get alerts only when prices hit your targets. No spam, no noise.",
      "primaryCTA": "Enable Price Alerts",
      "secondaryCTA": "Not now",
      "errors": {},
      "helpers": { "fine_print": "Prices refresh every 15 min while markets are open." }
    },
    "states": {
      "default": "Bell animation plays, notification card slides in",
      "loading": "N/A",
      "error": "N/A",
      "empty": "N/A",
      "offline": "Same as default"
    },
    "analytics": [
      { "event": "onboarding_notifications_viewed", "trigger": "onAppear", "properties": {} },
      { "event": "onboarding_notifications_enabled", "trigger": "enable_tap", "properties": { "granted": "Bool" } },
      { "event": "onboarding_notifications_skipped", "trigger": "skip_tap", "properties": {} }
    ],
    "accessibility": {
      "focusOrder": ["notification_card", "headline", "subtitle", "primary_cta", "skip_link"],
      "labels": { "bell_icon": "Price alert bell icon", "notification_card": "Example notification: AAPL reached 180 dollars, your target price" },
      "hints": { "primary_cta": "Opens the system notification permission dialog", "skip_link": "Skips notification setup. You can enable notifications later in Settings." },
      "traits": {}
    },
    "motion": [
      { "element": "bell_spring_in", "trigger": "onAppear", "duration_ms": 650, "easing": "spring(0.65,0.70)", "delay_ms": 100, "reduceMotionFallback": "instant" },
      { "element": "bell_ring", "trigger": "after_spring", "duration_ms": 880, "easing": "spring(0.22,0.45)", "delay_ms": 650, "reduceMotionFallback": "none" },
      { "element": "notification_slide", "trigger": "onAppear", "duration_ms": 600, "easing": "spring(0.60,0.80)", "delay_ms": 1300, "reduceMotionFallback": "instant" },
      { "element": "content_fade", "trigger": "onAppear", "duration_ms": 550, "easing": "easeOut", "delay_ms": 1000, "reduceMotionFallback": "instant" }
    ]
  },
  {
    "id": "OB-100",
    "name": "Completion",
    "purpose": "Celebrate and transition to main app",
    "phase": "completion",
    "entry": "After OB-090 or OB-080",
    "exit": [
      { "action": "auto_dismiss", "target": "MainApp", "condition": "after 2s delay" },
      { "action": "tap_anywhere", "target": "MainApp", "condition": "always" }
    ],
    "layout": {
      "background": "Color.black",
      "orientation": "portrait",
      "scrollable": false,
      "safeArea": "all",
      "stickyElements": []
    },
    "components": [
      { "id": "success_check", "type": "AnimatedCheckmark", "props": { "circleColor": "green", "checkColor": "white" }, "states": ["drawing", "complete"] },
      { "id": "headline", "type": "Text", "props": { "text": "You're all set", "style": "headline1" }, "states": ["default"] },
      { "id": "summary", "type": "Text", "props": { "style": "body", "opacity": 0.6 }, "states": ["default"] },
      { "id": "tap_hint", "type": "Text", "props": { "text": "Tap anywhere to continue", "style": "caption", "opacity": 0.3 }, "states": ["default"] }
    ],
    "copy": {
      "title": "You're all set",
      "subtitle": "{dynamic_summary}",
      "primaryCTA": null,
      "secondaryCTA": null,
      "errors": {},
      "helpers": { "tap_hint": "Tap anywhere to continue" }
    },
    "states": {
      "default": "Success animation plays, auto-dismiss after 2s",
      "loading": "N/A",
      "error": "N/A",
      "empty": "N/A",
      "offline": "Same as default"
    },
    "analytics": [
      { "event": "onboarding_completed", "trigger": "onAppear", "properties": { "total_time_ms": "Int", "screens_viewed": "Int", "screens_skipped": "Int", "account_created": "Bool", "watchlist_count": "Int", "portfolio_count": "Int", "notifications_enabled": "Bool", "biometrics_enabled": "Bool", "market": "String" } }
    ],
    "accessibility": {
      "focusOrder": ["headline", "summary"],
      "labels": { "success_check": "Setup complete checkmark" },
      "hints": {},
      "traits": {}
    },
    "motion": [
      { "element": "circle_draw", "trigger": "onAppear", "duration_ms": 500, "easing": "easeOut", "delay_ms": 0, "reduceMotionFallback": "instant" },
      { "element": "check_draw", "trigger": "after_circle", "duration_ms": 300, "easing": "spring(0.3,0.6)", "delay_ms": 400, "reduceMotionFallback": "instant" },
      { "element": "text_fade", "trigger": "after_check", "duration_ms": 400, "easing": "easeOut", "delay_ms": 600, "reduceMotionFallback": "instant" }
    ]
  }
]
```

---

## 11. Asset Manifest

### SVG Illustrations (12)

| Filename | Screen | Description | Style Notes |
|----------|--------|-------------|-------------|
| `il_welcome_chart.svg` | OB-020 | Ascending area chart with gradient fill | Blue-to-transparent gradient; Catmull-Rom curve; no axis labels |
| `il_portfolio_value.svg` | OB-020 | Currency symbol with upward arrow | Monoline stroke; white on dark; avoid dollar sign (use generic currency) |
| `il_shield_lock.svg` | OB-030 | Shield with lock keyhole | Gradient fill (blue-to-purple); modern flat style |
| `il_email_verify.svg` | OB-040 | Envelope with checkmark badge | Purple gradient; semi-flat with subtle shadow |
| `il_globe_markets.svg` | OB-050 | Globe with latitude/longitude lines and market pins | Cyan/blue palette; avoid country flags in illustration (flags are emoji) |
| `il_search_stocks.svg` | OB-060 | Magnifying glass over stock ticker cards | Blue accent; cards show generic ticker rows |
| `il_csv_import.svg` | OB-070 | Spreadsheet document with arrow importing into phone | Neutral colours; document icon style |
| `il_broker_connect.svg` | OB-070 | Two devices with secure connection line between them | Green secure connection indicator; padlock on line |
| `il_bell_alert.svg` | OB-080 | Bell with notification badge showing price target | Purple/blue gradient; notification card overlaid |
| `il_faceid_lock.svg` | OB-090 | Face ID scanning frame with shield | Green accent; TBD icon shape per device |
| `il_success_check.svg` | OB-100 | Circle with checkmark in centre | Green circle, white check; simple and clean |
| `il_empty_watchlist.svg` | Empty state | Dotted chart outline with plus button | Muted colours; encouraging, not sad |

**Style guidelines for all illustrations:**
- Semi-flat modern style (avoid 3D, avoid skeuomorphism)
- Finance-appropriate: no cartoon money, no slot machines, no gambling imagery
- Colour palette from design tokens (accent colours per screen)
- Max 3 colours per illustration plus white/opacity variants
- Export at 1x, 2x, 3x for iOS; `mdpi` through `xxxhdpi` for Android
- Avoid text in illustrations (localisation-unfriendly)

### Lottie / Animated Assets (6)

| Filename | Screen | Duration | Description | Reduce-Motion Fallback |
|----------|--------|----------|-------------|----------------------|
| `anim_chart_draw.json` | OB-020 | 1650ms | Chart line drawing left-to-right with gradient area reveal | Static completed chart (final frame) |
| `anim_value_counter.json` | OB-020 | 1650ms | Number roll-up from 0 to target value | Static final value |
| `anim_bell_ring.json` | OB-080 | 1100ms | Bell swings L-R-L with diminishing amplitude | Static bell icon |
| `anim_notification_slide.json` | OB-080 | 600ms | Notification card slides up from below with slight bounce | Static notification card |
| `anim_success_check.json` | OB-100 | 800ms | Circle draws clockwise, then checkmark path draws inside | Static checkmark |
| `anim_confetti_burst.json` | OB-060 | 300ms | Small particle burst (6-8 circles) emanating from added stock pill | No animation (skip entirely) |

**Lottie guidelines:**
- All animations must loop: no (play once)
- Frame rate: 60fps for smooth playback
- Total file size: < 50KB each
- Colour references should use Lottie colour slots for theming
- Test on iPhone SE (smallest screen) and iPhone 16 Pro Max (largest)

---

## Progressive Disclosure Strategy

### What's shown during onboarding:
- Watchlist basics (add stocks, see prices)
- Portfolio basics (manual entry, broker connect)
- Market preference
- Notification value proposition
- App lock (biometrics)

### What's deferred to the main app:
| Feature | When revealed | How |
|---------|--------------|-----|
| Price alerts creation | First stock detail view (3rd visit) | Coach mark pointing at bell icon |
| AI insights | After 3 sessions (Pro/Black users) | Tab bar highlight + tooltip |
| Technical indicators | First chart interaction (2nd time) | "Explore indicators" chip below chart |
| Portfolio benchmark | After 5 portfolio holdings (Black tier) | Banner in portfolio view |
| CSV import | After 3rd manual holding added | "Import from CSV?" suggestion card |
| Cloud sync | After account creation in Settings | Success toast + sync indicator |
| Watchlist groups | After 10+ watchlist items | Coach mark on watchlist header |
| Portfolio groups | After 10+ portfolio holdings | Suggestion card in portfolio view |
| Export reports | After 2 weeks of usage (Pro+) | Settings highlight badge |
| Auto-refresh settings | After first manual refresh (Pro+) | "Enable auto-refresh?" toast |

---

*End of specification.*
