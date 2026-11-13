# Threat Model

_2026-11-13. Scope: the iOS app, `TradingCore`, and the Supabase backend (`opruuwczvrwklmwdtsaw`). Assume that the app may later be linked to real brokerage accounts. Today all trading is simulated and live execution is disabled at three layers (see `IMPLEMENTATION_PLAN.md` §2)._

## Assets

| Asset | Where it lives | Worst case if lost |
|---|---|---|
| SnapTrade consumer key | Edge Function secret | Signs requests for **every** user of the client id: read every linked brokerage |
| A person's SnapTrade user secret | `secure_credentials`, sealed | Read that person's brokerage accounts and holdings |
| Vault KEKs (`CREDENTIAL_KEKS`) | Edge Function secret (plus your offline copy) | Together with a database dump, opens every sealed credential |
| AI provider keys | Edge Function secrets | Unbounded spend |
| Alpaca market-data key pair | **Still in the app bundle** | Trades the account it belongs to, so it must be an unfunded paper account |
| Portfolio, holdings, watchlists, alerts | Postgres (RLS), device Keychain | Privacy breach, with financial-profile inference |
| Order intents and approvals (future live) | Postgres | Unauthorised or duplicate real trades |

## Trust boundaries

1. **Device ↔ server.** The device is untrusted: anything in the bundle or Keychain can be read by a determined attacker, and any request can be forged.
2. **Server ↔ providers.** Provider responses are untrusted input: they're parsed defensively and never executed.
3. **Model ↔ everything.** Model output is untrusted: it can draft, never decide. News, filings and other retrieved text is untrusted data, never instructions.
4. **User ↔ user.** RLS isolates rows, and sealed credentials are bound to their owner by AAD.

## Threats, mitigations and tests

| Threat | Mitigation | Evidence (tests) | Status |
|---|---|---|---|
| **Leaked API credentials in git** | Secrets removed from the feature branch tree; `.mcp.json` uses `${FISCAL_AI_API_KEY}`; `.gitignore` covers `SecretsConfig.swift` and `Secrets.plist` | — | **Rotation outstanding**: the values are on `main` and in history |
| **Credentials extracted from the app bundle** | SnapTrade and AI traffic goes through `snaptrade-proxy` / `ai-proxy`; release builds contain no such keys; `DebugView` and `SnapTradeClient` compile in Debug only | Release build of the branch (`IMPLEMENTATION_PLAN.md` §9) | **Done** for SnapTrade and AI; **open** for market-data keys (Phase B) |
| **Account takeover** | Supabase Auth; TOTP MFA (`MFAManager`); proxies resolve the user with `auth.getUser` on every call (revoked sessions fail); step-up (aal2) for risk-loosening actions is in flight server-side | — | Partial |
| **Cross-user data leakage** | RLS on every user table; `secure_credentials` has RLS on with **no** app-user policies; sealed values bound to `<purpose>:<user id>` via AAD; SnapTrade identity derived from the JWT user, never from the request body | `secure_credentials.test.ts` (reassigned row won't open), `snaptrade_proxy.test.ts` ("a device cannot choose whose SnapTrade identity is used"), migration checks (pending your approval, below) | **Done** (DB checks pending) |
| **Database dump** | Credentials sealed with per-secret data keys, wrapped by a KEK that's never in the database; plaintext-shaped JSON rejected by a check constraint | `secure_envelope.test.ts` (tamper, wrong context, rotation) | **Done** |
| **Privilege escalation via the proxy** | Operation allowlist (no `listUsers`, no trading, no transfers); account ids validated as UUIDs before they reach a URL; redirect allowlist; trading portals refused unless a server flag is set | `snaptrade_proxy.test.ts` | **Done** |
| **Prompt injection** (news, filings, web, tool output) | Server policy prepended to every model call, which a device can't remove; the model can't reach any order path; the copilot answers through fixed tools and never supplies numbers; strategies are validated data | `ai_proxy.test.ts` (policy always leads, model and budget fixed); TradingCore agent tests | **Done** for chat; a research agent with retrieval is deferred |
| **Runaway AI spend / abuse** | Per-user daily ceiling enforced atomically in Postgres (`consume_ai_quota`), callable only by the service role; bounded message size and count; fixed models and token budgets | `ai_proxy.test.ts`; migration checks | **Done**. The ceiling is not the subscription entitlement (receipt validation is a gap) |
| **Duplicate or unauthorised trades** | Live execution disabled (TradingCore `isExecutionEnabled = false`, an empty frozen live adapter registry and a DB constraint in the in-flight server work). Paper orders use `clientOrderID` idempotency. Approvals required for `approvalRequired` agents | TradingCore `EngineTests`, `RiskEngineTests` | **Done** for paper; live is Phase F |
| **Stale-price execution** | Risk engine rejects stale quotes; an unlisted holiday fails safe (no fresh quote, so no trade) | `RiskEngineTests`, `InternationalMarketTests` | **Done** |
| **Tampered approvals** | Paper: proposals carry the evaluated order. Live (Phase F): approval bound to an immutable intent hash, single use, expiring, re-checked against risk at submission | — | Phase F |
| **Race conditions** (concurrent orders beating limits) | Paper engine is single-writer per state. Quota uses row-locking upsert. Server-side per-account reservation is in flight | migration checks (quota) | Partial |
| **Malicious webhook payloads / replay** | No inbound webhooks exist yet. When added: signature verification, timestamp window, idempotency keys | — | N/A yet |
| **Compromised background worker** | Scheduler runs with least privilege; no worker holds live trading credentials (none exist) | — | In flight |
| **Supply chain** | Edge Functions pin `@supabase/supabase-js@2.49.4` and `jsr:@std/assert@1`; vault and signing use WebCrypto only (no third-party crypto); iOS packages pinned by `Package.resolved` | — | Partial: no automated vulnerability scan yet |
| **Provider outage** | Proxies return machine-readable 502/503/504 codes; AI fails over Gemini → OpenAI; the app labels delayed or unavailable data | `ai_proxy.test.ts`, `snaptrade_proxy.test.ts` | **Done** |
| **Loss of reconciliation state** | Paper state is local and replayable. Live (Phase F): uncertain submission moves to `reconciliation_required` and is never retried blindly | — | Phase F |
| **Logging leaks** | Proxies log only error class and code, never bodies; upstream error text is redacted of `userSecret=`; responses scrubbed of `userSecret` at any depth | `snaptrade_proxy.test.ts` | **Done** |
| **KEK loss** | Keyring supports multiple keys and rewrap; operator keeps an offline copy before setting the secret | `secure_envelope.test.ts` (rotation) | Procedure in `IMPLEMENTATION_PLAN.md` §7 |

## Database checks

`supabase/tests/secret_custody_checks.sql` checks that app users can't read or write `secure_credentials` or call `consume_ai_quota`. It also checks the uniqueness rules, that `credential_events` rejects updates and direct deletes but still cascades when an account is deleted, and that the quota never passes its limit. It only ever runs against a throwaway database: the CI `migrations` job, or `scripts/verify-migrations.sh` locally. Status: written, not yet run (see `IMPLEMENTATION_PLAN.md` §10).

## Residual risks we accept for now

- Market-data keys on the device (mitigated by using an unfunded paper account).
- The AI ceiling isn't tied to the paid tier.
- No automated dependency vulnerability scanning.
