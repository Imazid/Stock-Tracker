# Regulatory review — decisions that need a qualified Australian lawyer

This is a decision register, not legal advice. The underlying research, with quotations and
sources, is `docs/trading/regulatory-au.md` (researched 2026-11-13 from ASIC, AUSTRAC, the Federal
Register of Legislation and Apple). Each decision below names the product capability it unlocks
and the server-side gate (`public.platform_gates`) that stays **off** until it is answered in
writing. The build enforces "off" in three places: CHECK constraints in the database, the gate
check in `supabase/functions/_shared/oms/execute.ts`, and the adapters' own refusal of live
orders.

## 1. What the product does today (no licence assumed)

| Capability | Status | Why it's allowed to run now (engineering view — confirm) |
|---|---|---|
| Portfolio tracking, market data, charts | On | Factual information. Data-vendor terms still apply (D11). |
| Practice trading, backtests (simulated money) | On | No financial product is acquired. Results are labelled as simulated; no performance claims. |
| Agents in research / signals / practice modes | On | Must stay general and factual: no statement that the person's objectives, finances or needs were considered. Gate `personalised_recommendations` is off. Whether *signals* are general advice is decision D2. |
| Orders to a provider's **paper** account (Alpaca paper) | Gated `provider_paper_execution` (off) | No real money; still a third-party integration — confirm the provider's terms allow it. |
| Real-money orders | Gated `live_execution` (off; refused by CHECK) | Decisions D1, D3–D9. |
| Agent orders without per-order approval | Gated `automated_live_execution` (off; refused by CHECK) | Decision D4 (MDA). |
| Custody of client assets | Never (refused by CHECK) | Out of scope. |

## 2. Decisions for counsel

| # | Question | Unlocks | Notes from the research |
|---|---|---|---|
| D1 | Does in-app order entry to a person's own Alpaca/Coinbase account constitute **arranging** (dealing) — or dealing as agent, given we submit with their API key? Which licensing route: own AFSL, authorised representative of a named licensee, or an exemption? | `live_execution` | RG 36.44 names order routing as generally arranging; holding one's own brokerage account doesn't change that. |
| D2 | Are agent research outputs, signals and order *proposals* **general** or **personal** advice? What must every proposal show (s949A general advice warning)? | Agent proposals on any path; `personalised_recommendations` | An agent that reads holdings, cash or limits risks "reasonable person might expect" personal advice (s766B(3)). RG 255 applies to digital advice; algorithm governance requirements. |
| D3 | For each crypto asset we'd route orders for, is it a financial product under INFO 225? Which tokens go on the allow-list? | Crypto on `live_execution` | Bitcoin likely not; yield-bearing stablecoins, many wrapped tokens likely are. |
| D4 | Would a strategy mandate (agent trades within user limits without per-order approval) be a **managed discretionary account**? If yes, which RG 179 / Instrument 2026/720 obligations apply? | `automated_live_execution` | User-set limits don't avoid MDA status. |
| D5 | **AUSTRAC**: does routing orders to a registered exchange make us a virtual asset service provider ("making arrangements" under items 50A/50B)? | Crypto on `live_execution` | Not settled by the guidance; registration is required *before* providing VASP services. |
| D6 | **Digital Assets Framework Act 2026**: after commencement, does the (jb) exemption for "arranging for another person to use a digital asset platform" cover us, and what transition steps apply? | Crypto after commencement | Commencement shows as **8 April 2027** on the legislation register and **9 April 2027** in ASIC's roadmap — confirm the date. ASIC's detailed guidance is still in progress; don't build to draft consultation requirements. |
| D7 | **Privacy Act 1988 / APPs**: are we exempt as a small business, or caught by s6D(4)(c)-(d)? Overseas disclosure (US providers, model providers, hosting region), Notifiable Data Breaches plan, data retention/deletion periods. | Public launch | Plan to comply regardless. The Stock Tracker Supabase project is in Sydney. Assess each overseas provider separately. |
| D8 | **Design and distribution obligations**: are we a distributor? TMD checks? | `live_execution` | |
| D9 | **Provider eligibility**: may Alpaca and Coinbase serve Australian retail clients for the asset classes we enable, and do their terms permit third-party order entry from an app like this? Written approval (e.g. Alpaca Connect live approval). | `live_execution`, `provider_paper_execution` | Not researched yet. |
| D10 | **App Store**: the submitting entity must be the licensed institution for trading apps (3.2.1(viii), 5.1.1(ix)); crypto exchange facilitation only where licensed (3.1.5(iii)). Can the iPhone app carry order entry at all under the current developer account? | Any order entry in the iPhone app | Live trading shipped dark must be described in review notes (2.5.19). |
| D11 | **Market-data licensing** for a public web app: Alpaca free plan (IEX) redistribution terms; SIP/consolidated entitlements; Yahoo's unofficial endpoints in a commercial product; exchange display fees for ASX/LSE/Tokyo data. | Public web launch | The web app labels IEX data as IEX, not consolidated. |
| D12 | **Tax**: the app shows preliminary P&L. Confirm wording so it isn't presented as an ATO tax calculation; what records to keep for crypto (ATO detailed transaction records). | Public launch | Transactions keep original currency, amounts, fees, dates, provider records; AUD conversion is stored separately. |
| D13 | **Record keeping**: retention periods for order, approval and audit records if licensed (and whether the OMS tables meet them). | `live_execution` | `order_intent_transitions` and `oms_events` are append-only. |

