// Sealed credential storage on top of `public.secure_credentials`.
//
// The table is reachable only with the service role (no RLS policies exist for app users),
// and every value in it is sealed by ./envelope.ts. This module is the only code that
// seals or opens those rows; it binds each one to `<purpose>:<user id>` so a row copied to
// another user does not open.

import { type Keyring, open, seal, type SealedSecret } from "./envelope.ts";
import type { SnapTradeUserRecord, SnapTradeUserStore } from "../snaptrade/proxy.ts";

export type CredentialPurpose = "snaptrade_user" | "broker_api_key";

export interface CredentialRow {
  id: string;
  user_id: string;
  purpose: CredentialPurpose;
  provider: string;
  external_ref: string | null;
  sealed: SealedSecret;
  kek_id: string;
}

export type NewCredentialRow = Omit<CredentialRow, "id">;

export type CredentialEventAction = "created" | "imported" | "revoked" | "rotated" | "deleted";

/** The few table operations the vault needs. The Edge Function binds these to supabase-js. */
export interface CredentialTable {
  findActive(userId: string, purpose: CredentialPurpose, provider: string): Promise<CredentialRow | null>;
  /** Must reject with `CredentialConflictError` on a unique-index violation. */
  insert(row: NewCredentialRow): Promise<CredentialRow>;
  revoke(id: string): Promise<void>;
  logEvent(event: { userId: string; credentialId: string | null; action: CredentialEventAction; provider: string }): Promise<void>;
}

export class CredentialConflictError extends Error {
  constructor(message = "credential already exists") {
    super(message);
    this.name = "CredentialConflictError";
  }
}

export function credentialContext(purpose: CredentialPurpose, userId: string): string {
  return `${purpose}:${userId.toLowerCase()}`;
}

/** SnapTrade identities, sealed at rest. */
export class SealedSnapTradeStore implements SnapTradeUserStore {
  constructor(private readonly table: CredentialTable, private readonly keyring: Keyring) {}

  async get(userId: string): Promise<SnapTradeUserRecord | null> {
    const row = await this.table.findActive(userId, "snaptrade_user", "snaptrade");
    if (!row || !row.external_ref) return null;
    const userSecret = await open(this.keyring, row.sealed, credentialContext("snaptrade_user", userId));
    return { snapTradeUserId: row.external_ref, userSecret };
  }

  async save(userId: string, record: SnapTradeUserRecord): Promise<void> {
    const sealed = await seal(this.keyring, record.userSecret, credentialContext("snaptrade_user", userId));
    const row = await this.table.insert({
      user_id: userId,
      purpose: "snaptrade_user",
      provider: "snaptrade",
      external_ref: record.snapTradeUserId,
      sealed,
      kek_id: sealed.kid,
    });
    await this.table.logEvent({
      userId,
      credentialId: row.id,
      action: record.snapTradeUserId.startsWith("st-") ? "created" : "imported",
      provider: "snaptrade",
    });
  }

  async remove(userId: string): Promise<void> {
    const row = await this.table.findActive(userId, "snaptrade_user", "snaptrade");
    if (!row) return;
    await this.table.revoke(row.id);
    await this.table.logEvent({ userId, credentialId: row.id, action: "revoked", provider: "snaptrade" });
  }
}
