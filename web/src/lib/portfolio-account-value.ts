import type { ExposureCurrency, PortfolioReferenceRates } from "./portfolio-exposure.ts";

type ReportedAccount = {
  paper: boolean;
  status: string;
  syncedAt: string | null;
  netValue?: { amount: string; currency: string } | null;
};

export function portfolioAccountValue(accounts: readonly ReportedAccount[], base: ExposureCurrency, rates?: PortfolioReferenceRates) {
  const realAccounts = accounts.filter((account) => !account.paper);
  const fxDates = new Set<string>();
  let total = 0;
  let covered = 0;
  let oldestSync: string | undefined;
  for (const account of realAccounts) {
    if (account.status !== "available" || !account.netValue || !account.syncedAt || !Number.isFinite(Date.parse(account.syncedAt))) continue;
    const { amount, currency } = account.netValue;
    const fx = currency === base ? undefined : rates?.[base]?.[currency];
    const rate = currency === base ? 1 : Number(fx?.rate);
    const value = Number(amount) * rate;
    if (!Number.isFinite(rate) || rate <= 0 || !Number.isFinite(value) || !Number.isFinite(total + value)) continue;
    total += value;
    covered++;
    if (!oldestSync || account.syncedAt < oldestSync) oldestSync = account.syncedAt;
    if (fx) fxDates.add(fx.date);
  }
  return { total: covered ? total : null, covered, accounts: realAccounts.length, oldestSync, fxDates: [...fxDates].sort() };
}
