export const PORTFOLIO_BENCHMARKS = {
  SPY: { label: "S&P 500 ETF (SPY)", fund: "https://www.ssga.com/us/en/individual/etfs/state-street-spdr-sp-500-etf-trust-spy" },
  STW: { label: "S&P/ASX 200 ETF (STW)", fund: "https://www.ssga.com/au/en_gb/individual/etfs/state-street-spdr-spasx-200-etf-stw" },
} as const;

export type PortfolioBenchmark = keyof typeof PORTFOLIO_BENCHMARKS;
export const BENCHMARK_MAX_DAYS = 3660;
type Boundary = { session: string; fxDate?: string };
export type PortfolioBenchmarkResult = {
  returnPct: number;
  start: Boundary;
  end: Boundary;
  source: string;
  sourceUrl: string;
};
