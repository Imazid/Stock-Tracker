"use client";

// Price chart on TradingView Lightweight Charts (Apache-2.0; the attribution logo stays on, as
// its licence asks). Indicators are computed with the shared engine's `Indicators` — the same
// functions the strategy evaluator and backtester use — so a line on this chart is exactly
// what a strategy rule would see.

import { Indicators, type Series } from "@engine/indicators.ts";
import {
  AreaSeries,
  CandlestickSeries,
  createChart,
  createSeriesMarkers,
  CrosshairMode,
  HistogramSeries,
  type IChartApi,
  LineSeries,
  type SeriesMarker,
  type Time,
  type UTCTimestamp,
} from "lightweight-charts";
import { useEffect, useRef } from "react";
import type { CandleView } from "@/lib/market-types";

export type ChartType = "candles" | "line" | "area";

export interface IndicatorSet {
  sma20: boolean;
  sma50: boolean;
  ema20: boolean;
  bollinger: boolean;
  volume: boolean;
  rsi: boolean;
  macd: boolean;
}

export const DEFAULT_INDICATORS: IndicatorSet = { sma20: false, sma50: false, ema20: false, bollinger: false, volume: true, rsi: false, macd: false };

export interface ChartMarker {
  time: number; // seconds
  side: "buy" | "sell";
  text?: string;
}

function cssVar(name: string, fallback: string): string {
  if (typeof window === "undefined") return fallback;
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v || fallback;
}

function palette() {
  return {
    text: cssVar("--chart-text", "#a8aeb8"),
    grid: cssVar("--chart-grid", "rgba(255,255,255,0.05)"),
    border: cssVar("--border", "#262a31"),
    up: cssVar("--up", "#34c77b"),
    down: cssVar("--down", "#f2646f"),
    primary: cssVar("--primary-fg", "#9aa5ff"),
    warn: cssVar("--warn", "#f2b448"),
    surface: cssVar("--surface", "#111317"),
  };
}

function line(times: UTCTimestamp[], values: Series) {
  const out: { time: UTCTimestamp; value: number }[] = [];
  values.forEach((v, i) => {
    if (v !== undefined && Number.isFinite(v)) out.push({ time: times[i], value: v });
  });
  return out;
}

function formatter(timeZone: string | undefined, intraday: boolean) {
  const full = new Intl.DateTimeFormat("en-AU", intraday
    ? { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false, timeZone, timeZoneName: "short" }
    : { day: "numeric", month: "short", year: "numeric", timeZone });
  const tickTime = new Intl.DateTimeFormat("en-AU", { hour: "2-digit", minute: "2-digit", hour12: false, timeZone });
  const tickDay = new Intl.DateTimeFormat("en-AU", { day: "numeric", month: "short", timeZone });
  const tickYear = new Intl.DateTimeFormat("en-AU", { month: "short", year: "numeric", timeZone });
  return {
    timeFormatter: (t: Time) => full.format(new Date((t as number) * 1000)),
    tickMarkFormatter: (t: Time, type: number) => {
      const d = new Date((t as number) * 1000);
      // TickMarkType: 0 Year, 1 Month, 2 DayOfMonth, 3 Time, 4 TimeWithSeconds
      if (type >= 3) return tickTime.format(d);
      if (type === 2) return tickDay.format(d);
      return tickYear.format(d);
    },
  };
}

