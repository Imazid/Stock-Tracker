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
| `market-data-proxy`, `snaptrade-proxy`, `ai-proxy` | Supabase Edge Functions | signed-in iOS data, broker aggregation and model access |
| Web app | Any Node host for Next.js (Vercel fits) | `web/` |

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
   supabase functions deploy trading-api agent-scheduler broker-orders broker-connections snaptrade-proxy ai-proxy market-data-proxy
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
                               # market-data keys, ANTHROPIC_API_KEY for the AI workspace
npm ci && npm run build && npm start
```
On Vercel: import the repo with `web/` as the root directory and set the same variables. Server-only
keys (`ALPACA_*`, `ANTHROPIC_API_KEY`) must not start with `NEXT_PUBLIC_`.

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
