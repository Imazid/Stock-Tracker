// Platform and compliance gates: what this deployment is allowed to do at all.
//
// Gates are stored server-side (public.platform_gates), writable only by the service role
// (an administrator acting through a reviewed process), readable by signed-in users so the UI
// can explain why something is off. They default OFF. A frontend flag never enables trading:
// every path that could reach a provider calls `requireGate` with the gate row it just read.
//
// The gates are layered under the person's own controls, not instead of them:
//   platform gate  →  person's kill switch  →  connection permission  →  risk engine  →  approval
// Every layer must say yes.

import type { GateID } from "./api.ts";
import type { TradingEnvironment } from "../brokers/types.ts";

export interface GateRow {
  id: GateID;
  enabled: boolean;
  reason: string;
  updatedAt?: string;
}

export const GATE_IDS: readonly GateID[] = [
  "provider_paper_execution",
  "live_execution",
  "automated_live_execution",
  "personalised_recommendations",
  "custodial_features",
];

/** What each gate means, and why it's off by default. Shown to people and administrators. */
export const GATE_DEFAULTS: Record<GateID, { enabled: false; reason: string }> = {
  provider_paper_execution: {
    enabled: false,
    reason: "Orders to a provider's paper (practice) account. No real money; off until an administrator enables it for this deployment.",
  },
  live_execution: {
    enabled: false,
    reason: "Real-money orders. Off until Australian licensing (AFSL / authorised representative), the provider's agreement and an operational review are complete. See docs/REGULATORY_REVIEW.md.",
  },
  automated_live_execution: {
    enabled: false,
    reason: "Agent orders without a per-order approval (a mandate). Off; requires legal review of discretionary/managed-account obligations.",
  },
  personalised_recommendations: {
    enabled: false,
    reason: "Agent output phrased as advice for this person's circumstances (personal advice under the Corporations Act). Agents give factual information and general analysis only.",
  },
  custodial_features: {
    enabled: false,
    reason: "Holding or moving customer assets. Out of scope; never enabled in this product.",
  },
};

export class GateClosedError extends Error {
  constructor(readonly gate: GateID, readonly reason: string) {
    super(reason);
    this.name = "GateClosedError";
  }
}

/** Fills in any gate missing from storage as OFF. Unknown ids in storage are ignored. */
export function resolveGates(rows: GateRow[]): Record<GateID, GateRow> {
  const out = {} as Record<GateID, GateRow>;
  for (const id of GATE_IDS) out[id] = { id, ...GATE_DEFAULTS[id] };
  for (const row of rows) {
    if (GATE_IDS.includes(row.id)) out[row.id] = { id: row.id, enabled: row.enabled === true, reason: row.reason || GATE_DEFAULTS[row.id].reason, updatedAt: row.updatedAt };
  }
  // Defence in depth: these two can only be on together with live execution.
  if (!out.live_execution.enabled) {
    out.automated_live_execution = { ...out.automated_live_execution, enabled: false };
  }
  out.custodial_features = { ...out.custodial_features, enabled: false };
  return out;
}

/** The gate that governs sending an order to a provider in this environment. */
export function gateForEnvironment(environment: TradingEnvironment, automated: boolean): GateID[] {
  if (environment === "live") return automated ? ["live_execution", "automated_live_execution"] : ["live_execution"];
  // Provider-hosted paper and sandbox venues: no real money, still a provider call.
  return ["provider_paper_execution"];
}

export function requireGates(gates: Record<GateID, GateRow>, ids: GateID[]): void {
  for (const id of ids) {
    const gate = gates[id];
    if (!gate?.enabled) throw new GateClosedError(id, gate?.reason ?? GATE_DEFAULTS[id].reason);
  }
}