export function PriceChart({ candles, type, indicators, markers, timeZone, intraday, baseline, height = 420, ariaLabel }: {
  candles: CandleView[];
  type: ChartType;
  indicators: IndicatorSet;
  markers?: ChartMarker[];
  timeZone?: string;
  intraday: boolean;
  /** Previous close: drawn as a dashed line on intraday charts. */
  baseline?: number;
  height?: number;
  ariaLabel: string;
}) {
  const container = useRef<HTMLDivElement>(null);
  const chartRef = useRef<IChartApi | null>(null);

  useEffect(() => {
    const el = container.current;
    if (!el || candles.length === 0) return;
    const build = () => {
      chartRef.current?.remove();
      const p = palette();
      const fmt = formatter(timeZone, intraday);
      const chart = createChart(el, {
        autoSize: true,
        layout: {
          background: { color: "transparent" },
          textColor: p.text,
          fontFamily: getComputedStyle(document.body).fontFamily,
          fontSize: 11,
          attributionLogo: true,
          panes: { separatorColor: p.border, separatorHoverColor: p.grid, enableResize: true },
        },
        grid: { vertLines: { color: p.grid }, horzLines: { color: p.grid } },
        rightPriceScale: { borderColor: p.border },
        timeScale: { borderColor: p.border, timeVisible: intraday, secondsVisible: false, tickMarkFormatter: fmt.tickMarkFormatter },
        localization: { timeFormatter: fmt.timeFormatter, locale: "en-AU" },
        crosshair: { mode: CrosshairMode.Normal },
        handleScroll: true,
        handleScale: true,
      });
      chartRef.current = chart;

      const times = candles.map((c) => c.time as UTCTimestamp);
      const closes = candles.map((c) => c.close);
      const first = closes[0];
      const last = closes[closes.length - 1];
      const ref = baseline ?? first;
      const rising = last >= ref;

      let main;
      if (type === "candles") {
        main = chart.addSeries(CandlestickSeries, { upColor: p.up, downColor: p.down, wickUpColor: p.up, wickDownColor: p.down, borderVisible: false });
        main.setData(candles.map((c) => ({ time: c.time as UTCTimestamp, open: c.open, high: c.high, low: c.low, close: c.close })));
      } else if (type === "area") {
        const color = rising ? p.up : p.down;
        main = chart.addSeries(AreaSeries, { lineColor: color, topColor: `${color}40`, bottomColor: `${color}00`, lineWidth: 2 });
        main.setData(candles.map((c) => ({ time: c.time as UTCTimestamp, value: c.close })));
      } else {
        main = chart.addSeries(LineSeries, { color: rising ? p.up : p.down, lineWidth: 2 });
        main.setData(candles.map((c) => ({ time: c.time as UTCTimestamp, value: c.close })));
      }
      if (intraday && baseline !== undefined) {
        main.createPriceLine({ price: baseline, color: p.text, lineStyle: 2, lineWidth: 1, axisLabelVisible: true, title: "Prev close" });
      }

      if (indicators.sma20) chart.addSeries(LineSeries, { color: p.primary, lineWidth: 1, priceLineVisible: false, lastValueVisible: false, title: "SMA 20" }).setData(line(times, Indicators.sma(closes, 20)));
      if (indicators.sma50) chart.addSeries(LineSeries, { color: p.warn, lineWidth: 1, priceLineVisible: false, lastValueVisible: false, title: "SMA 50" }).setData(line(times, Indicators.sma(closes, 50)));
      if (indicators.ema20) chart.addSeries(LineSeries, { color: "#c084fc", lineWidth: 1, priceLineVisible: false, lastValueVisible: false, title: "EMA 20" }).setData(line(times, Indicators.ema(closes, 20)));
      if (indicators.bollinger) {
        const bb = Indicators.bollinger(closes, 20, 2);
        const opts = { color: p.text, lineWidth: 1 as const, lineStyle: 2, priceLineVisible: false, lastValueVisible: false };
        chart.addSeries(LineSeries, { ...opts, title: "BB upper" }).setData(line(times, bb.upper));
        chart.addSeries(LineSeries, { ...opts, lineStyle: 0, title: "BB mid" }).setData(line(times, bb.middle));
        chart.addSeries(LineSeries, { ...opts, title: "BB lower" }).setData(line(times, bb.lower));
      }
      if (indicators.volume) {
        const vol = chart.addSeries(HistogramSeries, { priceScaleId: "vol", priceFormat: { type: "volume" }, priceLineVisible: false, lastValueVisible: false, title: "Volume" });
        chart.priceScale("vol").applyOptions({ scaleMargins: { top: 0.82, bottom: 0 } });
        vol.setData(candles.map((c, i) => ({ time: c.time as UTCTimestamp, value: c.volume, color: (i > 0 ? c.close >= candles[i - 1].close : c.close >= c.open) ? `${p.up}66` : `${p.down}66` })));
      }

      let pane = 1;
      if (indicators.rsi) {
        const rsi = chart.addSeries(LineSeries, { color: p.primary, lineWidth: 1, priceLineVisible: false, title: "RSI 14" }, pane);
        rsi.setData(line(times, Indicators.rsi(closes, 14)));
        rsi.createPriceLine({ price: 70, color: p.down, lineStyle: 2, lineWidth: 1, axisLabelVisible: false, title: "" });
        rsi.createPriceLine({ price: 30, color: p.up, lineStyle: 2, lineWidth: 1, axisLabelVisible: false, title: "" });
        pane++;
      }
      if (indicators.macd) {
        const m = Indicators.macd(closes, 12, 26, 9);
        chart.addSeries(HistogramSeries, { priceLineVisible: false, lastValueVisible: false, title: "Hist" }, pane)
          .setData(m.histogram.map((v, i) => (v === undefined ? undefined : { time: times[i], value: v, color: v >= 0 ? `${p.up}99` : `${p.down}99` })).filter((x): x is { time: UTCTimestamp; value: number; color: string } => x !== undefined));
        chart.addSeries(LineSeries, { color: p.primary, lineWidth: 1, priceLineVisible: false, title: "MACD" }, pane).setData(line(times, m.line));
        chart.addSeries(LineSeries, { color: p.warn, lineWidth: 1, priceLineVisible: false, title: "Signal" }, pane).setData(line(times, m.signal));
        pane++;
      }
      const panes = chart.panes();
      if (panes.length > 1) {
        panes[0].setStretchFactor(3);
        for (let i = 1; i < panes.length; i++) panes[i].setStretchFactor(1);
      }

      if (markers && markers.length > 0) {
        const sorted: SeriesMarker<Time>[] = markers.slice().sort((a, b) => a.time - b.time).map((m) => ({
          time: m.time as UTCTimestamp,
          position: m.side === "buy" ? "belowBar" : "aboveBar",
          shape: m.side === "buy" ? "arrowUp" : "arrowDown",
          color: m.side === "buy" ? p.up : p.down,
          text: m.text,
        }));
        createSeriesMarkers(main, sorted);
      }
      chart.timeScale().fitContent();
    };
    build();
    const rebuild = () => build();
    window.addEventListener("st-theme-change", rebuild);
    return () => {
      window.removeEventListener("st-theme-change", rebuild);
      chartRef.current?.remove();
      chartRef.current = null;
    };
  }, [candles, type, indicators, markers, timeZone, intraday, baseline]);

  const paneCount = 1 + (indicators.rsi ? 1 : 0) + (indicators.macd ? 1 : 0);
  return <div ref={container} role="img" aria-label={ariaLabel} style={{ height: height + (paneCount - 1) * 110 }} className="w-full" />;
}

