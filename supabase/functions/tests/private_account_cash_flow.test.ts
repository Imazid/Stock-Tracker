import { assertEquals } from "jsr:@std/assert@1";
import { accountCashFlow, accountCashFlowBalances } from "../_shared/private-markets/account-cash-flow.ts";

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
