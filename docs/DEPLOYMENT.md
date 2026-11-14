# Deployment, configuration and rollback

The dedicated Stock Tracker Supabase project is `opruuwczvrwklmwdtsaw` (Sydney).
The provisioning steps below apply when setting up a separate environment.

## Components

| Component | Where it runs | Source |
|---|---|---|
| iPhone app | App Store / TestFlight | `Stock Tracker/`, `TradingCore/` |
| Database, auth | Supabase (Postgres 17) | `supabase/migrations/` |
| `trading-api`, `agent-scheduler` | Supabase Edge Functions (Deno 2) | practice trading |
| `broker-connections`, `broker-orders` | Supabase Edge Functions | provider connections and orders |
| `provider-maintenance` | Supabase Edge Functions and Cron | provider order reconciliation and fill imports |
| `market-data-proxy`, `snaptrade-proxy`, `ai-proxy` | Supabase Edge Functions | signed-in iOS data, broker aggregation and model access |
| `market-workspace` | Supabase Edge Functions | workspace market data, fundamentals and shared backtesting |
| `account-deletion` | Supabase Edge Functions | authenticated account deletion and provider token revocation |
| Web app | Vercel (Sydney functions) | `web/` |

## 1. Create the backend (one time)

1. Create a Supabase project (owner's decision: it's paid infrastructure on anything beyond the free
   tier). Choose a region deliberately — it is an overseas disclosure under the Privacy Act if it
   isn't in Australia (`REGULATORY_REVIEW.md` D7).
2. Turn on MFA (TOTP) in Auth settings. Live orders and large paper orders need `aal2`.
3. Link and push the schema from a clean checkout of the release commit:
   ```
   supabase link --project-ref <ref>
   supabase db push            # applies supabase/migrations in order
   ```
   Then run the behaviour checks against a **branch database or a throwaway copy**, never production:
   `psql "$BRANCH_DB_URL" -At -f supabase/tests/provider_order_management.sql` and confirm the assertions pass.
4. Set function secrets (names in `supabase/functions/.env.example`):
   ```
   supabase secrets set ALPACA_DATA_KEY_ID=... ALPACA_DATA_SECRET=...
   supabase secrets set BROKER_CREDENTIALS_KEKS='{"active":"k1","keys":{"k1":"'"$(openssl rand -base64 32)"'"}}'
   supabase secrets set TRADING_SCHEDULER_SECRET=...   # practice agent scheduler (see its README)
   ```
   Keep a copy of the key ring in the team's secret manager. **Losing it makes every stored provider
   key unreadable** — people would have to reconnect.
5. Deploy the functions:
   ```
   supabase functions deploy trading-api agent-scheduler broker-orders broker-connections snaptrade-proxy ai-proxy market-data-proxy market-workspace provider-maintenance
   ```

## 2. Gates (what is switched on)

All gates start off (`public.platform_gates`). Live and automated-live are refused by CHECK
constraints and can't be switched on by an UPDATE.

- To allow orders to **Alpaca paper** accounts, an administrator runs, in the SQL editor:
  ```sql
  update public.platform_gates set enabled = true, updated_by = '<name>', updated_at = now()
  where id = 'provider_paper_execution';
  ```
  Do this only after confirming Alpaca's terms allow third-party order entry for paper accounts
  (`REGULATORY_REVIEW.md` D9).
- Real money: see `REGULATORY_REVIEW.md` §3. It takes a reviewed migration plus code change.

## 3. Web app

```
cd web
cp .env.example .env.local     # fill NEXT_PUBLIC_SUPABASE_URL / NEXT_PUBLIC_SUPABASE_ANON_KEY,
                               # market-data keys, ANTHROPIC_API_KEY or OPENAI_API_KEY for the AI workspace
npm ci && npm run build && npm start
```
On Vercel, use `web/` as the project root and include its shared Supabase source files from
the repository. Run `vercel deploy --prod` from the repository root. The Stock Tracker release
project uses Vercel Authentication on every deployment. Keep production and previews private
while using the existing market-data account. The Stock Tracker sign-in separately controls
access to each person's portfolios, watchlist and paper orders. Keep `ALPACA_*`,
`ANTHROPIC_API_KEY` and `OPENAI_API_KEY` server-side.

Set `WORKSPACE_OVERVIEW_SECRET` to the same randomly generated value in Vercel and the Supabase
function secrets. Set `FINNHUB_API_KEY` in Supabase for US fundamentals and news. Set
`ENABLE_AI` and `ENABLE_SNAPTRADE` in Vercel after configuring the corresponding shared Edge
Functions. Allowlist the production workspace URL in Supabase Auth. Standard Supabase hosted
email limits apply until a custom SMTP sender is configured.

## 4. Local development

