import { Avatar, AvatarFallback } from "@/components/ui/avatar"
import { Badge } from "@/components/ui/badge"
import { initials, nameHue, SNR_LEVELS, snrQuality, tokenize, type SnrLevel } from "@/lib/mesh"
import type { NodeType } from "@/lib/types"
import { cn } from "@/lib/utils"
import { useRadioSf } from "@/lib/queries"
import type { ComponentProps, ReactNode } from "react"

// colour is never the only signal: aria-label/title, and the number is always shown alongside
const BAR_COLOR = ["", "bg-red-500", "bg-amber-500", "bg-emerald-500", "bg-emerald-500"]

/** Four bars for a signal's level (see snrQuality): red below the decode limit, amber marginal,
 *  green fair or good. Pass `level` and `label` to show something other than a LoRa SNR. */
export function SignalBars({ snr, level, label, className }: {
  snr?: number | null; level?: SnrLevel; label?: string; className?: string
}) {
  const sf = useRadioSf()
  const q = level ?? snrQuality(snr, sf)
  const text = label ?? (snr == null ? "no signal data" : `SNR ${snr} dB, ${SNR_LEVELS[q]}`)
  return (
    <span role="img" aria-label={text} title={text} className={cn("inline-flex h-3 items-end gap-px align-[-1px]", className)}>
      {[0.3, 0.53, 0.77, 1].map((h, i) => (
        <span key={i} style={{ height: `${h * 100}%` }}
          className={cn("w-[3px] rounded-[1px] bg-muted-foreground/25", i < q && BAR_COLOR[q])} />
      ))}
    </span>
  )
}

export function NodeAvatar({ name, className }: { name: string; className?: string }) {
  const hue = nameHue(name)
  return (
    <Avatar className={cn("size-8", className)}>
      <AvatarFallback className="text-[11px] font-semibold"
        style={{ backgroundColor: `oklch(0.9 0.06 ${hue})`, color: `oklch(0.35 0.08 ${hue})` }}>
        {initials(name)}
      </AvatarFallback>
    </Avatar>
  )
}

const TYPE_STYLE: Record<NodeType, string> = {
  repeater: "text-sky-700 dark:text-sky-300 bg-sky-500/10",
  companion: "text-emerald-700 dark:text-emerald-300 bg-emerald-500/10",
  room: "text-violet-700 dark:text-violet-300 bg-violet-500/10",
  sensor: "text-amber-700 dark:text-amber-300 bg-amber-500/10",
  unknown: "text-muted-foreground bg-muted",
}
export function TypeBadge({ type }: { type: NodeType | string }) {
  return <Badge variant="secondary" className={cn("border-0 font-medium", TYPE_STYLE[type as NodeType] ?? TYPE_STYLE.unknown)}>{type}</Badge>
}

export function Sparkline({ values, className, tall }: { values: number[]; className?: string; tall?: boolean }) {
  const max = Math.max(1, ...values)
  return (
    <span aria-hidden className={cn("inline-flex items-end gap-px", tall ? "h-16 w-full gap-[3px]" : "h-4", className)}>
      {values.map((v, i) => (
        <span key={i} style={{ height: `${Math.max(v ? 10 : 4, Math.round((v / max) * 100))}%` }}
          className={cn("rounded-[1px] bg-primary", tall ? "flex-1" : "w-[3px]", !v && "opacity-20")} />
      ))}
    </span>
  )
}

/** Message text with @[Name] tags. Mesh text is untrusted: it is only ever rendered as text. */
export function MessageText({ text, renderTag }: { text: string; renderTag: (name: string) => ReactNode }) {
  return (
    <>
      {tokenize(text).map((t, i) => ("tag" in t ? <span key={i}>{renderTag(t.tag)}</span> : <span key={i}>{t.text}</span>))}
    </>
  )
}

/** An @mention. `onPrimary`: inside your own message bubble, which is already the primary colour. */
export function TagChip({ name, me, onPrimary, ...props }: { name: string; me?: boolean; onPrimary?: boolean } & ComponentProps<"button">) {
  return (
    <button type="button" {...props}
      className={cn("mx-px rounded px-1 font-medium transition-colors focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none",
        onPrimary
          ? me ? "bg-primary-foreground text-primary" : "bg-primary-foreground/15 text-primary-foreground hover:bg-primary-foreground/25"
          : me ? "bg-primary text-primary-foreground" : "bg-primary/10 text-primary hover:bg-primary/20")}>
      @{name}
    </button>
  )
}

export function Stat({ value, label, hint }: { value: ReactNode; label: string; hint?: ReactNode }) {
  return (
    <div className="rounded-xl border bg-card p-3">
      <div className="text-xl font-semibold tabular-nums leading-tight">{value}</div>
      <div className="text-xs text-muted-foreground">{label}</div>
      {hint ? <div className="mt-0.5 text-[11px] text-muted-foreground/80">{hint}</div> : null}
    </div>
  )
}
