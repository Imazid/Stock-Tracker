# Private Markets

## Architecture decision

**Status** Accepted for development. Live distribution and document processing require review.

The iOS feature uses the existing navigation, portfolio, currency service, and Supabase session. An Edge Function serves the public catalogue. It requires a valid session for company updates, research, investor profiles and provider handoff. Supabase stores published facts and scoped account records. The iPhone stores manual holdings, valuations, cash flows and watchlists in account-specific, data-protected files excluded from backups. Signed-out device records stay in their own scope. The listed portfolio keeps its original daily performance history and gains a unified allocation that uses dated private carrying values.

This design reuses the existing AI gateway, model credentials, quota and encryption envelope. The server fetches selected evidence by authenticated ownership, passes excerpts only after explicit permission and a deployment flag, resolves numbered source citations, and stores reports with the same envelope encryption. Committee runs continue on the Edge runtime while the app polls an account-scoped status endpoint. Source documents and analyst outputs are untrusted inputs. The language models receive no application or order tools. A specialist review or synthesis failure fails the committee run. Quotes are checked mechanically. Analysis and its interpretation still require review.

## Phase 1 · Discovery, research and tracking

- The catalogue includes closed Grong Grong Solar Farm, Heidi and AdvanCell rounds, plus public offer references for Alvear Tungsten and MoPA. The offer references display unverified availability. Publish additional facts only with a public issuer source or contractual publication rights. Set publication flags on the opportunity, round and company. Use the original source URL, record the verification timestamp and leave unavailable fields empty. When a listing or round passes its 24-hour verification window or its deadline, in-app handoff is unavailable.
- Signed-in users can search the public catalogue in natural language. The model interprets the question as filters. The server applies the filters to published records, including current availability, eligibility and currency checks. The interface displays the interpreted filters and any constraints that need clarification.
- A maintained provider directory links to Birchal, OnMarket, AngelList Meridian and Syndex. These links lead to each provider's public website or documentation.
- Research uses one to three published opportunities, company announcements or approved excerpts. Deal Room extracts selectable PDF text and recognizes text on scanned PDF pages on the device. It also accepts UTF-8 files and pasted text. Only the reviewed excerpt is uploaded. The limit is 4,500 characters, with scan recognition attempted on up to eight pages. Provider data-room ingestion requires provider permission. Previously generated reports can be removed independently of their sources.
- Unified allocation aggregates tracked listed portfolios with self-reported and provider-confirmed private positions using dated marks and available FX. Copilot can show the same allocation in response to an exposure question. That request is handled on the device. A position without a carrying value or FX rate is excluded and counted in the interface. A stale mark is flagged after 90 days. Cash-flow and valuation dates govern XIRR, MOIC and TVPI. DPI uses settled cash flows. XIRR returns unavailable when the recorded cash flows do not establish a unique, bracketed rate. Provider performance also requires the evidenced opening settlement and complete activity history.
- Manual holdings can link to a Deal Room excerpt and record the owner's review. The holding remains self-reported. Changing the recorded ownership terms clears the link and review date. Manual holdings can also link to a published catalogue company for monitoring.
- Company updates show curated issuer announcements and recently verified funding events for followed companies, linked manual holdings and provider-confirmed holdings. Each update includes a source, timestamp and significance. Users can ask the research agent to summarise up to three published announcements at a time. The agent receives only those published records. Optional notifications depend on iOS background refresh, a restored session and access to the device's records. Continuous collection and scheduled AI summaries remain future work.

## Phase 2 · Provider hosted workflow

The country and investor classification entered by a user are self-declared. The handoff RPC independently requires a current provider connection and unexpired provider verification. A dated compliance version and agreement for the same provider and jurisdiction must be enabled. The application UI collects a document review acknowledgement and amount. The provider applies its own prescribed disclosures, identity checks and eligibility rules, takes the application and handles funds and withdrawal. A tracked handoff starts with a pending provider status.

