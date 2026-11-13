# Regulatory Review Checklist (Australia first)

_2026-11-13. **This is not legal advice.** It records how each capability might be characterised and lists the decisions that need a qualified Australian financial-services lawyer or compliance adviser before the matching feature is offered to the public. An execution-only positioning, user approval, AI disclaimers or the use of a licensed broker do **not**, by themselves, remove the platform's own obligations._

## 1. How each capability might be characterised

| Capability (today's status) | Possible characterisation | Question for counsel |
|---|---|---|
| Prices, charts, watchlists, portfolio tracking (live) | Factual information | Confirm no advice element, including in default watchlists and "top movers" curation |
| AI chat and copilot commentary on the user's own holdings (live, server-proxied) | General advice, or **personal advice** where it takes the person's objectives, situation or needs into account (Corporations Act s766B) | Is concentration and "why did my portfolio fall" analysis personal advice? Which warnings and scaling (RG 244) apply? Does RG 255 (digital advice) apply? |
| Agent signals and strategy templates (paper only) | General or personal advice; possibly a financial product recommendation | Can signals be shown for real instruments if the user only trades paper? |
| Paper trading (live, simulated) | Likely information or education, but marketing could change that | Confirm the simulated-results disclaimers are adequate |
| Order proposals for a real broker account (**disabled**) | **Dealing** or **arranging** (s766C), even when a licensed broker executes | AFSL authorisation needed, or an authorised representative arrangement under a licensee? |
| Approval-required live agents (**disabled**) | Arranging plus personal advice | Same, plus best-interests duty and SOA obligations if personal advice |
| Autonomous live agents (**disabled**) | Discretionary trading, akin to a managed discretionary account | MDA authorisation and the related ASIC instruments? |
| SnapTrade read-only aggregation (live) | Data service | Terms, consent and privacy (§4). Confirm no CDR implications |
| Custody of funds or assets | **Not offered**: no custody, no transfers, no withdrawals | Confirm the architecture keeps it that way (§5) |
| Operating a trading venue | **Not offered** | — |

References: ASIC "Do I need an AFS licence?"; RG 255 *Providing digital financial product advice to retail clients*; RG 244 *Giving information, general advice and scaled advice*.

## 2. Digital assets

- Per the project brief, the *Corporations Amendment (Digital Assets Framework) Act 2026* regime is scheduled to commence on **9 April 2027**, and ASIC's implementation work is ongoing. **Counsel to confirm the commencement date and the final rules.** Draft consultation material must not be treated as final.
- Questions: is any supported token a financial product? Does arranging crypto orders through Alpaca or Coinbase make this platform a digital-asset platform or tokenised custody platform intermediary under the new framework, or something else?
- **AUSTRAC**: do the virtual-asset service provider obligations under the AML/CTF regime apply if the app arranges crypto exchanges for customers, even though a third-party exchange executes? If so, registration, an AML/CTF program and KYC would be needed before any live crypto order path is enabled.

## 3. Cross-border and third parties

Data leaves Australia today through these providers:

| Provider | Data | Location |
|---|---|---|
| SnapTrade | Brokerage holdings and accounts | Outside Australia (Canada / US) |
| OpenAI, Google Gemini | Chat text, including portfolio summaries the app builds | US |
| Alpaca, FMP, Finnhub, CoinGecko, Yahoo | Symbols queried (no account data) | US and other |
| Supabase | All server data | **Sydney** (`ap-southeast-2`) |

Questions: APP 8 cross-border disclosure, the consents and privacy-notice wording needed, and whether portfolio summaries sent to model providers need to be minimised further. The app already avoids exact share counts and cost basis in chat prompts.

## 4. Privacy and security obligations

- Does the **Privacy Act 1988** and the APPs apply? The small-business exemption has conditions; don't assume it applies.
- Notifiable Data Breaches scheme readiness: an incident runbook and a contact path. See `THREAT_MODEL.md`.
- Needed before public release: a privacy notice (the `Constants.URLs.privacyPolicy` placeholder is still `yoursite.com`), terms, in-app data export, and account deletion that removes server rows. FK cascades already delete user rows, including the append-only credential log.
- Financial-services record-keeping obligations if licensed.

## 5. Architecture commitments that support compliance

- No custody, no transfers, no withdrawals. SnapTrade portals open **read-only** unless a server flag is set (`SNAPTRADE_ALLOW_TRADE_CONNECTIONS`, off).
- Live execution is disabled in three places (TradingCore, a DB constraint and an empty live adapter registry), so enabling it is a reviewable change, never a configuration toggle on a device.
- Model output can't place orders. A server policy on every AI call forbids claiming to trade or presenting predictions as facts.
- Every agent action, proposal and fill is recorded in an audit trail.

## 6. Release gates to implement (Phase D in `IMPLEMENTATION_PLAN.md`)

A server-side, admin-only configuration that every relevant path must read. Defaults are shown.

| Gate | Default | Enforced today? |
|---|---|---|
| `live_trading_enabled` | off | Yes, by code (three layers) |
| `automated_live_trading_enabled` | off | Yes, by code |
| `trade_connections_enabled` (SnapTrade portals) | off | Yes (function secret) |
| `personalised_recommendations_enabled` | off | **No**: the copilot's wording needs review against §1 |
| `allowed_countries` / customer types | AU retail | **No** |
| `allowed_providers` / instruments | Current list | Partially (TradingCore catalogs) |
| `custodial_features_enabled` | off | Yes: none exist |
| Marketing claims about performance | Reviewed copy only | Process, not code |

## 7. Tax record-keeping

- Today the synced holdings model stores money as **USD** (the app's money invariant), with practice portfolios in a single local currency. ATO-ready records need: the original trade amount and currency, the **AUD value at the trade date** with its FX source, fees, acquisition and disposal dates, the asset identifier and the crypto transaction type (buy, sell, swap, staking income).
- Exports must say they are **preliminary**, not a tax calculation.

## 8. Decisions needed before each step

1. Public release of AI commentary: general vs personal advice, warnings, RG 255 controls.
2. Any real-money order path, including approval-required: AFSL or authorised-representative pathway; AUSTRAC position for crypto.
3. Autonomous live agents: MDA position. Expect "no" for the first release.
4. Cross-border disclosures and the privacy notice.
5. Digital Assets Framework position before 9 April 2027 (if confirmed).
