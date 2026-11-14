import { assertEquals } from "jsr:@std/assert@1";
import { accountCashFlow, accountCashFlowBalances } from "../_shared/private-markets/account-cash-flow.ts";
import { accountValuations, withAccountCashFlows, withAccountValuations } from "../_shared/private-markets/account-holdings.ts";

const now = new Date("2026-11-14T14:05:00Z"); // 15 November in Sydney.
const entry = {
  id: "ab100000-0000-4000-8000-000000000010", status: "contribution",
  amount: "1000.123456789", date: "2026-11-15", source: "Fund contribution statement",
};

Deno.test("account cash flows retain exact amounts and require dated settlement evidence", () => {
  assertEquals(accountCashFlow(entry, now), entry);
  assertEquals(accountCashFlow({ ...entry, date: "2026-11-16" }, now), null);
  assertEquals(accountCashFlow({ ...entry, date: "2026-02-29" }, now), null);
  assertEquals(accountCashFlow({ ...entry, status: "pending", date: "2026-12-01" }, now)?.date, "2026-12-01");
  assertEquals(accountCashFlow({ ...entry, amount: "0.0000" }, now), null);
  assertEquals(accountCashFlow({ ...entry, status: "paid", dueOn: "2026-12-01" }, now), null);
  assertEquals(accountCashFlow({ ...entry, status: "cancelled", dueOn: "2026-12-01", resolutionSource: "Fund cancellation" }, now)?.dueOn, "2026-12-01");
  assertEquals(accountCashFlow({ ...entry, provider_confirmed: true }, now), null);
});

Deno.test("account balances sum precise settled and pending entries and exclude cancellations", () => {
  assertEquals(accountCashFlowBalances([
    { ...entry, status: "contribution" },
    { ...entry, status: "paid", amount: "100.0000000000000001" },
    { ...entry, status: "pending", amount: "0.1234567890123456" },
    { ...entry, status: "distribution", amount: "5.123456789" },
    { ...entry, status: "cancelled", amount: "2000" },
  ]), { paid: "1100.1234567890000001", returned: "5.123456789", pendingCalls: "0.1234567890123456" });
});

Deno.test("sale validation distinguishes unit sales and full exits", () => {
  const sale = { ...entry, status: "sale" as const, amount: "0", soldUnits: "0.0000000000000001", disposedCost: "0" };
  assertEquals(accountCashFlow(sale, now), sale);
  assertEquals(accountCashFlow({ ...sale, soldUnits: "0" }, now), null);
  assertEquals(accountCashFlow({ ...sale, disposedCost: "-1" }, now), null);
  assertEquals(accountCashFlow({ ...sale, closesPosition: true }, now), null);
  assertEquals(accountCashFlow({ ...sale, status: "distribution", amount: "1" }, now), null);
  assertEquals(accountCashFlow({ ...sale, date: "2026-11-16" }, now), null);
  assertEquals(accountCashFlow({ ...sale, soldUnits: undefined, closesPosition: true }, now)?.closesPosition, true);
});

Deno.test("sale balances protect opening units and retain pre-sale mark history", () => {
  const original = { units: "0.3000000000000001", valuation: {
    date: "2026-11-10T00:00:00Z", value: "1000", source: "October statement", method: "NAV",
  } };
  const partial = { ...entry, status: "sale" as const, amount: "25.0000000000000001", soldUnits: "0.1", date: "2026-11-10" };
  const close = { ...partial, id: crypto.randomUUID(), soldUnits: "0.2000000000000001", amount: "75", date: "2026-11-12" };
  const updated = withAccountCashFlows(original, [partial])!;
  assertEquals(updated.remainingUnits, "0.2000000000000001");
  assertEquals(updated.valuation, undefined);
  assertEquals(updated.valuationHistory, [original.valuation]);
  assertEquals(updated.cashFlows, []);
  assertEquals(updated.sales, [partial]);
  const mark = { ...original.valuation, date: "2026-11-11T00:00:00Z", value: "750" };
  const marked = withAccountValuations(updated, accountValuations(updated), mark);
  assertEquals(marked.valuation, mark);
  const closed = withAccountCashFlows(marked, [close, partial])!;
  assertEquals(closed.remainingUnits, "0");
  assertEquals(closed.exitedOn, close.date);
  assertEquals(closed.saleProceeds, "100.0000000000000001");
  assertEquals(withAccountCashFlows(closed, [partial])?.valuation, mark);
  assertEquals(withAccountCashFlows(closed, [])?.remainingUnits, undefined);
  assertEquals(withAccountCashFlows(marked, [partial, { ...close, soldUnits: "0.2000000000000002" }]), null);
  assertEquals(withAccountCashFlows({ ...original, units: undefined }, [partial]), null);
  const unknownUnits = withAccountCashFlows({}, [{ ...close, soldUnits: undefined, closesPosition: true }]);
  assertEquals(unknownUnits?.exitedOn, close.date);
  assertEquals(unknownUnits?.remainingUnits, "0");
});
