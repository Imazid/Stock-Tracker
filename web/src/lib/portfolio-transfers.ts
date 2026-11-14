export type HoldingBrokerAccount = {
  account_id: string;
  label: string;
  institution: string;
  observed_at: string;
  tracking: boolean;
};

export type TransferHolding = {
  id: string;
  asset_symbol: string;
  asset_exchange: string | null;
  asset_kind: string;
  date_added: string;
  broker_account?: HoldingBrokerAccount | null;
  deleted_at: string | null;
};

export type ReceivingSnapshot = {
  id: string;
  holding_id: string;
  transaction_date: string;
  type: string;
  shares: number;
  trade_provenance: { source?: string } | null;
  deleted_at: string | null;
};

export type StockTransfer = {
  id: string;
  from_holding_id: string;
  to_holding_id: string;
  sent_on: string;
  received_on: string;
  shares: string;
  same_day_order: number;
  from_account: string;
  to_account: string;
  statement_reference: string;
  receiving_snapshot_id: string | null;
  updated_at: string;
  source: TransferHolding | null;
  destination: TransferHolding | null;
  receiving_snapshot: ReceivingSnapshot | null;
  snaptrade_reference?: BrokerStockTransferReference | null;
};

export type BrokerStockTransferReference = {
  sentId: string;
  receivedId: string;
  sentOn: string;
  receivedOn: string;
  fromAccountId: string;
  toAccountId: string;
  symbol: string;
  exchange: string;
  shares: string;
};

export const transferHoldingFields = "id,asset_symbol,asset_exchange,asset_kind,date_added,deleted_at,broker_account";
export const receivingSnapshotFields = "id,holding_id,transaction_date,type,shares,trade_provenance,deleted_at";
export const stockTransferFields = [
  "id,from_holding_id,to_holding_id,sent_on,received_on,shares::text,same_day_order,from_account,to_account,statement_reference,receiving_snapshot_id,updated_at,snaptrade_reference",
  `source:portfolio_holdings!from_holding_id(${transferHoldingFields})`,
  `destination:portfolio_holdings!to_holding_id(${transferHoldingFields})`,
  `receiving_snapshot:transactions!receiving_snapshot_id(${receivingSnapshotFields})`,
].join(",");

export function sameListedStock(source: TransferHolding | null, destination: TransferHolding | null) {
  const exchange = source?.asset_exchange?.trim().toUpperCase();
  return source && destination && source.id !== destination.id && source.asset_kind === "Stock" &&
    destination.asset_kind === "Stock" && Boolean(exchange) &&
    (!source.broker_account || !destination.broker_account ||
      source.broker_account.account_id !== destination.broker_account.account_id) &&
    exchange === destination.asset_exchange?.trim().toUpperCase() &&
    source.asset_symbol.trim().toUpperCase() === destination.asset_symbol.trim().toUpperCase();
}

const sydneyDates = new Intl.DateTimeFormat("en-AU", { timeZone: "Australia/Sydney", year: "numeric", month: "2-digit", day: "2-digit" });

export function sydneyDate(timestamp: string) {
  const time = Date.parse(timestamp);
  if (!Number.isFinite(time)) return null;
  const { day, month, year } = Object.fromEntries(sydneyDates.formatToParts(time).map((part) => [part.type, part.value]));
  return `${year.padStart(4, "0")}-${month}-${day}`;
}

export function matchesReceivingSnapshot(transfer: StockTransfer, day: string | null) {
  const snapshot = transfer.receiving_snapshot;
  return snapshot && snapshot.holding_id === transfer.to_holding_id && !snapshot.deleted_at &&
    snapshot.type === "Buy" && (snapshot.trade_provenance?.source === "broker_position" ||
      snapshot.trade_provenance?.source === "csv_position") && day !== null && day >= transfer.received_on;
}
