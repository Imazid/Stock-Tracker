// The deterministic trading engine, ported from the Swift package in TradingCore/.
// The Swift code is the specification; TradingCore/Tests/Vectors holds the shared cases
// both sides must reproduce (supabase/functions/tests/parity.test.ts checks this side).

export * from "./agent.ts";
export * from "./audit.ts";
export * from "./broker.ts";
export * as Calendar from "./calendar.ts";
export { MarketCalendar } from "./calendar.ts";
export * from "./catalog.ts";
export * from "./engine.ts";
export * from "./evaluator.ts";
export * from "./indicators.ts";
export * as Ledgers from "./ledger.ts";
export type { EquityPoint, Ledger, LedgerKind, Position } from "./ledger.ts";
export * from "./market.ts";
export * from "./orders.ts";
export * from "./risk.ts";
export * as Rounding from "./rounding.ts";
export * from "./state.ts";
export * from "./strategy.ts";
export * as Templates from "./templates.ts";
export * from "./text.ts";
export { sha256Hex } from "./sha256.ts";