/** Equity curve (and optional benchmark) for a backtest, in the strategy's currency. */
export function EquityChart({ equity, benchmark, benchmarkName, height = 260, ariaLabel }: {
  equity: { time: number; value: number }[]; benchmark?: { time: number; value: number }[]; benchmarkName?: string; height?: number; ariaLabel: string;
}) {
  const container = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = container.current;
    if (!el || equity.length === 0) return;
    let chart: IChartApi | null = null;
    const build = () => {
      chart?.remove();
      const p = palette();
      chart = createChart(el, {
        autoSize: true,
        layout: { background: { color: "transparent" }, textColor: p.text, fontSize: 11, attributionLogo: true },
        grid: { vertLines: { color: p.grid }, horzLines: { color: p.grid } },
        rightPriceScale: { borderColor: p.border },
        timeScale: { borderColor: p.border },
        localization: { locale: "en-AU" },
      });
      const dedupe = (pts: { time: number; value: number }[]) => {
        const out: { time: UTCTimestamp; value: number }[] = [];
        for (const pt of pts) {
          const t = Math.floor(pt.time / 1000) as UTCTimestamp;
          if (out.length && out[out.length - 1].time >= t) out[out.length - 1] = { time: out[out.length - 1].time, value: pt.value };
          else out.push({ time: t, value: pt.value });
        }
        return out;
      };
      const rising = equity[equity.length - 1].value >= equity[0].value;
      const c = rising ? p.up : p.down;
      chart.addSeries(AreaSeries, { lineColor: c, topColor: `${c}33`, bottomColor: `${c}00`, lineWidth: 2, title: "Strategy" }).setData(dedupe(equity));
      if (benchmark && benchmark.length > 0) {
        chart.addSeries(LineSeries, { color: p.text, lineWidth: 1, lineStyle: 2, title: benchmarkName ?? "Benchmark", priceLineVisible: false }).setData(dedupe(benchmark));
      }
      chart.timeScale().fitContent();
    };
    build();
    window.addEventListener("st-theme-change", build);
    return () => {
      window.removeEventListener("st-theme-change", build);
      chart?.remove();
    };
  }, [equity, benchmark, benchmarkName]);
  return <div ref={container} role="img" aria-label={ariaLabel} style={{ height }} className="w-full" />;
}
