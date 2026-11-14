import { PORTFOLIO_BENCHMARKS, type PortfolioBenchmark } from "@/lib/portfolio-benchmark";
import { json, jsonError, rateLimited } from "@/server/http/respond";
import { cachedPortfolioBenchmark, validBenchmarkPeriod } from "@/server/portfolio/benchmark";

export const maxDuration = 30;

export async function GET(request: Request) {
  const limited = rateLimited(request);
  if (limited) return limited;
  const params = new URL(request.url).searchParams;
  const id = params.get("benchmark") ?? "";
  const start = params.get("start") ?? "";
  const end = params.get("end") ?? "";
  if (!Object.hasOwn(PORTFOLIO_BENCHMARKS, id) || !validBenchmarkPeriod(start, end)) {
    return jsonError(400, "invalid_benchmark", "Choose a supported benchmark and a period of up to ten years.");
  }
  try {
    return json({ result: await cachedPortfolioBenchmark(id as PortfolioBenchmark, start, end) }, 300);
  } catch {
    return jsonError(503, "benchmark_unavailable", "Benchmark data is temporarily unavailable.");
  }
}
