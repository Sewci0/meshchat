// How strongly a repeater's packets arrive at your radio, over time: one dot per packet heard
// directly from it and a running median through them, over shaded bands for the signal levels
// (below the decode limit at the current spreading factor, marginal, fair, good). Plain SVG,
// sized to its container.
import { clock, snrFloor, SNR_LEVELS, SNR_STEPS, snrQuality, type SnrLevel } from "@/lib/mesh"
import type { SignalPoint } from "@/lib/types"
import { cn } from "@/lib/utils"
import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent } from "react"

const H = 180
const M = { top: 12, right: 48, bottom: 22, left: 34 }
const WINDOW = 15   // points in the running median

// band fills by level (tokens in index.css); fair is left plain so the four read as distinct
const BAND_FILL: Record<number, string> = { 1: "var(--band-below)", 2: "var(--band-marginal)", 4: "var(--band-good)" }

const fmtDb = (v: number) => `${v > 0 ? "+" : v < 0 ? "−" : ""}${Math.abs(Math.round(v * 10) / 10)}`
const median = (xs: number[]) => { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)] }

function useWidth() {
  const ref = useRef<HTMLDivElement>(null)
  const [w, setW] = useState(0)
  useEffect(() => {
    const el = ref.current
    if (!el) return
    const ro = new ResizeObserver(([e]) => setW(Math.round(e.contentRect.width)))
    ro.observe(el)
    return () => ro.disconnect()
  }, [])
  return [ref, w] as const
}

function timeLabel(ts: number, spanDays: boolean) {
  const d = new Date(ts * 1000)
  return spanDays ? `${d.toLocaleDateString([], { weekday: "short" })} ${clock(ts)}` : clock(ts)
}

