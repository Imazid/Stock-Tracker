"use client";

import { useEffect, useRef, useState } from "react";

export function usePreviousPortfolioVisit(userId: string, observed: boolean) {
  const [previous, setPrevious] = useState<number>();
  const recorded = useRef(false);
  useEffect(() => {
    if (!observed || recorded.current) return;
    recorded.current = true;
    try {
      const key = `st:portfolio-visit:${userId}`;
      const now = Date.now();
      const saved = Number(localStorage.getItem(key));
      localStorage.setItem(key, String(now));
      // This records an observation in this browser, without storing portfolio data.
      // eslint-disable-next-line react-hooks/set-state-in-effect
      if (Number.isSafeInteger(saved) && saved > 0 && saved <= now) setPrevious(saved);
    } catch {
      // Browser storage can be disabled.
    }
  }, [observed, userId]);
  return previous;
}