- Database + functions: `supabase start` in the repo root (API on port 58321), then
  `supabase functions serve --env-file supabase/functions/.env`.
- Tests: `cd TradingCore && swift test`; `npx -y deno test --no-check=remote --allow-read --allow-env supabase/functions/tests/*.test.ts`
  (unit tests); the Postgres integration test needs a throwaway database
  (`OMS_TEST_DB_URL=... npx -y deno test --allow-net --allow-env --allow-read supabase/functions/tests/oms_pg.integration.test.ts`);
  web: `cd web && npm run lint && npx tsc --noEmit && npm run build`.

## 5. Release checklist

1. All test suites green on the release commit (Swift, Deno unit, SQL checks on a branch DB, web build).
2. `supabase db push --dry-run` shows only the expected migrations.
3. Deploy functions, then the web app, then (if changed) submit the iPhone build.
4. Smoke test signed in as a test user: market page loads with labelled data; a practice order fills;
   with the paper gate on, a provider paper order goes draft → risk → approve → submit → filled.
5. Watch for intents stuck in `submitting` or `reconciliation_required` (`select status, count(*) from
   public.order_intents group by 1`).

## 6. Rollback

- **Functions:** redeploy the previous release commit's functions (`git checkout <prev>` then
  `supabase functions deploy ...`). Functions are stateless; this is safe at any time.
- **Web app:** promote the previous deployment (Vercel: "Promote to production" on the prior build).
- **Gates:** turning `provider_paper_execution` off stops new provider orders immediately; orders
  already at the provider are not cancelled by that — cancel them from Orders or at the provider.
- **Database:** migrations are forward-only. To undo one, write a new migration that reverses it;
  never edit or delete an applied migration. Back up first (`supabase db dump`), and never drop
  `order_intents`, `order_intent_transitions`, `oms_events` or `broker_fills` — they are the record of
  what was sent.
- **Credential key ring:** rotation is additive (add k2, make it active, re-wrap, then retire k1).
  Never remove a key while rows still reference it (`select kek_id, count(*) from
  public.broker_credentials group by 1`).

## 7. iOS build configuration

Copy `Stock Tracker/SecretsConfig.swift.template` to `Stock Tracker/SecretsConfig.swift` and copy the plist example to `Stock Tracker/Config/Secrets.plist`. Set `SupabaseURL` and `SupabaseAnonKey` to the target project's URL and public client key. The build copies only those two values into release bundles. A clean checkout can build with no plist. Debug builds can use local keys for development with no backend.

Set the SnapTrade partner credentials, AI credentials and optional market provider keys in Supabase. The complete names are in `supabase/functions/.env.example`. Use distinct encryption key rings for the SnapTrade and provider-order vaults. The hosted project has Keychain recovery copies in `stock-tracker-credential-kek` and `stock-tracker-broker-credential-kek`.

### Privacy policy and App Store details

The iPhone Settings screen includes the privacy notice and service terms. The web routes `/privacy` and `/terms` render the review copy without a Stock Tracker account. Deployment-level Vercel authentication still applies on the private workspace. Use a public host for the approved copies and check both URLs in a signed-out browser before submitting. Set `STOCK_TRACKER_PRIVACY_EMAIL` on the legal-page build to the monitored privacy contact. Set the iOS build variable `STOCK_TRACKER_PRIVACY_POLICY_URL` to the same approved HTTPS privacy URL used in App Store Connect. The app also keeps the notice readable offline.

