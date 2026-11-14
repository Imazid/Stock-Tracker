import { errorResponse, HttpError, json, readJSONObject, refusal } from "../_shared/server/http.ts";

export interface AccountOwner {
  id: string;
  email?: string;
  appleSubject?: string;
  needsMFA: boolean;
}

export interface AccountDeletionDependencies {
  owner(request: Request): Promise<AccountOwner>;
  confirmPassword(owner: AccountOwner, password: string): Promise<void>;
  confirmApple(subject: string, code: string): Promise<() => Promise<void>>;
  disconnectBroker(owner: string): Promise<boolean>;
  deleteUser(owner: string): Promise<void>;
}

export async function deleteAccount(request: Request, deps: AccountDeletionDependencies): Promise<Response> {
  try {
    if (request.method !== "POST") return refusal(405, "method_not_allowed", "Use POST.");
    const owner = await deps.owner(request);
    if (owner.needsMFA) {
      throw new HttpError(403, "step_up_required", "Verify your authenticator code before deleting your account.");
    }
    const body = await readJSONObject(request, 8_192);
    if (body.confirm !== true || Object.keys(body).some((key) => !["confirm", "password", "appleCode"].includes(key))) {
      throw new HttpError(400, "confirmation_required", "Confirm that you want to delete this account.");
    }

    let revokeApple: (() => Promise<void>) | undefined;
    if (owner.appleSubject) {
      if (typeof body.appleCode !== "string" || body.appleCode.length === 0 || body.appleCode.length > 2_048) {
        throw new HttpError(400, "apple_required", "Confirm with Sign in with Apple.");
      }
      revokeApple = await deps.confirmApple(owner.appleSubject, body.appleCode);
    } else {
      if (typeof body.password !== "string" || body.password.length === 0 || body.password.length > 1_024) {
        throw new HttpError(400, "password_required", "Enter your account password.");
      }
      await deps.confirmPassword(owner, body.password);
    }
    const brokerDeletionQueued = await deps.disconnectBroker(owner.id);
    await revokeApple?.();
    await deps.deleteUser(owner.id);
    return json(200, { deleted: true, brokerDeletionQueued });
  } catch (error) {
    if (error instanceof HttpError) return errorResponse(error);
    console.error("account_deletion_failed");
    return refusal(503, "deletion_unavailable", "Account deletion could not be confirmed. Try again.");
  }
}
