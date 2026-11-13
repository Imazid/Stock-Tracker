"use client";

import { useEffect, useState } from "react";

/** The current time, refreshed every `everyMs` — so render stays pure and expiry labels tick. */
export function useNow(everyMs = 15_000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), everyMs);
    return () => clearInterval(t);
  }, [everyMs]);
  return now;
}