export function SignalChart({ points, sf, className }: { points: SignalPoint[]; sf: number; className?: string }) {
  const [ref, width] = useWidth()
  const [active, setActive] = useState<number | null>(null)
  const floor = snrFloor(sf)

  const g = useMemo(() => {
    if (!points.length || width < 120) return null
    const iw = width - M.left - M.right, ih = H - M.top - M.bottom
    // ends at the newest packet: the chart never runs on into time that hasn't happened
    const t1 = points[points.length - 1].ts
    const t0 = Math.min(points[0].ts, t1 - 600)   // a single burst: at least 10 minutes, the room before it
    const snrs = points.map((p) => p.snr)
    const step = Math.max(...snrs) - Math.min(...snrs, floor) > 30 ? 10 : 5
    const lo = Math.floor((Math.min(floor - 2.5, ...snrs) - 1) / step) * step
    const hi = Math.ceil((Math.max(floor + 10, ...snrs) + 1) / step) * step
    const x = (t: number) => M.left + ((t - t0) / (t1 - t0)) * iw
    const y = (v: number) => M.top + (1 - (v - lo) / (hi - lo)) * ih
    const yTicks: number[] = []
    for (let v = lo; v <= hi; v += step) yTicks.push(v)
    const spanDays = t1 - t0 > 20 * 3600
    const xTicks = Array.from({ length: iw > 360 ? 4 : 3 }, (_, i) => t0 + ((t1 - t0) * (i + 0.5)) / (iw > 360 ? 4 : 3))
    // running median, centred
    const half = Math.floor(WINDOW / 2)
    const trend = points.map((_, i) => median(snrs.slice(Math.max(0, i - half), i + half + 1)))
    const line = points.map((p, i) => `${i ? "L" : "M"}${x(p.ts).toFixed(1)},${y(trend[i]).toFixed(1)}`).join("")
    // the four levels as horizontal bands, clipped to the axis
    const edges = [lo, ...SNR_STEPS.map((s) => floor + s), hi]
    const bands = ([1, 2, 3, 4] as SnrLevel[]).map((level, i) => ({ level, from: Math.max(lo, edges[i]), to: Math.min(hi, edges[i + 1]) }))
      .filter((b) => b.to > b.from)
    return { x, y, yTicks, xTicks, spanDays, line, trend, iw, ih, lo, hi, bands }
  }, [points, width, floor])

  // pointer: snap to the packet nearest in time
  const xs = useMemo(() => (g ? points.map((p) => g.x(p.ts)) : []), [g, points])
  const nearest = (px: number) => {
    let a = 0, b = xs.length - 1
    while (b - a > 1) { const m = (a + b) >> 1; if (xs[m] < px) a = m; else b = m }
    return Math.abs(xs[a] - px) <= Math.abs(xs[b] - px) ? a : b
  }
  const onPointer = (e: PointerEvent<SVGSVGElement>) => {
    if (!xs.length) return
    const r = e.currentTarget.getBoundingClientRect()
    setActive(nearest(e.clientX - r.left))
  }
  const onKey = (e: KeyboardEvent<SVGSVGElement>) => {
    if (!points.length) return
    const last = points.length - 1
    if (e.key === "ArrowLeft") { setActive((a) => Math.max(0, (a ?? last) - 1)); e.preventDefault() }
    else if (e.key === "ArrowRight") { setActive((a) => Math.min(last, (a ?? last) + 1)); e.preventDefault() }
    else if (e.key === "Home") setActive(0)
    else if (e.key === "End") setActive(last)
    else if (e.key === "Escape") setActive(null)
  }

  const p = active != null ? points[active] : null
  const med = points.length ? median(points.map((q) => q.snr)) : null
  const summary = points.length
    ? `Signal at your radio: ${points.length} packets, median ${fmtDb(med!)} dB (${SNR_LEVELS[snrQuality(med, sf)]}), latest ${fmtDb(points[points.length - 1].snr)} dB. Decoding stops below ${fmtDb(floor)} dB at SF${sf}; marginal up to ${SNR_STEPS[1]} dB above that, fair up to ${SNR_STEPS[2]}, good beyond.`
    : "No packets heard directly yet."

  return (
    <div ref={ref} className={cn("relative w-full select-none", className)} style={{ height: H }}>
      {g ? (
        <svg width={width} height={H} role="img" aria-label={summary} tabIndex={0}
          className="touch-pan-y rounded-md outline-none focus-visible:ring-2 focus-visible:ring-ring"
          onPointerMove={onPointer} onPointerDown={onPointer} onPointerLeave={(e) => e.pointerType === "mouse" && setActive(null)}
          onFocus={() => setActive((a) => a ?? points.length - 1)} onBlur={() => setActive(null)} onKeyDown={onKey}>
          {/* signal levels, behind everything */}
          {g.bands.map((b) => (
            <rect key={b.level} x={M.left} width={g.iw} y={g.y(b.to)} height={g.y(b.from) - g.y(b.to)} fill={BAND_FILL[b.level] ?? "none"} />
          ))}
          {/* grid and y axis */}
          {g.yTicks.map((v) => (
            <g key={v}>
              <line x1={M.left} x2={M.left + g.iw} y1={g.y(v)} y2={g.y(v)} stroke="var(--border)" strokeWidth={1} />
              <text x={M.left - 6} y={g.y(v)} dy="0.32em" textAnchor="end" className="fill-muted-foreground text-[10px] tabular-nums">{fmtDb(v)}</text>
            </g>
          ))}
          {g.xTicks.map((t) => (
            <text key={t} x={g.x(t)} y={H - 6} textAnchor="middle" className="fill-muted-foreground text-[10px] tabular-nums">{timeLabel(t, g.spanDays)}</text>
          ))}
          {/* where decoding stops at this SF */}
          <line x1={M.left} x2={M.left + g.iw} y1={g.y(floor)} y2={g.y(floor)} stroke="var(--muted-foreground)" strokeWidth={1} strokeDasharray="4 3" />
          {/* packets, then the running median on top */}
          {points.map((q, i) => (
            <circle key={i} cx={xs[i]} cy={g.y(q.snr)} r={4} fill="var(--signal)" fillOpacity={0.45} stroke="var(--background)" strokeWidth={1.5} />
          ))}
          <path d={g.line} fill="none" stroke="var(--signal)" strokeWidth={2} strokeLinejoin="round" strokeLinecap="round" />
          <text x={M.left + g.iw + 6} y={g.y(g.trend[g.trend.length - 1])} dy="0.32em" className="fill-foreground text-[11px] font-medium tabular-nums">
            {fmtDb(g.trend[g.trend.length - 1])} dB
          </text>
          {/* each band named at its top left, over the dots (a halo keeps the words readable) */}
          {g.bands.map((b) => g.y(b.from) - g.y(b.to) >= 14 ? (
            <text key={b.level} x={M.left + 4} y={g.y(b.to) + 11} stroke="var(--background)" strokeWidth={3} style={{ paintOrder: "stroke" }}
              className="pointer-events-none fill-muted-foreground text-[10px]">
              {b.level === 1 ? `below the decode limit (${fmtDb(floor)} dB at SF${sf})` : SNR_LEVELS[b.level]}
            </text>
          ) : null)}
          {/* hover / focus */}
          {p && active != null ? (
            <g pointerEvents="none">
              <line x1={xs[active]} x2={xs[active]} y1={M.top} y2={M.top + g.ih} stroke="var(--foreground)" strokeOpacity={0.25} strokeWidth={1} />
              <circle cx={xs[active]} cy={g.y(p.snr)} r={5.5} fill="var(--signal)" stroke="var(--background)" strokeWidth={2} />
            </g>
          ) : null}
        </svg>
      ) : null}
      {g && p && active != null ? (
        <div role="status" className="pointer-events-none absolute top-1 z-10 rounded-md border bg-popover px-2 py-1 text-xs text-popover-foreground shadow-md"
          style={xs[active] > width / 2 ? { right: width - xs[active] + 10 } : { left: xs[active] + 10 }}>
          <div className="text-sm font-semibold tabular-nums">{fmtDb(p.snr)} dB <span className="text-xs font-normal text-muted-foreground">SNR · {SNR_LEVELS[snrQuality(p.snr, sf)]}</span></div>
          <div className="text-muted-foreground tabular-nums">{p.rssi != null ? `${p.rssi} dBm · ` : ""}{p.type} · {timeLabel(p.ts, true)}</div>
        </div>
      ) : null}
    </div>
  )
}
