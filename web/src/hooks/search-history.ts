"use client";

import { useSyncExternalStore } from "react";
import { parseRecentSearches, searchHistorySnapshot, subscribeSearchHistory } from "@/lib/recent-searches";

const serverSnapshot = () => "";

export function useSearchHistory() {
  return parseRecentSearches(useSyncExternalStore(subscribeSearchHistory, searchHistorySnapshot, serverSnapshot));
}
