import { lotUnits } from "./lot-numbers.ts";
import { receivingSnapshotFields, sydneyDate, transferHoldingFields, type ReceivingSnapshot, type TransferHolding } from "./portfolio-transfers.ts";

export type StockSpinOff = {
  id: string;
  parent_holding_id: string;
  child_holding_id: string;
  effective_on: string;
  parent_shares: string;
  child_shares: string;
  child_basis_pct_usd: string | null;
  child_basis_pct_aud: string | null;
  average_aud_basis: boolean;
  statement_reference: string;
  child_snapshot_id: string | null;
  updated_at: string;
  parent: TransferHolding | null;
  child: TransferHolding | null;
  child_snapshot: ReceivingSnapshot | null;
};

export const stockSpinOffFields = [
  "id,parent_holding_id,child_holding_id,effective_on,parent_shares::text,child_shares::text,child_basis_pct_usd::text,child_basis_pct_aud::text,average_aud_basis,statement_reference,child_snapshot_id,updated_at",
  `parent:portfolio_holdings!parent_holding_id(${transferHoldingFields})`,
  `child:portfolio_holdings!child_holding_id(${transferHoldingFields})`,
  `child_snapshot:transactions!child_snapshot_id(${receivingSnapshotFields})`,
].join(",");

export function distinctSpinOffHoldings(parent: TransferHolding | null, child: TransferHolding | null) {
  if (!parent || !child || parent.id === child.id || parent.asset_kind !== "Stock" || child.asset_kind !== "Stock") return false;
  if (parent.broker_account && child.broker_account && parent.broker_account.account_id !== child.broker_account.account_id) return false;
  const parentSymbol = parent.asset_symbol.trim().toUpperCase();
  const childSymbol = child.asset_symbol.trim().toUpperCase();
  const parentExchange = parent.asset_exchange?.trim().toUpperCase();
  const childExchange = child.asset_exchange?.trim().toUpperCase();
  return Boolean(parentSymbol && childSymbol && parentExchange && childExchange &&
    (parentSymbol !== childSymbol || parentExchange !== childExchange));
}

export function matchesSpinOffSnapshot(snapshot: ReceivingSnapshot, childId: string, effectiveOn: string, shares: string) {
  const day = sydneyDate(snapshot.transaction_date);
  const units = lotUnits(shares);
  return Boolean(units && snapshot.holding_id === childId && !snapshot.deleted_at && snapshot.type === "Buy" &&
    (snapshot.trade_provenance?.source === "broker_position" || snapshot.trade_provenance?.source === "csv_position") &&
    day && day >= effectiveOn && lotUnits(snapshot.shares) === units);
}

export function spinOffPercent(value: string | null) {
  if (!value || !/^(?:0|[1-9]\d?)(?:\.\d{1,12})?$/.test(value)) return undefined;
  return lotUnits(value) || undefined;
}
