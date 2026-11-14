import { useQuery } from "@tanstack/react-query";
import { getJSON } from "@/lib/api";
import type { PortfolioReferenceRates } from "@/lib/portfolio-exposure";
import type { PortfolioGains } from "@/lib/portfolio-gains";

export function usePortfolioGains(userId?: string) {
  return useQuery({
    queryKey: ["portfolio-gains", userId],
    enabled: Boolean(userId),
    queryFn: async ({ signal }) => {
      const report = await getJSON<PortfolioGains>("/api/portfolio/gains", signal);
      if (report.owner !== userId) throw new Error("The account changed while loading gains.");
      return report;
    },
    staleTime: 30_000,
  });
}

export function usePortfolioRates(enabled: boolean) {
  return useQuery({
    queryKey: ["portfolio-reference-rates"],
    queryFn: ({ signal }) => getJSON<PortfolioReferenceRates>("/api/portfolio/reference-rates", signal),
    enabled,
    staleTime: 15 * 60_000,
    refetchInterval: 30 * 60_000,
  });
}
