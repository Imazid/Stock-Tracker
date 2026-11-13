# Private Markets

## Architecture decision

**Status** Accepted for development. Live distribution and document processing require review.

The iOS feature uses the existing navigation, portfolio, currency service, and Supabase session. An Edge Function serves the public catalogue. It requires a valid session for company updates, research, investor profiles and provider handoff. Supabase stores published facts and scoped account records. The iPhone stores manual holdings, valuations, cash flows and watchlists in account-specific, data-protected files excluded from backups. Signed-out device records stay in their own scope. The listed portfolio keeps its original daily performance history and gains a unified allocation that uses dated private carrying values.

This design reuses the existing AI gateway, model credentials, quota and encryption envelope. The server fetches selected evidence by authenticated ownership, passes excerpts only after explicit permission and a deployment flag, validates exact quotations against their sources, and stores reports with the same envelope encryption. Source documents and analyst outputs are untrusted inputs. The language models receive no application or order tools. A specialist review or synthesis failure fails the committee run. Quotes are checked mechanically. Analysis and its interpretation still require review.

## Phase 1 · Discovery, research and tracking

- The hosted catalogue includes two closed Grong Grong Solar Farm rounds, an issuer announcement and an ASX and issuer-sourced proposed Alvear Tungsten IPO reference. The IPO reference displays unverified availability and has no handoff URL. Publish additional facts only with a public issuer source or contractual publication rights. Set publication flags on the opportunity, round and company. Use the original source URL, record the verification timestamp and leave unavailable fields empty. When a listing or round passes its 24-hour verification window or its deadline, in-app handoff is unavailable.
- A maintained provider directory links to Birchal, OnMarket, AngelList Meridian and Syndex. These links lead to each provider's public website or documentation.
- Research uses one to three published opportunities or approved excerpts. Deal Room supports text pasted by the user or extracted locally from a text PDF or UTF-8 file. It sends only the edited excerpt. It has no OCR or provider data-room ingestion. Source excerpts are capped at 4,500 characters. Deleting a source does not delete a previously generated report. Remove that report separately when necessary.
- Unified allocation aggregates tracked listed portfolios with manual private positions valued using dated marks and available FX. A position without a carrying value or FX rate is excluded and counted in the interface. A stale mark is flagged after 90 days. Cash-flow and valuation dates govern XIRR, MOIC and TVPI. DPI uses settled cash flows. XIRR returns unavailable when the recorded cash flows do not establish a unique, bracketed rate.
- Company updates use curated issuer announcements with source and timestamp. User-controlled local notifications run on iOS background refresh when a session is restored and the device is accessible. There is no unattended provider crawler or scheduled AI news synthesis.

## Phase 2 · Provider hosted workflow

The country and investor classification entered by a user are self-declared. The handoff RPC independently requires a current provider connection and unexpired provider verification. A dated compliance version and agreement for the same provider and jurisdiction must be enabled. The application UI collects a document review acknowledgement and amount. The provider applies its own prescribed disclosures, identity checks and eligibility rules, takes the application and handles funds and withdrawal. A tracked handoff starts with a pending provider status.

The service-role-only provider event RPC matches an existing connected provider subject to the commitment. It rejects mismatched references and unsupported transitions, serializes updates, ignores replays and creates ownership atomically only on confirmation with issued units and settled capital. There is no public webhook. The app can display provider-owned records once an approved adapter supplies them. Manual records are labelled self-reported and remain device-local.

| Provider | Verified public capability | Integration status |
| --- | --- | --- |
| Birchal | Australian CSF and provider-hosted checks and applications. | Public directory link. Offer-specific handoff code requires signed approval, approved data and a verification adapter. |
| OnMarket | Australian CSF, IPO and eligible wholesale offers. Its website terms restrict commercial content reuse. | Public directory link. Offer-specific handoff has the same gates as Birchal. |
| AngelList | Meridian hosts funds, SPVs and permissioned deal rooms. Link is an OAuth MCP for read-only authorised fund data. | The iOS app implements on-device OAuth with PKCE, dynamic registration and revocation. Fund records are requested directly from AngelList using read-only scopes. An entitled account is required to verify returned records. |
| Syndex | New Zealand registry and primary and secondary marketplace services. | Public directory link. No Stock Tracker access agreement or Australian transaction pathway. |

## Phase 3 · Advanced infrastructure