## 3. Release gates (what has to be on file before an administrator flips a gate)

Use the go-live checklist in `docs/trading/regulatory-au.md` §8, levels (a) manual live orders,
(b) approval-required agent orders, (c) autonomous agent orders. In addition, for this codebase:

1. A reviewed migration that drops the relevant `*_not_in_this_build` CHECK constraints, and a
   reviewed code change that enables the live adapter path — never an UPDATE alone.
2. `provider_paper_execution` has run end-to-end against Alpaca paper with the failure journeys
   of the brief's §18 (market closed, insufficient buying power, risk limit, expired approval,
   wrong user, duplicate submit, timeout after accept, partial fill, unsupported order type,
   disconnected provider, kill switch).
3. Monitoring and alerting from `THREAT_MODEL.md` "Operational controls" are live.
4. Support, complaints (IDR/EDR membership if licensed) and incident contacts are published.

## 4. Things the product must never do, whatever the gates say

Hold or move customer assets; request withdrawal or transfer permissions; present simulated or
backtested results as achievable; let a model place, approve or size an order without the
deterministic risk engine and the owner's approval; claim that a P&L figure is a tax calculation.


## 5. Data handling and tax records

Data leaves Australia today through these providers:

| Provider | Data | Location |
|---|---|---|
| SnapTrade | Brokerage holdings and accounts | Outside Australia (Canada / US) |
| OpenAI, Google Gemini | Chat text, including portfolio summaries the app builds | US |
| Alpaca, FMP, Finnhub, CoinGecko, Yahoo | Symbols queried (no account data) | US and other |
| Supabase | All server data | **Sydney** (`ap-southeast-2`) |

Questions: APP 8 cross-border disclosure, the consents and privacy-notice wording needed, and whether portfolio summaries sent to model providers need to be minimised further. The app already avoids exact share counts and cost basis in chat prompts.

### Privacy and security obligations

- Does the **Privacy Act 1988** and the APPs apply? The small-business exemption has conditions; don't assume it applies.
- Notifiable Data Breaches scheme readiness: an incident runbook and a contact path. See `THREAT_MODEL.md`.
- Before public release, review and publish the privacy notice and terms, configure the public privacy URL, and verify the full account-data request process. The iOS Private Markets export covers that workspace's device and cloud records. Existing portfolio CSV exports cover selected listed investment records. The deployed account deletion endpoint removes the Supabase user and dependent data. Sign in with Apple deletion requires server configuration and a device acceptance run. See [Account deletion](DEPLOYMENT.md#account-deletion).
- Financial-services record-keeping obligations if licensed.

### Tax record-keeping

- Today the synced holdings model stores money as **USD** (the app's money invariant), with practice portfolios in a single local currency. ATO-ready records need: the original trade amount and currency, the **AUD value at the trade date** with its FX source, fees, acquisition and disposal dates, the asset identifier and the crypto transaction type (buy, sell, swap, staking income).
- Exports must say they are **preliminary**, not a tax calculation.
