# Threat model — provider connections, orders and agents

Scope: the parts that could move money or leak financial data: provider connections and
credentials, the order management system (OMS), the agents that propose orders, the web and
iPhone clients, and the Supabase backend. Written 2026-11-13; the "Test" column names the
automated check that would fail if the mitigation regressed. "Gap" marks something not yet
mitigated.

Assets, in order of harm if lost: (1) the ability to place orders in a person's provider
account, (2) provider credentials, (3) portfolio, order and identity data, (4) the integrity of
the audit trail, (5) availability.

Trust boundaries: browser/iPhone ⇄ edge functions (JWT); edge functions ⇄ Postgres (service
role); edge functions ⇄ providers (sealed credentials, opened per call); edge functions ⇄ model
providers (no secrets, no credentials, retrieved text treated as untrusted).

| # | Threat | Mitigation | Test |
|---|---|---|---|
| T1 | **Account takeover** → attacker approves orders | Approvals need the owner's session; live (and paper ≥ A$/US$25k) approvals and submissions need `aal2` (MFA) at both steps; approvals expire in 2 minutes; kill switch stops everything. Supabase Auth: session expiry, refresh rotation. **Gap:** device/session list and revocation UI; suspicious-activity alerts. | `oms.test.ts` "approve: … step-up", "refusals … live without aal2" |
| T2 | **Leaked provider credentials** (DB dump, logs, client) | Envelope encryption (AES-256-GCM, per-secret DEK, KEK only in function secrets); AAD binds user+connection+provider so a copied blob won't open; `broker_credentials` has RLS with no policies and SELECT revoked; CHECK refuses plaintext field names; revoke deletes the sealed row; keys never returned (only a 4-char hint); adapters never put keys in errors. Request read-only or trade-only scopes, never withdrawal/transfer. **Gap:** KEK in env, not a KMS; rotation runbook. | `vault.test.ts`; SQL checks "reading the vault…", "plaintext secretKey", "credentials left after revoke: 0" |
| T3 | **Leaked keys in the iPhone bundle / public git history** (exists today) | Provider trading keys are only ever server-side on this path. **Gap (owner action):** rotate Fiscal.ai, Alpha Vantage, SnapTrade keys; move remaining data keys behind functions. | — |
| T4 | **Prompt injection** via news, filings, web pages, tool output, another user's content | Models never hold credentials or call order endpoints. An agent can only *draft* an intent (origin `agent`, rationale required); drafting is not approval; approval is a separate authenticated request by the owner bound to the intent hash. Practice: model JSON goes through `decodeDraft` (live modes downgraded) and `StrategyValidator`. Retrieved text is passed as quoted data, never merged into system instructions. **Gap:** live-model injection evals for the web AI workspace remain open. | `oms.test.ts` (agent origin can't submit without owner approval); TradingCore `StrategyTests` (decodeDraft downgrade) |
| T5 | **Privilege escalation** (agent raises its own limits/permissions; client writes rows) | Clients have SELECT only on every OMS table; all writes via functions using the service role after checks; `oms_consume_approval` not executable by clients; gates writable only by service role; live gates refused by CHECK. Agents get no tool that edits risk policy or gates. | SQL checks "a client inserting an intent directly", "a client consuming an approval", "enabling live by UPDATE" |
| T6 | **Cross-user data leakage** | RLS `user_id = auth.uid()` on every table; user id always from the JWT, never the body; pipeline checks connection owner = intent owner = caller. | SQL check "A sees intents: 1" (not B's); `oms.test.ts` "another user can't submit" |
| T7 | **Duplicate or unauthorised trades** (double click, retries, concurrent requests, replays) | Single-use approval consumed atomically in SQL; `approved → submitting` compare-and-set; our `clientOrderID` is the provider idempotency key; `Idempotency-Key` on every state-changing call; unique `(user_id, client_order_id)`; submissions never retried. | `oms.test.ts` "second submit…", "concurrent submits…"; SQL "consume #2 → false" |
| T8 | **Timeout after the provider accepted** → second order | Unknown outcome ⇒ `reconciliation_required`; DB forbids `reconciliation_required → submitting`; lookup by client order id; give up to `failed` only after 10 minutes with no provider record. | `oms.test.ts` "timeout after the provider accepted…", "unknown outcome … refuses resubmission"; SQL "resubmitting from reconciliation_required" |
| T9 | **Stale-price execution** | Risk re-run at submission on a freshly fetched quote; refuse if older than `maxQuoteAgeMs`; practice engine refuses synthetic/fixture data and stale quotes; every displayed price carries source/time/status. | `oms.test.ts` "stale price" |
| T10 | **Tampered approvals** (change qty/price after approval, approve someone else's intent, extend expiry) | Approval stores the intent hash; submit recomputes the hash from the stored row; DB refuses edits to hashed fields, approvals by non-owners, mismatched hashes, and any change to an approval. | `oms.test.ts` "approval for another order"; SQL "editing the quantity…", "approval for a different hash", "extending an approval" |
| T11 | **Malicious webhook payloads / replay** | `provider_webhook_events` primary key `(provider, event_id)` + payload hash for dedup; fills deduped on `(connection_id, provider_fill_id)`; webhooks only trigger a *reconcile* (we re-read state from the provider's API), never trust payload amounts. **Gap:** signature verification per provider when webhooks are wired (none consumed yet). | SQL unique keys (structural) |
| T12 | **Race conditions** (two orders each within limits, together over) | Risk → consume → `submitting` runs under a per-user lock (advisory lock in production); reserving states count against limits. | `oms.test.ts` "under the lock, two orders…" (also proves the race without the lock) |
| T13 | **Compromised background worker** | Worker uses the same pipeline; can't approve (approval requires an owner session); can't enable gates; kill switch is checked on every submit. **Gap:** separate least-privilege DB role for the scheduler. | — |
| T14 | **Supply-chain dependency attack** | Engine and OMS are dependency-free TypeScript; Deno tests pin `jsr:@std/assert@1`; web app lockfile committed. **Gap:** `npm audit`/Dependabot in CI; CI checks the server, migrations, and iOS builds. | — |
| T15 | **Provider outage / rate limiting** | Reads retried with backoff + jitter, honouring Retry-After; submissions fail closed; UI shows "couldn't reach provider — nothing was sent". | `brokers_http.test.ts` (brokers branch) |
| T16 | **Loss of reconciliation state** (missed stream events, crashed function mid-submit) | Every transition persisted before and after the provider call; an intent left in `submitting`/`reconciliation_required` is picked up by reconcile (scheduler or manual); provider is the source of truth for order state; fills ingested idempotently. **Gap:** scheduled reconcile job. | `oms.test.ts` "reconcile: partial fill then fill" |
| T17 | **Misleading output** (hallucinated sources, paper results presented as real) | Practice results labelled "Practice"; backtests list assumptions; research must cite sources with timestamps; gate `personalised_recommendations` off. **Gap:** source-verification evals for the web AI workspace. | — |
| T18 | **Audit tampering** | `order_intent_transitions` and `oms_events` append-only by trigger; practice `audit_events` hash-chained. **Gap:** hash-chain OMS events too. | SQL "deleting the transition log", "editing an OMS event" |

## Operational controls still to build

Monitoring of unknown-order-status counts, provider error rates and submit latency; alerting on
any intent older than 5 minutes in `submitting`; a runbook for KEK rotation and for a provider
incident; web checks in CI and dependency scanning.

## SnapTrade and AI proxy controls

| Threat | Mitigation | Evidence (tests) | Status |
|---|---|---|---|
| **Leaked API credentials in git** | Secrets removed from the feature branch tree; `.mcp.json` uses `${FISCAL_AI_API_KEY}`; `.gitignore` covers `SecretsConfig.swift` and `Secrets.plist` | — | **Rotation outstanding**: the values are in Git history |
| **Credentials extracted from the app bundle** | SnapTrade and AI traffic goes through `snaptrade-proxy` / `ai-proxy`; release builds contain no such keys; `DebugView` and `SnapTradeClient` compile in Debug only | Release iOS build | **Done** for SnapTrade and AI; **open** for market-data keys  |
| **Cross-user data leakage** | RLS on every user table; `secure_credentials` has RLS on with **no** app-user policies; sealed values bound to `<purpose>:<user id>` via AAD; SnapTrade identity derived from the JWT user, never from the request body | `secure_credentials.test.ts` (reassigned row won't open), `snaptrade_proxy.test.ts` ("a device cannot choose whose SnapTrade identity is used"), migration checks | **Done** |
| **Database dump** | Credentials sealed with per-secret data keys, wrapped by a KEK that's never in the database; plaintext-shaped JSON rejected by a check constraint | `secure_envelope.test.ts` (tamper, wrong context, rotation) | **Done** |
| **Privilege escalation via the proxy** | Operation allowlist (no `listUsers`, no trading, no transfers); account ids validated as UUIDs before they reach a URL; redirect allowlist; trading portals refused unless a server flag is set | `snaptrade_proxy.test.ts` | **Done** |
| **Runaway AI spend / abuse** | Per-user daily ceiling enforced atomically in Postgres (`consume_ai_quota`), callable only by the service role; bounded message size and count; fixed models and token budgets | `ai_proxy.test.ts`; migration checks | **Done**. The ceiling is not the subscription entitlement (receipt validation is a gap) |
| **Logging leaks** | Proxies log only error class and code, never bodies; upstream error text is redacted of `userSecret=`; responses scrubbed of `userSecret` at any depth | `snaptrade_proxy.test.ts` | **Done** |
| **KEK loss** | Keyring supports multiple keys and rewrap; operator keeps an offline copy before setting the secret | `secure_envelope.test.ts` (rotation) | Procedure in `IMPLEMENTATION_PLAN.md` §9 |

The throwaway database checks in `supabase/tests/secret_custody_checks.sql` cover RLS denial, credential uniqueness, the append-only event log, account deletion and quota limits.

## Market-data proxy

Native release bundles contain only the public Supabase URL and client key. The market-data function resolves the user with Supabase Auth, rejects requests outside its read-only path and parameter allowlists, and enforces a database-backed limit per user. It sends provider keys only to fixed HTTPS hosts and refuses redirects. An anonymous user can use public sources, subject to their availability.