The service-role-only provider event RPC matches an existing connected provider subject to the commitment. It rejects mismatched references and unsupported transitions, serializes updates, ignores replays and creates ownership atomically only on confirmation with issued units and settled capital. A second service-role RPC accepts dated settlement evidence, valuations, capital calls and distributions from a trusted adapter after its holding-activity approval is enabled. It checks account and currency, ignores replays and older revisions, and audits accepted changes. The app displays confirmed records as read-only. Manual records are labelled self-reported and remain device-local.

| Provider | Verified public capability | Integration status |
| --- | --- | --- |
| Birchal | Australian CSF and provider-hosted checks and applications. | Public directory link. Offer-specific handoff code requires signed approval, approved data and a verification adapter. |
| OnMarket | Australian CSF, IPO and eligible wholesale offers. Its website terms restrict commercial content reuse. | Public directory link. Offer-specific handoff has the same gates as Birchal. |
| AngelList | Meridian hosts funds, SPVs and permissioned deal rooms. Link is an OAuth MCP for read-only authorised fund data. | The iOS app implements on-device OAuth with PKCE, dynamic registration and revocation. Fund records are requested directly from AngelList using read-only scopes. An entitled account is required to verify returned records. |
| Syndex | New Zealand registry and primary and secondary marketplace services. | Public directory link. No Stock Tracker access agreement or Australian transaction pathway. |

## Phase 3 · Advanced infrastructure

The product records capital calls, distributions, stale marks, share classes and dated corporate actions. Optional reminders schedule on the device for up to 20 upcoming recorded calls, at 9 a.m. the preceding day or the due date if the earlier reminder window has passed. The app clears pending reminders for settled calls after the provider records refresh. Capital payments, embedded execution, fund subscription, syndicate participation, live registry synchronization, and secondary transactions require their own provider agreements, documented APIs and jurisdiction review. There are no in-app payment or order routes. Stock Tracker does not act as a custody or secondary-market operator.

## Development and rollout

1. Apply migrations to a disposable project with `supabase start` or run `scripts/verify-migrations.sh`. Enable local Edge Runtime for the disposable project and serve the functions. The hosted Stock Tracker project has the Private Markets migrations and Edge Function. For updates, dry-run the linked migrations and deploy the `private-markets` function by name.
2. Configure the existing `CREDENTIAL_KEKS` and `CREDENTIAL_ACTIVE_KEK` secrets. Configure at least one supported model key using the existing AI gateway configuration. The private function shares the per-user AI quota. Keep older encryption keys available while retained documents and reports reference them.
3. Install a build with the Stock Tracker Supabase URL and publishable key. Test authentication, the closed catalogue, a user-created holding, and a research request in staging. The app's test build can use a local Supabase URL.
4. Before enabling `PRIVATE_MARKETS_DOCUMENT_AI_ENABLED`, review provider retention, cross-border handling, data-room terms and permission notices. Set `PRIVATE_MARKETS_DOCUMENT_AI_PROVIDER` to the approved provider, `openai` or `gemini`. Document runs use that provider exclusively. Keep the feature flag false when approval is absent.
5. Have compliance review the AU rule version, retail investor protections, wholesale routes, accountant-certificate review, documents, referral mechanics and user-facing AI. Keep handoff and provider activity disabled until the provider approves Stock Tracker and documents the applicable account, eligibility, confirmation, withdrawal and ledger interfaces. Add its adapter, test signatures and replay handling, and complete a provider sandbox acceptance run.
6. Keep live authorisations and contractual evidence outside this repository. Populate the compliance and approval records through privileged operational procedures after sign-off. The in-app cap accounts for provider applications known to Stock Tracker. The intermediary remains authoritative for the full per-company, per-intermediary rolling cap and cooling-off deadline.

## Verification

