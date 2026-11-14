import { sameListedStock, type BrokerStockTransferReference, type TransferHolding } from "./portfolio-transfers.ts";

export type BrokerStockMovement = {
  id: string;
  date: string;
  stockTransfer: { accountId: string; direction: "sent" | "received"; symbol: string; exchange: string; shares: string };
};

export type BrokerStockMatch = {
  source: TransferHolding;
  destination: TransferHolding;
  reference: BrokerStockTransferReference;
};

function exchangeKey(value: string) {
  const exchange = value.trim().toUpperCase();
  switch (exchange) {
    case "XASX": return "ASX";
    case "XNYS": return "NYSE";
    case "XNAS": return "NASDAQ";
    default: return exchange;
  }
}

function listingKey(symbol: string, exchange: string) {
  const venue = exchangeKey(exchange);
  const ticker = symbol.trim().toUpperCase();
  return JSON.stringify([venue === "ASX" ? ticker.replace(/\.AX$/, "") : ticker, venue]);
}

function matchesLegs(sent: BrokerStockMovement, received: BrokerStockMovement) {
  const source = sent.stockTransfer;
  const destination = received.stockTransfer;
  const gap = (Date.parse(received.date) - Date.parse(sent.date)) / 86_400_000;
  return sent.id !== received.id && source.accountId !== destination.accountId && gap >= 0 && gap <= 7 &&
    source.shares === destination.shares && listingKey(source.symbol, source.exchange) === listingKey(destination.symbol, destination.exchange);
}

export function matchBrokerStockTransfers(movements: readonly BrokerStockMovement[], holdings: readonly TransferHolding[]): BrokerStockMatch[] {
  const distinct = [...new Map(movements.map((movement) => [movement.id, movement])).values()];
  const outgoing = distinct.filter((movement) => movement.stockTransfer.direction === "sent");
  const incoming = distinct.filter((movement) => movement.stockTransfer.direction === "received");
  const holdingIndex = new Map<string, TransferHolding[]>();
  for (const holding of holdings) {
    const account = holding.broker_account?.account_id;
    if (!account || !holding.asset_exchange || holding.asset_kind !== "Stock") continue;
    const key = account + listingKey(holding.asset_symbol, holding.asset_exchange);
    const rows = holdingIndex.get(key) ?? [];
    rows.push(holding);
    holdingIndex.set(key, rows);
  }
  const candidatesBySender = new Map<string, BrokerStockMovement[]>();
  const sendersByReceiver = new Map<string, number>();
  for (const sent of outgoing) {
    const candidates = incoming.filter((received) => matchesLegs(sent, received));
    candidatesBySender.set(sent.id, candidates);
    for (const candidate of candidates) {
      sendersByReceiver.set(candidate.id, (sendersByReceiver.get(candidate.id) ?? 0) + 1);
    }
  }
  return outgoing.flatMap((sent) => {
    const candidates = candidatesBySender.get(sent.id);
    if (candidates?.length !== 1) return [];
    const [received] = candidates;
    if (sendersByReceiver.get(received.id) !== 1) return [];
    const { accountId: fromAccountId, symbol, exchange, shares } = sent.stockTransfer;
    const { accountId: toAccountId } = received.stockTransfer;
    const listing = listingKey(symbol, exchange);
    const sources = holdingIndex.get(fromAccountId + listing);
    const destinations = holdingIndex.get(toAccountId + listing);
    if (sources?.length !== 1 || destinations?.length !== 1 || !sameListedStock(sources[0], destinations[0])) return [];
    return [{
      source: sources[0], destination: destinations[0],
      reference: { sentId: sent.id, receivedId: received.id, sentOn: sent.date, receivedOn: received.date,
        fromAccountId, toAccountId, symbol, exchange, shares },
    }];
  }).sort((first, second) => second.reference.sentOn.localeCompare(first.reference.sentOn));
}
