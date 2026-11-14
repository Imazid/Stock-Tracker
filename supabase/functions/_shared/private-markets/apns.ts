import { fromBase64, toBase64, utf8 } from "../secure/encoding.ts";

export type PushEnvironment = "sandbox" | "production";
export type PushResult = "accepted" | "invalid" | "retry";

const hosts: Record<PushEnvironment, string> = {
  sandbox: "api.sandbox.push.apple.com",
  production: "api.push.apple.com",
};

function base64url(bytes: Uint8Array): string {
  return toBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function pushEnvironment(value: unknown): value is PushEnvironment {
  return value === "sandbox" || value === "production";
}

export function validDeviceToken(value: unknown): value is string {
  // Apple specifies a variable-length token. Bound the encoded input without
  // relying on the current token size.
  return typeof value === "string" && /^(?:[0-9a-f]{2}){16,128}$/i.test(value);
}

export class ApnsSender {
  private key?: Promise<CryptoKey>;
  private authorization?: { token: Promise<string>; expiresAt: number };

  constructor(
    private readonly settings: { team: string; keyId: string; privateKey: string; environment: PushEnvironment },
    private readonly request: typeof fetch,
  ) {
    if (!/^[A-Z0-9]{10}$/.test(settings.team) || !/^[A-Z0-9]{10}$/.test(settings.keyId)) {
      throw new Error("APNs team or key identifier is invalid");
    }
  }

  private async sign(iat: number): Promise<string> {
    if (!this.key) {
      const der = fromBase64(this.settings.privateKey.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\\n|\s/g, ""));
      this.key = crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    }
    const header = base64url(utf8(JSON.stringify({ alg: "ES256", kid: this.settings.keyId })));
    const claims = base64url(utf8(JSON.stringify({ iss: this.settings.team, iat })));
    const message = header + "." + claims;
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await this.key, utf8(message));
    return message + "." + base64url(new Uint8Array(signature));
  }

  async send(deviceToken: string, lease: string, now = Date.now()): Promise<PushResult> {
    if (!validDeviceToken(deviceToken)) return "invalid";
    if (!this.authorization || this.authorization.expiresAt <= now) {
      // Reuse a signed token per worker and key, then renew before Apple's one-hour limit.
      this.authorization = { token: this.sign(Math.floor(now / 1_000)), expiresAt: now + 50 * 60_000 };
    }
    const authorization = await this.authorization.token;
    const response = await this.request("https://" + hosts[this.settings.environment] + "/3/device/" + deviceToken, {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(8_000),
      headers: {
        authorization: "bearer " + authorization,
        "apns-id": lease,
        "apns-topic": "Cubeplay.Stock-Tracker",
        "apns-push-type": "alert",
        "apns-priority": "5",
        "apns-expiration": "0",
        "apns-collapse-id": "private-markets-updates",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        aps: { alert: { title: "Private Markets update", body: "Open Stock Tracker to see what’s new." }, sound: "default" },
        privateMarkets: true,
      }),
    });
    if (response.status === 200) {
      await response.body?.cancel();
      return "accepted";
    }
    const payload = await response.json().catch(() => ({})) as { reason?: string };
    if (response.status === 410 || payload.reason === "BadDeviceToken" || payload.reason === "DeviceTokenNotForTopic") {
      return "invalid";
    }
    console.warn("private push not accepted", response.status);
    return "retry";
  }
}
