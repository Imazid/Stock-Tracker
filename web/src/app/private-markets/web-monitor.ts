import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { privateMarkets, PrivateMarketsError, type MonitorPreferences } from "./private-data";

export type WebMonitorOptions = Pick<MonitorPreferences, "company_ids" | "eligible_opportunities" | "digest_enabled"> & { enabled: boolean };
type WebMonitorSettings = { revision: string | null; preferences: MonitorPreferences | null };

export const webMonitorKey = (owner: string) => ["private-markets", owner, "monitor"];
export const maxMonitoredCompanies = 250;

export function useWebMonitor(owner: string) {
  const scope = webMonitorKey(owner);
  const preferencesKey = [...scope, "preferences"];
  const cache = useQueryClient();
  const settings = useQuery({
    queryKey: preferencesKey, gcTime: 0, staleTime: Infinity, retry: false,
    queryFn: ({ signal }) => privateMarkets<WebMonitorSettings>("web_monitor_preferences", { owner, signal }),
  });
  const save = useMutation({
    mutationFn: (options: WebMonitorOptions & { expected_revision: string | null; expected_enabled: boolean }) =>
      privateMarkets<WebMonitorSettings>("save_web_monitor", { owner, ...options }),
    onMutate: () => cache.cancelQueries({ queryKey: preferencesKey }),
    onSuccess: (value) => {
      cache.setQueryData(preferencesKey, value);
      void cache.invalidateQueries({ queryKey: [...scope, "alerts"] });
    },
    onError: (error) => {
      if (error instanceof PrivateMarketsError && error.code === "MONITOR_SETTINGS_CHANGED") {
        void cache.invalidateQueries({ queryKey: preferencesKey });
      }
    },
  });
  return { settings, save };
}