The product records capital calls, distributions, stale marks, share classes and dated corporate actions. The provider event interface accepts confirmed ownership from an approved adapter. Capital payments, embedded execution, fund subscription, syndicate participation, live registry synchronization, and secondary transactions require their own provider agreements, documented APIs and jurisdiction review. There are no in-app payment or order routes. Stock Tracker does not act as a custody or secondary-market operator.

## Development and rollout

1. Apply migrations to a disposable project with `supabase start` or run `scripts/verify-migrations.sh`. Enable local Edge Runtime for the disposable project and serve the functions. The hosted Stock Tracker project has the Private Markets migrations and Edge Function. For updates, dry-run the linked migrations and deploy the `private-markets` function by name.
2. Configure the existing `CREDENTIAL_KEKS` and `CREDENTIAL_ACTIVE_KEK` secrets. Configure at least one supported model key using the existing AI gateway configuration. The private function shares the per-user AI quota. Keep older encryption keys available while retained documents and reports reference them.
3. Install a build with the Stock Tracker Supabase URL and publishable key. Test authentication, the closed catalogue, a user-created holding, and a research request in staging. The app's test build can use a local Supabase URL.
4. Before enabling `PRIVATE_MARKETS_DOCUMENT_AI_ENABLED`, review provider retention, cross-border handling, data-room terms and permission notices. Set `PRIVATE_MARKETS_DOCUMENT_AI_PROVIDER` to the approved provider, `openai` or `gemini`. Document runs use that provider exclusively. Keep the feature flag false when approval is absent.
5. Have compliance review the AU rule version, retail investor protections, wholesale routes, documents, referral mechanics and user-facing AI. Keep handoff disabled until the provider approves Stock Tracker and documents the account, eligibility, confirmation and withdrawal interfaces. Add its adapter, test signatures and replay handling, and complete a provider sandbox acceptance run.
6. Keep live authorisations and contractual evidence outside this repository. Populate the compliance and approval records through privileged operational procedures after sign-off. The in-app cap accounts for provider applications known to Stock Tracker. The intermediary remains authoritative for the full per-company, per-intermediary rolling cap and cooling-off deadline.

## Verification

- 146 TradingCore tests and 31 Edge Function unit tests passed. The Edge Function type check and migration test suite passed.
- A disposable Supabase stack verified the catalogue, updates and account boundaries. The hosted Stock Tracker project also returned the catalogue, refused anonymous private access and passed encrypted excerpt and cross-account checks. The SQL suite verified consent-related access controls, Australian offer gates, duplicate handoffs and provider-confirmed ownership using fixtures.
- Two iPhone 17 Pro simulator tests passed on iOS 26.5. They exercised the provider directory, offline scenario calculator, and private holding creation, valuation and persistence across relaunch.
- AngelList’s production OAuth endpoint accepted a Stock Tracker dynamic client registration with the iOS redirect. The interactive consent, token exchange and fund reads require an entitled AngelList account. Provider onboarding and investment settlement remain gated on signed agreements and compliance approval.

## Primary sources

- [ASIC crowd-sourced funding](https://www.asic.gov.au/crowd-sourced-funding)
- [ASIC Regulatory Guide 262](https://download.asic.gov.au/media/kdljjy4d/rg262-published-18-october-2018-20260421.pdf)
- [ASIC licensing guidance for advice and dealing](https://www.asic.gov.au/regulatory-resources/financial-services/giving-financial-product-advice)
- [OAIC commercial AI guidance](https://www.oaic.gov.au/privacy/privacy-guidance-for-organisations-and-government-agencies/guidance-on-privacy-and-the-use-of-commercially-available-ai-products)
- [Birchal investor process](https://www.birchal.com/investors)
- [OnMarket Financial Services Guide](https://www.onmarket.com.au/general/financial-services-guide/) and [Terms of Use](https://www.onmarket.com.au/general/terms-of-use/)
- [AngelList Meridian](https://help.angellist.com/hc/en-us/articles/38089333472269-What-is-Meridian) and [AngelList Link data and privacy](https://help.angellist.com/hc/en-us/articles/47543225581965-AngelList-Link-Data-Privacy)
- [ASX upcoming floats](https://www.asx.com.au/listings/upcoming-floats-and-listings.) and [Alvear Tungsten issuer prospectus page](https://alveartungsten.com/)
- [Syndex investor access](https://www.syndex.exchange/investors)
