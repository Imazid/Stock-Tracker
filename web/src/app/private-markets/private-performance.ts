import type { PortfolioHolding } from "./private-data";

const dayMs = 86_400_000;
const isFund = (kind: string) => ["Venture fund", "Private equity", "Syndicate or SPV"].includes(kind);

type CashFlow = { day: string; amount: number };

// Same conventional-flow restriction and log-rate bracket as TradingCore.
function annualizedReturn(flows: CashFlow[]) {
  const byDate = new Map<string, number>();
  for (const { day, amount } of flows) byDate.set(day, (byDate.get(day) ?? 0) + amount);
  const dated = [...byDate].filter(([, amount]) => amount !== 0).sort(([first], [second]) => first.localeCompare(second));
  const firstCredit = dated.findIndex(([, amount]) => amount > 0);
  if (firstCredit < 1 || dated.slice(firstCredit).some(([, amount]) => amount < 0)) return null;

  const origin = Date.parse(dated[0][0]);
  const series = dated.map(([day, amount]) => ({ years: (Date.parse(day) - origin) / (365 * dayMs), amount }));
  const valueAt = (logRate: number) => series.reduce((sum, flow) => sum + flow.amount * Math.exp(-logRate * flow.years), 0);
  let low = -16;
  let high = 16;
  if (!(valueAt(low) > 0 && valueAt(high) < 0)) return null;
  for (let step = 0; step < 100; step++) {
    const midpoint = (low + high) / 2;
    if (valueAt(midpoint) > 0) low = midpoint;
    else high = midpoint;
  }
  return Math.expm1((low + high) / 2);
}

export function privatePositionPerformance(holding: PortfolioHolding, today: string, asOf: number) {
  const dispositionOn = holding.last_disposition_on;
  const hasDisposition = dispositionOn !== null && dispositionOn <= today;
  const exited = hasDisposition && holding.remaining_units === 0 && Boolean(holding.exit_source);
  const revisionAt = Date.parse(holding.disposition_revision_at ?? "");
  // The API sorts marks newest first with provider revision order as the tiebreak.
  const mark = exited ? undefined : holding.marks.find((entry) => {
    const reportedAt = Date.parse(entry.provider_event_at ?? "");
    return Number.isFinite(entry.value) && entry.value >= 0 && entry.valued_on <= today &&
      (entry.provider_event_at === null || reportedAt <= asOf) &&
      (!hasDisposition || entry.valued_on > dispositionOn) &&
      (!(revisionAt <= asOf) || reportedAt > revisionAt);
  });
  const stale = mark ? Date.parse(today) - Date.parse(mark.valued_on) > 90 * dayMs : false;
  const completeActivity = Math.max(holding.marks.length, holding.calls.length, holding.distributions.length,
    holding.dispositions.length) <= 100 && (!hasDisposition || holding.dispositions.length > 0);
  const position = { exited, mark, stale, completeActivity, fund: isFund(holding.asset_class) };
  if (!completeActivity || holding.settled_amount == null || !holding.settled_on || holding.settled_on > today ||
    !holding.settlement_source) return { ...position, metrics: null };

  const pendingCalls = holding.calls.filter((call) => !call.settled_on || call.settled_on > today);
  const paidCalls = holding.calls.filter((call) => call.settled_on && call.settled_on <= today);
  const distributions = holding.distributions.filter((record) => record.received_on <= today);
  const sales = holding.dispositions.filter((sale) => sale.settled_on <= today);
  const paid = holding.settled_amount + paidCalls.reduce((sum, call) => sum + call.amount, 0);
  const distributed = distributions.reduce((sum, record) => sum + record.amount, 0);
  const proceeds = sales.reduce((sum, sale) => sum + sale.net_proceeds, 0);
  const disposed = sales.reduce((sum, sale) => sum + (sale.disposed_cost ?? 0), 0);
  const hasBasis = paid > 0 && sales.every((sale) => sale.disposed_cost != null) && disposed <= paid;
  const flows: CashFlow[] = [
    { day: holding.settled_on, amount: -holding.settled_amount },
    ...paidCalls.map((call) => ({ day: call.settled_on!, amount: -call.amount })),
    ...distributions.map((record) => ({ day: record.received_on, amount: record.amount })),
    ...sales.map((sale) => ({ day: sale.settled_on, amount: sale.net_proceeds })),
  ];
  const carrying = exited ? 0 : mark?.value;
  const carryingDay = exited ? dispositionOn : mark?.valued_on;
  const comparable = carrying !== undefined && carryingDay !== undefined &&
    (exited || flows.every((flow) => flow.day <= carryingDay));
  const returned = distributed + proceeds;
  return {
    ...position,
    metrics: {
      paid, returned,
      uncalled: holding.committed_amount == null ? null : Math.max(0, holding.committed_amount - paid),
      pending: pendingCalls.reduce((sum, call) => sum + call.amount, 0),
      netGain: comparable ? carrying + returned - paid : null,
      realized: hasBasis && sales.length ? proceeds - disposed : null,
      unrealized: exited ? 0 : comparable && hasBasis && !distributions.length ? carrying - (paid - disposed) : null,
      multiple: comparable && paid > 0 ? (carrying + returned) / paid : null,
      multipleLabel: position.fund && !sales.length ? "TVPI" : "MOIC",
      dpi: position.fund && paid > 0 ? distributed / paid : null,
      xirr: comparable ? annualizedReturn([...flows, { day: carryingDay, amount: carrying }]) : null,
    },
  };
}
