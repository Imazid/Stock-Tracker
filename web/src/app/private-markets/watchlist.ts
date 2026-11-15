import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { privateMarkets } from "./private-data";
import { webMonitorKey } from "./web-monitor";

export type FollowedCompany = { id: string; name: string; source: string | null };

export function useCompanyWatchlist(owner: string) {
  const cache = useQueryClient();
  const key = ["private-markets", owner, "company-watchlist"];
  const watchlist = useQuery({
    queryKey: key, gcTime: 0, retry: false,
    queryFn: ({ signal }) => privateMarkets<{ companies: FollowedCompany[] }>("company_watchlist", { owner, signal }),
  });
  const save = useMutation({
    mutationFn: ({ id, following }: { id: string; following: boolean }) =>
      privateMarkets<{ companies: FollowedCompany[] }>("save_company_watchlist", {
        owner, add_company_ids: following ? [id] : [], remove_company_ids: following ? [] : [id],
      }),
    onMutate: () => cache.cancelQueries({ queryKey: key }),
    onSuccess: (value) => {
      cache.setQueryData(key, value);
      void cache.invalidateQueries({ queryKey: [...webMonitorKey(owner), "alerts"] });
    },
    onError: () => cache.invalidateQueries({ queryKey: key }),
  });
  return { watchlist, save };
}
