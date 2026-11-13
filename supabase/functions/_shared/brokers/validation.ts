// Checks every adapter runs before an order request leaves the building. They are about the
// request's SHAPE against what the provider can do (capabilities) — not about whether the
// order is wise or allowed; that is the risk engine and the approval in ../oms.

import { isDecimal, isFractional, isPositiveDecimal } from "./decimal.ts";
import {
  type AdapterContext,
  BrokerError,
  type BrokerOrderRequest,
  type OrderCapability,
  type ProviderCapabilities,
} from "./types.ts";

/** Our clientOrderID rule: 1–48 of [A-Za-z0-9-]. Both providers accept this. */
export const CLIENT_ORDER_ID = /^[A-Za-z0-9-]{1,48}$/;

/** Throws `environment_refused` for a money-moving call on live without the OMS's explicit allowance. */
export function assertMoneyMovementAllowed(ctx: AdapterContext, what: string): void {
  if (ctx.environment === "live" && ctx.allowLive !== true) {
    throw new BrokerError(
      "environment_refused",
      `Refused to ${what} on a live account: real-money orders are only sent after the platform's live gate, the person's approval and the risk checks have all passed.`,
    );
  }
}

/** The capability entry for the request's asset class, or throws `unsupported`. */
export function capabilityFor(capabilities: ProviderCapabilities, request: BrokerOrderRequest): OrderCapability {
  if (!capabilities.executionAvailable) {
    throw new BrokerError("unsupported", `${capabilities.provider} can't place orders in the ${capabilities.environment} environment.`);
  }
  const capability = capabilities.orders.find((c) => c.assetClass === request.assetClass);
  if (!capability) throw new BrokerError("unsupported", `${capabilities.provider} doesn't trade ${request.assetClass} here.`);
  return capability;
}

/** Shape checks common to every provider. Returns the capability that applies. */
export function validateOrderRequest(capabilities: ProviderCapabilities, request: BrokerOrderRequest): OrderCapability {
  const invalid = (message: string) => new BrokerError("invalid_request", message);
  if (!CLIENT_ORDER_ID.test(request.clientOrderID)) throw invalid("clientOrderID must be 1–48 letters, digits or hyphens.");
  if (!request.symbol || request.symbol.trim() !== request.symbol) throw invalid("symbol is required.");
  if (request.side !== "buy" && request.side !== "sell") throw invalid("side must be buy or sell.");
  const hasQuantity = request.quantity !== undefined;
  const hasNotional = request.notional !== undefined;
  if (hasQuantity === hasNotional) throw invalid("Give exactly one of quantity or notional.");
  if (hasQuantity && !isPositiveDecimal(request.quantity)) throw invalid("quantity must be a positive decimal string.");
  if (hasNotional && !isPositiveDecimal(request.notional)) throw invalid("notional must be a positive decimal string.");
  const needsLimit = request.type === "limit" || request.type === "stop_limit";
  const needsStop = request.type === "stop" || request.type === "stop_limit";
  if (needsLimit !== (request.limitPrice !== undefined)) {
    throw invalid(needsLimit ? "A limit price is required for this order type." : "A limit price isn't used by this order type.");
  }
  if (needsStop !== (request.stopPrice !== undefined)) {
    throw invalid(needsStop ? "A stop price is required for this order type." : "A stop price isn't used by this order type.");
  }
  if (request.limitPrice !== undefined && !isPositiveDecimal(request.limitPrice)) throw invalid("limitPrice must be a positive decimal string.");
  if (request.stopPrice !== undefined && !isPositiveDecimal(request.stopPrice)) throw invalid("stopPrice must be a positive decimal string.");

  const capability = capabilityFor(capabilities, request);
  const unsupported = (message: string) => new BrokerError("unsupported", message);
  if (!capability.orderTypes.includes(request.type)) {
    throw unsupported(`${capabilities.provider} doesn't accept ${request.type} orders for ${request.assetClass}.`);
  }
  const tifs = capability.timeInForce[request.type] ?? [];
  if (!tifs.includes(request.timeInForce)) {
    throw unsupported(`${capabilities.provider} doesn't accept time in force "${request.timeInForce}" for ${request.type} ${request.assetClass} orders (allowed: ${tifs.join(", ") || "none"}).`);
  }
  if (hasNotional && !capability.notional) throw unsupported(`${capabilities.provider} doesn't accept notional (cash amount) orders for ${request.assetClass}.`);
  if (hasQuantity && isFractional(request.quantity!) && !capability.fractional) {
    throw unsupported(`${capabilities.provider} doesn't accept fractional quantities for ${request.assetClass}.`);
  }
  return capability;
}

/** Reads a decimal-string field from a provider payload, or undefined. Numbers are refused, not converted. */
export function decimalField(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key];
  return isDecimal(value) ? value : undefined;
}

export function stringField(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

export function asRecord(value: unknown, what: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new BrokerError("unexpected_response", `The provider's ${what} couldn't be read.`);
  }
  return value as Record<string, unknown>;
}

export function asArray(value: unknown, what: string): unknown[] {
  if (!Array.isArray(value)) throw new BrokerError("unexpected_response", `The provider's ${what} couldn't be read.`);
  return value;
}