The app’s privacy manifest declares its use of app-local and App Group preferences. The widget has its own App Group declaration. iPhone account identity, synced financial information, research content, push tokens and subscriptions are covered by the app’s first-party manifest. Review the bundled Google Mobile Ads and User Messaging Platform manifests alongside the first-party declaration before completing App Store privacy labels. Confirm the public legal entity name, monitored contact, recipients and processing locations, retention and backup policy, and account-data request procedure during release review. [Apple App Store privacy details](https://developer.apple.com/app-store/app-privacy-details/) · [OAIC APP 1 guidance](https://www.oaic.gov.au/privacy/australian-privacy-principles/australian-privacy-principles-guidelines/chapter-1-app-1-open-and-transparent-management-of-personal-information)

## 8. Provider maintenance

Enable `pg_cron` and `pg_net` before applying the provider maintenance migration. If the extensions are enabled later, register the job using `select cron.schedule('provider-maintenance', '* * * * *', 'select public.invoke_provider_maintenance()');`. The job checks up to four due order intents and syncs fills for up to two connections on each run. The worker has no execution or cancellation path.

Store a dedicated random scheduler secret of at least 32 characters as `PROVIDER_MAINTENANCE_SECRET` for the Edge Function and `provider_maintenance_secret` in Supabase Vault. Store the full HTTPS Edge Function endpoint in Vault as `provider_maintenance_url`. Deploy the function with gateway JWT verification off. The worker authenticates the Vault secret using the `x-scheduler-secret` header.

Verify that the unauthenticated endpoint returns 401. Confirm scheduled requests in the `provider_maintenance` Edge Function logs, which report counts for claimed orders, connections, imported fills and errors. A cron run reports delivery to pg_net. Check the HTTP response or function logs for the worker result.

## 9. Scheduled SnapTrade activity

Deploy `snaptrade-activity-sync` and `snaptrade-proxy`. Set a dedicated secret of at least 32 characters as `SNAPTRADE_ACTIVITY_SYNC_SECRET` on the Edge Function and `snaptrade_activity_secret` in Supabase Vault. Set `snaptrade_activity_url` in Vault to the full HTTPS sync endpoint. Use `pg_cron` and `pg_net` as for provider maintenance. If the extensions are enabled after applying the migration, register `select cron.schedule('snaptrade-activity-sync', '* * * * *', 'select public.invoke_snaptrade_activity_sync()');`.

## Account deletion

Apply the database migrations before deploying `account-deletion`. The function verifies the Supabase user and active session, and requires password confirmation or a fresh Sign in with Apple authorization code. An account with verified MFA must use an elevated session. The server removes an active SnapTrade connection before deleting the Supabase user and its dependent data.

For Sign in with Apple, enable the capability for the iOS app identifier `Cubeplay.Stock-Tracker` and add it to the Stock Tracker target in Xcode. Regenerate the signing profiles and verify that the signed iOS app includes the Sign in with Apple entitlement. Configure the server secrets `ACCOUNT_DELETION_APPLE_TEAM_ID`, `ACCOUNT_DELETION_APPLE_KEY_ID` and `ACCOUNT_DELETION_APPLE_PRIVATE_KEY` using a Sign in with Apple key for the app. Test from Account settings with a disposable Apple sign-in and verify Apple token revocation and Supabase account deletion. [Apple’s signing configuration](https://developer.apple.com/documentation/xcode/configuring-sign-in-with-apple) · [Apple’s account deletion requirements](https://developer.apple.com/support/offering-account-deletion-in-your-app/)

Each tick leases up to three SnapTrade identities and processes one provider request per identity. It publishes a 90-calendar-day snapshot once all accounts and pages are read, then schedules the next refresh 24 hours later. The portfolio editor prefers a complete snapshot synced in the past 36 hours. It offers a live broker read for other dates and on request. A revoked identity deletes its staged and published activity. Scheduler logs contain counts and error codes.

## 10. Provider monitoring and response

Apply the provider operations migration, then deploy `provider-maintenance`, `snaptrade-activity-sync` and `broker-orders` with their existing gateway settings. The first two report completed runs, durations, job and error counts, and allowlisted error categories. They use their existing scheduler and database credentials. Run reports expire after 30 days and resolved alerts after 90 days.

The `provider-operations-check` job runs every minute. It opens an alert when a worker has no report for five minutes, a worker records three failing runs within 15 minutes, an order spends five minutes in `submitting`, or an order spends ten minutes in `reconciliation_required`. It records one open alert per condition and worker or provider environment. It logs an `opened` or `resolved` event in Postgres when a condition changes. Check the database logs or the private alerts table. External paging requires a configured log destination.

If `pg_cron` was enabled after applying the migration, register `provider-operations-check` and `provider-operations-retention` using the schedules in the migration. The jobs run as the migration owner. As a database operator, check both the worker reports and the alert check's cron history. A successful cron invocation that queues a worker request does not prove the worker completed.

```sql
select condition, subject, observed_count, opened_at, last_seen_at
from provider_operations.alerts where resolved_at is null order by opened_at;

select worker, max(finished_at) as last_report, sum(jobs) as jobs, sum(errors) as errors,
  count(*) filter (where errors > 0) as failing_runs, count(*) as runs
from provider_operations.worker_runs where finished_at >= now() - interval '15 minutes'
group by worker;

select worker, finished_at, duration_ms, jobs, errors, failure_codes
from provider_operations.worker_runs where errors > 0 order by finished_at desc limit 30;

select * from provider_operations.submit_summary_24h;
```

For a missing worker report, check its cron history, worker deployment, scheduler secret configuration and recent function logs. For repeated errors, check the recorded category and the provider's status before changing credentials or retry settings. For an unresolved order, locate the affected intent in the flagged provider environment and reconcile it using the existing order workflow. Check the provider's order and fill records before taking further action. Sending a new order while the outcome remains unknown can duplicate execution.

The submission summary reports the last 24 hours of recorded outcomes by provider and environment. Its latency measures the adapter call and includes preflight refusals. The `latency_samples` column gives the number of measurements behind the percentile. A blank percentile means there are no timed outcomes in the window.
