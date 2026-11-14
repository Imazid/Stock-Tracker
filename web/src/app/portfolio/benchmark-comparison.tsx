import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Button } from "@/components/ui/Button";
import { Field, Select } from "@/components/ui/Field";
import { getJSON } from "@/lib/api";
import { percent } from "@/lib/format";
import { BENCHMARK_MAX_DAYS, PORTFOLIO_BENCHMARKS, type PortfolioBenchmark, type PortfolioBenchmarkResult } from "../../../../supabase/functions/_shared/portfolio/benchmark_types";

type Period = { id: string; starts_on: string; ends_on: string; time_weighted_return_pct: number | null };

export function BenchmarkComparison({ periods, continuous }: {
  periods: readonly Period[];
  continuous: Omit<Period, "id"> | null;
}) {
  const options = continuous ? [{ ...continuous, id: "continuous" }, ...periods] : periods;
  const [periodId, setPeriodId] = useState("");
  const [benchmark, setBenchmark] = useState<PortfolioBenchmark | "">("");
  const period = options.find((period) => period.id === periodId) ?? options[0];
  const tooLong = Date.parse(period.ends_on) - Date.parse(period.starts_on) > BENCHMARK_MAX_DAYS * 86_400_000;
  const params = new URLSearchParams({ benchmark, start: period.starts_on, end: period.ends_on });
  const query = useQuery({
    queryKey: ["portfolio-benchmark", benchmark, period.starts_on, period.ends_on],
    queryFn: ({ signal }) => getJSON<{ result: PortfolioBenchmarkResult | null }>(`/api/portfolio/benchmark?${params}`, signal),
    enabled: Boolean(benchmark) && !tooLong,
    staleTime: 5 * 60_000,
    retry: 1,
  });
  const comparison = query.data?.result;
  const portfolio = period.time_weighted_return_pct;
  const selected = benchmark ? PORTFOLIO_BENCHMARKS[benchmark] : undefined;
  const difference = comparison && portfolio !== null ? portfolio - comparison.returnPct : undefined;

  return (
    <section aria-labelledby="portfolio-benchmark-heading" className="space-y-3 rounded-lg border border-border bg-surface-2 p-3">
      <h3 id="portfolio-benchmark-heading" className="font-medium">Benchmark comparison</h3>
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Return period" htmlFor="portfolio-benchmark-period">
          <Select id="portfolio-benchmark-period" value={period.id} onChange={(event) => setPeriodId(event.target.value)}>
            {options.map((item) => <option key={item.id} value={item.id}>
              {item.starts_on} to {item.ends_on}{item.id === "continuous" ? " · Continuous" : ""}
            </option>)}
          </Select>
        </Field>
        <Field label="Benchmark" htmlFor="portfolio-benchmark">
          <Select id="portfolio-benchmark" value={benchmark} onChange={(event) => setBenchmark(event.target.value as PortfolioBenchmark | "")}>
            <option value="">Choose a benchmark</option>
            {Object.entries(PORTFOLIO_BENCHMARKS).map(([id, item]) => <option key={id} value={id}>{item.label}</option>)}
          </Select>
        </Field>
      </div>
      {tooLong && <p role="status" className="text-xs text-text-2">Choose a return period of up to ten years.</p>}
      {selected && !tooLong && <>
        <p className="text-xs text-text-2">Compares the portfolio’s time-weighted return with the ETF’s distribution-adjusted return in USD. The ETF uses its local market close on or before each date.</p>
        {query.isPending && <p role="status" className="text-xs text-text-2">Loading benchmark…</p>}
        {query.isError && <div className="flex flex-wrap items-center gap-2">
          <p role="status" className="text-xs text-text-2">{query.error.message}</p>
          <Button size="sm" disabled={query.isFetching} onClick={() => void query.refetch()}>Retry benchmark</Button>
        </div>}
        {query.data?.result === null && <p role="status" className="text-xs text-text-2">Completed prices or exchange rates are unavailable for these dates.</p>}
        {comparison && <>
          <dl aria-live="polite" className="grid grid-cols-2 gap-2 tabular sm:grid-cols-3">
            <div><dt className="text-xs text-text-3">Portfolio time-weighted return</dt><dd>{portfolio === null ? "Unavailable" : percent(portfolio)}</dd></div>
            <div><dt className="text-xs text-text-3">ETF return in USD</dt><dd>{percent(comparison.returnPct)}</dd></div>
            <div><dt className="text-xs text-text-3">Difference</dt><dd>{difference === undefined
              ? "Unavailable" : `${difference > 0 ? "+" : ""}${difference.toFixed(2)} pp`}</dd></div>
          </dl>
          <p className="text-xs text-text-2">ETF closes {comparison.start.session} and {comparison.end.session}.
            {comparison.start.fxDate && comparison.end.fxDate && <> ECB AUD/USD rates observed {comparison.start.fxDate} and {comparison.end.fxDate}.</>}
          </p>
          <p className="flex flex-wrap gap-x-3 gap-y-1 text-xs">
            <a className="text-primary-fg underline" href={comparison.sourceUrl} target="_blank" rel="noreferrer">{comparison.source}</a>
            <a className="text-primary-fg underline" href={selected.fund} target="_blank" rel="noreferrer">ETF details</a>
          </p>
        </>}
      </>}
    </section>
  );
}
