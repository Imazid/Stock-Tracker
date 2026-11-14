import { useQuery } from "@tanstack/react-query";
import { service } from "@/workspace/lib/backend";

export type CashAccount = {
  id: string;
  label: string;
  paper: boolean;
  status: "available" | "disconnected" | "unavailable";
  syncedAt: string | null;
  netValue?: { amount: string; currency: string } | null;
  incomplete?: boolean;
  balances: { currency: string; amount: string | null; buyingPower?: string | null }[];
};

export function usePortfolioBrokerage(userId: string, enabled: boolean) {
  return useQuery({
    queryKey: ["portfolio-broker-cash", userId],
    queryFn: () => service<{ accounts: CashAccount[]; duplicatesSkipped: number }>("brokerage", { operation: "portfolioCash" }, undefined, userId),
    enabled,
    gcTime: 0,
    staleTime: 60_000,
    retry: false,
  });
}
