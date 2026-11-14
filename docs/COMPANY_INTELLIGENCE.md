# Company Intelligence

## Where to use it

Open **Markets** and search for a ticker, a company name, a venue-qualified ticker such as `ASX:BHP`, or an identifier such as `CIK:320193`. The existing instrument page keeps the chart, watchlist and order ticket. Company intelligence adds financials, valuation, earnings, ownership, news and filings, options, peer comparison and a company-scoped assistant.

**Research Everything** opens a structured report backed by the datasets that answered. The evidence report works without a model key. On the web, the action also starts a company-scoped synthesis when AI is configured and accessible to the user. The iPhone stock and holding details show the report in a native sheet. Signed-in US listings also show recent Finnhub publisher links, available market fundamentals and reported earnings. **Ask AI** uses the selected listing and public filing evidence after the user consents. It checks the returned citations against the evidence sent to the model and links them to the original documents.

When live filing data is unavailable, known listings can show a dated filing from the issuer catalog. Apple and BHP also include selected annual statement figures with fiscal period, filing date and reporting currency. The ASX-listed BHP share price is in AUD and the issuer reports its accounts in USD. [Apple annual filing](https://www.sec.gov/Archives/edgar/data/320193/000032019326000026/aapl-20260926.htm) · [BHP annual report](https://www.bhp.com/-/media/documents/investors/annual-reports/2026/260818_bhpannualreport2026)

## Deployment

1. Follow the existing [deployment guide](DEPLOYMENT.md) for the web app, Supabase and account features. Apply `20261114091000_company_intelligence.sql` through the normal migration workflow.
2. Set `RESEARCH_SEC_USER_AGENT` on the web server to the application name and a real operator contact. SEC requests come from the server and use a per-process request queue, bounded timeouts and backoff. SEC's published limits apply to aggregate traffic from the deployment. Use a shared gateway or limiter before scaling to multiple high-volume instances. [SEC fair access and public data](https://www.sec.gov/search-filings/edgar-search-assistance/accessing-edgar-data).
3. Set `RESEARCH_SUPABASE_SERVICE_ROLE_KEY` alongside the existing Supabase project URL to enable public SEC fact snapshots and scheduled alerts. Keep the service key, AI key and vendor keys on the server. Without persistence, the web app still reads SEC data and uses its process cache.
4. Configure optional providers using [web/.env.example](../web/.env.example). Enable display, AI transmission, and news alert retention only when the agreement covers the specific use. FMP and Massive datasets stay out of financial snapshots and CSV export. News alerts can retain the triggering headline and link with the separate retention setting.
5. Set `RESEARCH_WEB_ORIGIN` and `RESEARCH_WEB_BYPASS_SECRET` on the Supabase Edge Function and deploy `market-workspace`. The signed-in report and AI request use the existing market-data quota. The AI request also uses the shared daily AI quota and the configured `OPENAI_API_KEY` or `GEMINI_API_KEY`. The question and public filing facts go to the model. Holdings, watchlists, news and paid provider data stay outside the native AI request. A deployment with a public research origin can set `COMPANY_RESEARCH_URL` in Xcode. A debug simulator can use `-CompanyResearchURLOverride http://127.0.0.1:4328`. [Vercel automation bypass](https://vercel.com/docs/deployment-protection/methods-to-bypass-deployment-protection/protection-bypass-automation)
6. For scheduled alerts, configure a job that sends `GET /api/cron/company-alerts` with `Authorization: Bearer <CRON_SECRET>`. Each invocation claims at most 12 rules and each rule is eligible again 10 minutes after processing. Size the schedule and monitor claimed versus completed counts for the number of subscribed rules. The alert history is in the signed-in user's company page. Filing, ownership and news rules read recent source events. Price rules use the listing currency and volume rules require a consolidated feed. Price and volume re-arm after a subsequent observation outside the threshold. Deleting a rule deletes its alert history.

## Provider coverage

| Source | Connected capability | Access and known gaps |
|---|---|---|
| SEC EDGAR | US issuer lookup by name, ticker or CIK, filer profile, current and paged archive submissions, ownership filing links, issuer-wide standard XBRL facts, text search within supported primary HTML documents | Public endpoint with an operator contact and SEC fair-access limits. Standard facts are generally consolidated and omit custom taxonomy or segment detail. The source filing is linked for those details. [EDGAR APIs](https://www.sec.gov/search-filings/edgar-application-programming-interfaces) |
| Yahoo Finance | Existing instrument search, quotes and historical bars, including Australian listings | Existing unofficial feed. Coverage and stability vary. Confirm display and distribution rights before a commercial release. The app labels the source, delay, currency and adjustment. |
| Alpaca | Existing US IEX quotes and market-data fallback, plus existing crypto routes | Configured market-data account. IEX is one venue. Consolidated US display and streaming need corresponding market-data rights and integration. [Alpaca market data](https://docs.alpaca.markets/docs/about-market-data-api) |
| Financial Modeling Prep | Optional profile, ISIN/CUSIP lookup, statement fallback, news, earnings, annual consensus estimates, insider activity, current valuation multiples and provider peers | Requires a key and authorized display. Endpoint entitlements and exchange coverage vary. Company records use the exact vendor ticker, including the international suffix. Transcript, estimate-revision, recommendation and institutional history are outside this implementation. [FMP endpoints and access](https://site.financialmodelingprep.com/developer/docs) |
| Massive | Optional current US options chain with expiration filter, cursor pagination and entitled quote, open-interest and Greeks fields | Requires options and display rights. Historic chains, trade-level data, unusual-volume analytics and streaming require further integration. [Massive options](https://massive.com/options) |
| ASX | Links to the selected ASX listing and its exchange announcements | An ASX-authorized feed such as ComNews is needed for automated announcement ingestion. No scraping adapter is included. International statements depend on an entitled FMP feed. [ASX announcements and terms](https://www.asx.com.au/markets/trade-our-cash-market/announcements.ses) |
| Anthropic | Company-scoped conversation and synthesis using the existing assistant | Requires configured AI credentials and, on a production deployment, the existing sign-in flow. Optional paid data reaches the assistant only with separate authorization settings. |

## Dates, formulas and data quality

- The listing key uses the existing `venue:SYMBOL` contract. CIK identifies the SEC filer and can correspond to multiple listings or share classes. The research registry records exact mapped US listings. ASX selection never substitutes a US ADR's SEC data. The current ticker directory cannot reconstruct a historical universe or resolve all inactive symbols.
- SEC facts carry taxonomy, tag, unit, fiscal dates, filing date, original accession link and retrieval time. The cutoff is inclusive by filing day in UTC. For a point-in-time display, the latest eligible observation wins within the same concept, unit and period. Earlier submissions remain available in the versions view. Intraday availability within a filing day and historical ticker membership require a separate point-in-time dataset.
- Periods are identified from reported dates and form types. SEC facts can contain year-to-date flows without a standalone quarter. The TTM calculation uses annual plus comparable current YTD less prior YTD, when the periods line up. Each result shows its end date and input sources. A fiscal-year result can be the latest eligible TTM for an individual metric. Financial ratios use matching periods and currency. The DCF calculator uses only entered assumptions.
- Market comparison aligns common daily bar dates and rebases both series to their first overlapping close. Feed currency and price adjustments can differ. The comparison uses local-currency price series and retains the provider's adjustment labels.
- Source failures produce dataset-specific coverage, including stale SEC snapshot fallback within 14 days when configured. Available values are not inferred from gaps. SEC facts are authoritative for SEC filings. FMP fallback values retain a separate provider label and are not merged into the SEC series.
- The cutoff view is for research. It does not alter the existing trading engine or make a historical backtest point-in-time safe across delistings, ticker reuse, splits, mergers or corporate actions.

## Verification

From the repository root:

```bash
node --test web/src/server/research/financials.test.ts web/src/server/agent/agent-safety.test.ts
RESEARCH_TEST_ORIGIN=http://localhost:4328 node --test web/src/server/research/live.test.mjs
RESEARCH_TEST_ORIGIN=http://localhost:4328 RESEARCH_TEST_CHROME=/path/to/chrome node --test web/tests/company-intelligence.browser.test.mjs
psql "$BRANCH_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/company_intelligence.sql
```

The live suite expects an app with SEC access and the existing market feed. It exercises CIK and venue search, a fund, the original Apple FY2025 filing, the as-of cutoff, SEC text retrieval, US issuer coverage, AUD candles, an inactive listing, crypto eligibility and the combined evidence report. The SQL suite checks private snapshots, user isolation, restricted worker access, leases and trigger deduplication.

## Remaining coverage

Universal natural-language screening, issuer relationship graphs, global security-master history, full statement presentation and segment normalization, a restatement diff UI, historical valuation multiples, detailed analyst and ownership history, corporate actions, earnings reaction studies, macro and specialist data, automated historical backfills and event-driven ingestion remain outside this implementation. Current options coverage is entitlement-dependent. Scheduled alerts cover the implemented price, volume and publication triggers and use an in-app inbox. The implementation does not include push or email delivery, all requested alert types, AI alert summaries or a distributed alert queue.

For a public Australian release, follow the repository's [regulatory review](REGULATORY_REVIEW.md) and confirm market-data agreements and the scope of the research experience. [ASIC RG 244](https://www.asic.gov.au/regulatory-resources/find-a-document/regulatory-guides/rg-244-giving-information-general-advice-and-scaled-advice).
