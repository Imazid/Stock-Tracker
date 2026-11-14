"use client";

import { useId, useState, type KeyboardEvent } from "react";
import { Activity } from "lucide-react";
import { dateText, money, type Bar, type Point } from "../lib/models";

export default function Chart({ points, candles, currency = "USD", empty = "No price history yet.", history, comparison }: {
  points: Point[]; candles?: Bar[]; currency?: string; empty?: string;
  history?: { label: string; valueLabel: string };
  comparison?: { label: string; points: Point[] };
}) {
  const id = useId();
  const [focus, setFocus] = useState<number | null>(null);
  const left = 12, right = 700, top = 20, bottom = 224;
  const active = focus == null ? null : Math.min(points.length - 1, focus);
  const values = candles?.length ? candles.flatMap(bar => [bar.high, bar.low])
    : [...points, ...(comparison?.points ?? [])].map(point => point.value);
  const dataMin = points.length ? Math.min(...values) : 0;
  const dataMax = points.length ? Math.max(...values) : 0;
  const padding = (dataMax - dataMin || Math.abs(dataMax) * 0.02 || 1) * 0.13;
  const lowest = dataMin - padding, highest = dataMax + padding;
  const y = (value: number) => bottom - (value - lowest) / (highest - lowest) * (bottom - top);
  const startTime = points[0]?.time ?? 0;
  const duration = (points.at(-1)?.time ?? 0) - startTime;
  const x = (index: number) => points.length === 1 ? (left + right) / 2
    : left + (history && duration > 0 ? (points[index].time - startTime) / duration : index / (points.length - 1)) * (right - left);
  const line = (series: Point[]) => series.map((point, index) => `${index ? "L" : "M"}${x(index).toFixed(1)} ${y(point.value).toFixed(1)}`).join(" ");
  const marker = active == null ? undefined : points[active];
  const tickTimes = history ? [0, points.length - 1] : [0, Math.floor((points.length - 1) / 2), points.length - 1];
  const barsWidth = Math.max(1.4, Math.min(12, 460 / points.length));
  function keyboard(event: KeyboardEvent<SVGSVGElement>) {
    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
    event.preventDefault();
    setFocus(index => Math.max(0, Math.min(points.length - 1, (index ?? (event.key === "ArrowLeft" ? points.length : -1)) + (event.key === "ArrowLeft" ? -1 : 1))));
  }

  return <div className={`chart ${history ? "history-chart" : ""} ${points.length === 0 ? "no-series" : ""}`}>
    <svg viewBox="0 0 800 258" preserveAspectRatio="none" role={points.length ? "group" : "presentation"}
      aria-label={points.length ? `${history?.label ?? "Historical chart"}. Use arrow keys to inspect ${history ? "values" : "prices"}.` : undefined}
      tabIndex={points.length ? 0 : undefined}
      onPointerMove={event => {
        if (!points.length) return;
        const box = event.currentTarget.getBoundingClientRect();
        const chartX = (event.clientX - box.left) / box.width * 800;
        if (!history) {
          setFocus(Math.max(0, Math.min(points.length - 1, Math.round((chartX - left) / (right - left) * (points.length - 1)))));
          return;
        }
        let lo = 0, hi = points.length - 1;
        while (lo < hi) {
          const mid = Math.floor((lo + hi) / 2);
          if (chartX <= (x(mid) + x(mid + 1)) / 2) hi = mid;
          else lo = mid + 1;
        }
        setFocus(lo);
      }}
      onPointerLeave={() => setFocus(null)} onBlur={() => setFocus(null)} onKeyDown={keyboard}>
      <defs><linearGradient id={id} x1="0" x2="0" y1="0" y2="1"><stop stopColor="#bbf567" stopOpacity=".22"/><stop offset="1" stopColor="#bbf567" stopOpacity="0"/></linearGradient></defs>
      {Array.from({ length: 5 }, (_, index) => {
        const gridY = top + index * (bottom - top) / 4;
        return <g key={index}><line x1="12" x2="704" y1={gridY} y2={gridY} className="gridline"/>
          <text x="722" y={gridY + 4}>{points.length ? money(highest - index * (highest - lowest) / 4, currency) : "—"}</text></g>;
      })}
      {!candles && !comparison && points.length > 1 && <path d={`${line(points)} L ${right} ${bottom} L ${left} ${bottom} Z`} fill={`url(#${id})`}/>}
      {!candles && points.length > 1 && <path vectorEffect="non-scaling-stroke" d={line(points)} className="chart-line"/>}
      {comparison && points.length > 1 && <path vectorEffect="non-scaling-stroke" d={line(comparison.points)} className="chart-comparison"/>}
      {!candles && points.length === 1 && <circle cx={x(0)} cy={y(points[0].value)} r="5" fill="#c9f86a"/>}
      {candles?.map((bar, index) => <g key={bar.time} className={bar.close >= bar.open ? "candle-up" : "candle-down"}>
        <line x1={x(index)} x2={x(index)} y1={y(bar.high)} y2={y(bar.low)}/>
        <rect x={x(index) - barsWidth / 2} width={barsWidth} y={Math.min(y(bar.open), y(bar.close))} height={Math.max(1.25, Math.abs(y(bar.open) - y(bar.close)))}/>
      </g>)}
      {points.length > 0 && [...new Set(tickTimes)].map(index =>
        <text key={index} x={x(index)} y="250" textAnchor={index === 0 ? "start" : index === points.length - 1 ? "end" : "middle"}>{new Intl.DateTimeFormat("en-AU", { day: "numeric", month: "short", timeZone: "UTC" }).format(points[index].time)}</text>)}
      {marker && active !== null && <><line x1={x(active)} x2={x(active)} y1={top} y2={bottom} className="crosshair"/><circle cx={x(active)} cy={y(marker.value)} r="4" fill="#c9f86a"/></>}
    </svg>
    {!points.length && <div className="chart-empty"><Activity size={19}/><span>{empty}</span></div>}
    {marker && <output className="chart-tip">{dateText(marker.time, true)}
      {history && <span className="chart-tip-label">{history.valueLabel}</span>} <strong>{money(marker.value, currency)}</strong>
      {comparison && active !== null && <><span className="chart-tip-label">{comparison.label}</span> <strong>{money(comparison.points[active]?.value, currency)}</strong></>}
    </output>}
  </div>;
}