- TradingCore passed 173 tests with one skipped. The Edge suite passed 284 tests with three ignored. The private Edge Function type check and migration test suite passed.
- Hosted AI catalogue search returned no verified open matches for Australian healthcare and retail, found Heidi's closed Series C, and asked for a currency on an ambiguous valuation filter.
- The iPhone simulator recognized an image-only ownership statement PDF and enforced the plain-text excerpt limit. A signed-in simulator test opened an encrypted excerpt, recorded the review, and linked it to a manual holding. Hosted tests verified that uppercase iOS UUIDs open the owner's report and excerpt and that another account is denied.
- A disposable Supabase stack verified the catalogue, scoped holdings populated with settlement, valuation, capital-call and distribution fixtures, and funding events that omit unpublished companies. The hosted Stock Tracker project returned the catalogue, issuer update and account-scoped holdings response. It refused anonymous private access and passed encrypted excerpt and cross-account checks. A live model returned cited answers from both a historical round and an issuer announcement, and a saved committee report with five specialist findings and a synthesis. Temporary smoke-test accounts were removed. The SQL suite verified consent controls, Australian offer gates, duplicate handoffs, provider-confirmed ownership and provider activity isolation with fixtures. Live settlement records still require an approved adapter.
- Three iPhone 17 Pro simulator tests passed on iOS 26.5. They exercised the provider directory, offline scenario calculator, private holding creation, valuation and persistence across relaunch, and Copilot’s unified exposure card.
- AngelList’s production OAuth endpoint accepted a Stock Tracker dynamic client registration with the iOS redirect. The interactive consent, token exchange and fund reads require an entitled AngelList account. Provider onboarding and investment settlement remain gated on signed agreements and compliance approval.

## Primary sources

- [Stock Tracker Private Markets pull request](https://github.com/Imazid/Stock-Tracker/pull/7)
- [Conversational discovery and ownership evidence pull request](https://github.com/Imazid/Stock-Tracker/pull/12)
- [ASIC crowd-sourced funding](https://www.asic.gov.au/crowd-sourced-funding)
- [ASIC Regulatory Guide 262](https://download.asic.gov.au/media/kdljjy4d/rg262-published-18-october-2018-20260421.pdf)
- [ASIC licensing guidance for advice and dealing](https://www.asic.gov.au/regulatory-resources/financial-services/giving-financial-product-advice)
- [OAIC commercial AI guidance](https://www.oaic.gov.au/privacy/privacy-guidance-for-organisations-and-government-agencies/guidance-on-privacy-and-the-use-of-commercially-available-ai-products)
- [Apple Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [Birchal investor process](https://www.birchal.com/investors)
- [OnMarket Financial Services Guide](https://www.onmarket.com.au/general/financial-services-guide/) and [Terms of Use](https://www.onmarket.com.au/general/terms-of-use/)
- [AngelList Meridian](https://help.angellist.com/hc/en-us/articles/38089333472269-What-is-Meridian) and [AngelList Link data and privacy](https://help.angellist.com/hc/en-us/articles/47543225581965-AngelList-Link-Data-Privacy)
- [ASX upcoming floats](https://www.asx.com.au/listings/upcoming-floats-and-listings.) and [Alvear Tungsten issuer prospectus page](https://alveartungsten.com/)
- [Heidi Series C announcement](https://www.heidihealth.com/en-gb/blog/heidi-secures-us340m-to-scale-agents-across-health-systems-globally)
- [AdvanCell Series D announcement](https://www.advancell.com.au/news/advancell-closes-us-315-million-oversubscribed-series-d-financing-to-advance-targeted-alpha-therapies-and-expand-clinical-and-commercial-manufacturing-infrastructure/)
- [MoPA issuer site](https://www.museumofplayandart.com.au/) and [public CSF offer document](https://storage.googleapis.com/birchal-uploads/209b02ce-0064-41f7-9434-3cc5cb24c84c/209b02ce-0064-41f7-9434-3cc5cb24c84c.pdf)
- [Syndex investor access](https://www.syndex.exchange/investors)
