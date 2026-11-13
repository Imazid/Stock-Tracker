// The providers this build can connect to, and the one place to get an adapter. The UI reads
// `PROVIDERS` to explain what each connection needs, and `capabilitiesFor` to offer only the
// operations a provider/environment actually supports.

import { alpacaAdapter } from "./alpaca.ts";
import { coinbaseAdapter } from "./coinbase.ts";
import type { AssetClass, BrokerAdapter, ProviderCapabilities, ProviderID, TradingEnvironment } from "./types.ts";

const ADAPTERS: Readonly<Record<ProviderID, BrokerAdapter>> = Object.freeze({
  alpaca: alpacaAdapter,
  coinbase: coinbaseAdapter,
});

export interface ProviderInfo {
  id: ProviderID;
  displayName: string;
  assetClasses: AssetClass[];
  /** Environments a person can connect, in the order to offer them. */
  environments: TradingEnvironment[];
  /** How to create the credentials, in plain words. */
  setup: string;
  /** What read-only and trading access mean for this provider. */
  permissions: { read: string; trade: string };
  /** Said on every provider: we never ask for this. */
  neverRequested: string;
  /** Which credential fields the connect form collects (write-only). */
  credentialFields: { name: string; label: string; secret: boolean; optional?: boolean }[];
}

export const PROVIDERS: readonly ProviderInfo[] = Object.freeze([
  {
    id: "alpaca",
    displayName: "Alpaca",
    assetClasses: ["us_equity", "crypto"],
    environments: ["paper", "live"],
    setup: "In the Alpaca dashboard, open your paper (or live) account and generate an API key. Paper and live accounts have separate keys.",
    permissions: {
      read: "Read-only: Stock Tracker reads your balances, positions, orders and fills. Alpaca keys can't be limited on Alpaca's side, so read-only is enforced by Stock Tracker never sending an order for this connection.",
      trade: "Trading: Stock Tracker may send orders you approve (paper accounts only in this release) and cancel or change them.",
    },
    neverRequested: "Stock Tracker never moves money in or out of your account — there is no transfer or withdrawal call anywhere in it.",
    credentialFields: [
      { name: "keyID", label: "API key ID", secret: false },
      { name: "secretKey", label: "Secret key", secret: true },
    ],
  },
  {
    id: "coinbase",
    displayName: "Coinbase",
    assetClasses: ["crypto"],
    environments: ["live", "sandbox"],
    setup: "In the Coinbase Developer Platform, create an API key for the portfolio you want to connect, choosing the ECDSA (ES256) signature algorithm. Coinbase keys are scoped to one portfolio.",
    permissions: {
      read: "View: Stock Tracker reads the portfolio's balances, orders and fills.",
      trade: "Trade: additionally lets Stock Tracker send orders you approve. Live crypto orders stay off until the platform's live gate is opened.",
    },
    neverRequested: "Don't give the key the Transfer permission. Stock Tracker refuses keys that can move funds out.",
    credentialFields: [
      { name: "keyName", label: "API key name (organizations/…/apiKeys/…)", secret: false },
      { name: "privateKeyPEM", label: "Private key (PEM)", secret: true },
      { name: "portfolioID", label: "Portfolio ID", secret: false, optional: true },
    ],
  },
]) as readonly ProviderInfo[];

export function adapterFor(provider: ProviderID): BrokerAdapter {
  const adapter = ADAPTERS[provider];
  if (!adapter) throw new RangeError(`unknown provider ${String(provider)}`);
  return adapter;
}

export function capabilitiesFor(provider: ProviderID, environment: TradingEnvironment): ProviderCapabilities {
  return adapterFor(provider).capabilities(environment);
}

export function providerInfo(provider: ProviderID): ProviderInfo {
  const info = PROVIDERS.find((p) => p.id === provider);
  if (!info) throw new RangeError(`unknown provider ${String(provider)}`);
  return info;
}

export function isProviderID(value: unknown): value is ProviderID {
  return value === "alpaca" || value === "coinbase";
}
