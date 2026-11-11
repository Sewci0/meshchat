// The saved route to a contact (or room): which repeaters your DMs go through, how each is doing,
// when and how the route was learned, what it replaced, how your recent DMs on it went, what it
// costs on air, and Reset path. MeshCore keeps one route per contact: it's learned from the PATH
// packet that answers a flooded message, and a DM's last try floods (and learns again) by itself.
import { useActions } from "@/components/app-provider"
import { NodeAvatar, SignalBars, Stat } from "@/components/mesh-bits"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet"
import { Spinner } from "@/components/ui/spinner"
import { api } from "@/lib/api"
import { ago, clock, hopLabel, km, plural, resolvePath, splitPath, SNR_LEVELS, snrQuality, type ResolvedHop } from "@/lib/mesh"
import { airtimeMs } from "@/lib/packet-anatomy"
import { keys, useAppState, useMessages, useNodes, useRadioSf, useRepeaterDays, useRepeaters } from "@/lib/queries"
import { dmConv } from "@/lib/routes"
import type { AppState, Contact, Home, MeshNode, Message, RepeaterSummary } from "@/lib/types"
import { useAsync } from "@/lib/use-async"
import { cn } from "@/lib/utils"
import { useQueryClient } from "@tanstack/react-query"
import { AlertTriangleIcon, MapIcon, RadioTowerIcon, RouteOffIcon, UserIcon } from "lucide-react"
import { Fragment, useMemo, type ReactNode } from "react"

/** A saved route runs from you to them; resolvePath names hops from the far end towards you,
 *  so resolve it reversed and turn the answer back round. */
export function resolveRoute(hex: string | null | undefined, size: number, home: Home | undefined, nodes: Map<string, MeshNode>) {
  const hops = splitPath(hex, size)
  const r = resolvePath([...hops].reverse().join(""), size, home, nodes)
  return { hops, resolved: [...r.resolved].reverse() }
}

export const hasRoute = (c: Contact | undefined) => c?.out_path_len != null && c.out_path_len >= 0

/** "2 hops via A → B", "direct", "no saved route" */
export function routeSummary(c: Contact, state: AppState | undefined, nodes: Map<string, MeshNode>) {
  if (!hasRoute(c)) return "no saved route: the next message floods"
  if (c.out_path_len === 0) return "direct route, no repeater in between"
  const { hops, resolved } = resolveRoute(c.out_path, (c.hash_mode ?? 0) + 1, state?.home, nodes)
  return `route via ${hops.map((h, i) => hopLabel(resolved[i], h)).join(" → ")}`
}

export function RouteSheet({ contact, open, onOpenChange }: { contact: Contact | undefined; open: boolean; onOpenChange: (o: boolean) => void }) {
  return (
    <Sheet open={open && !!contact} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="gap-0 p-0 pt-safe pb-safe data-[side=right]:w-full data-[side=right]:sm:max-w-xl [&>[data-slot=sheet-close]]:top-[calc(env(safe-area-inset-top)+0.75rem)]">
        <SheetHeader className="border-b pr-12">
          <SheetTitle>Route to {contact?.name}</SheetTitle>
          <SheetDescription>The repeaters your messages to {contact?.type === "room" ? "this room" : "them"} go through, and how that's going.</SheetDescription>
        </SheetHeader>
        {contact ? <RouteDetails c={contact} onClose={() => onOpenChange(false)} /> : null}
      </SheetContent>
    </Sheet>
  )
}

function Section({ title, aside, children }: { title: string; aside?: ReactNode; children: ReactNode }) {
  return (
    <section className="grid gap-2">
      <div className="flex items-baseline justify-between gap-2">
        <h3 className="text-sm font-medium">{title}</h3>
        {aside ? <div className="text-xs text-muted-foreground">{aside}</div> : null}
      </div>
      {children}
    </section>
  )
}

const at = (t: number) => `${clock(t)}, ${ago(t)}`
const ms = (v: number) => (v < 1000 ? `${Math.round(v)} ms` : `${(v / 1000).toFixed(1)} s`)
const median = (xs: number[]) => {
  if (!xs.length) return null
  const s = [...xs].sort((a, b) => a - b), m = s.length >> 1
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2
}

function RouteDetails({ c, onClose }: { c: Contact; onClose: () => void }) {
  const { data: state } = useAppState()
  const nodes = useNodes()
  const { data: messages } = useMessages(dmConv(c.pubkey))
  const { showOnMap } = useActions()
  const size = (c.hash_mode ?? 0) + 1
  const routed = hasRoute(c)
  const { hops, resolved } = useMemo(() => resolveRoute(c.out_path, size, state?.home, nodes), [c.out_path, size, state?.home, nodes])
  const delivery = useMemo(() => deliveryStats(messages ?? []), [messages])
  const h = c.route

  const onMap = routed && hops.length ? () => {
    onClose()
    const names = ["you", ...hops.map((x, i) => hopLabel(resolved[i], x)), c.name]
    showOnMap({ kind: "route", label: `Route to ${c.name}: ${names.join(" → ")}`, message: {
      id: 0, ts: 0, sender_ts: null, conv: dmConv(c.pubkey), direction: "in", sender: c.name, text: "", hops: hops.length,
      path: [...hops].reverse().join(""), hash_size: size, snr: null, rssi: null, status: "received", repeats: 0, msg_hash: null,
    } })
  } : undefined

  return (
    <div className="min-h-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain">
      <div className="grid gap-6 p-4">
        <Glance c={c} hops={hops.length} delivery={delivery} />
        <Path c={c} hops={hops} resolved={resolved} onMap={onMap} />
        {h || routed ? <History c={c} /> : null}
        <Delivery d={delivery} c={c} />
        {routed ? <OnAir hops={hops.length} size={size} /> : null}
        <Reset c={c} delivery={delivery} />
      </div>
    </div>
  )
}

// ---------------------------------------------------------------- at a glance
function Glance({ c, hops, delivery }: { c: Contact; hops: number; delivery: DeliveryStats }) {
  const h = c.route
  const routed = hasRoute(c)
  const learned = h?.learned ?? null
  return (
    <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
      <Stat value={!routed ? "flood" : hops === 0 ? "direct" : hops} label={!routed ? "no saved route" : hops === 0 ? "no repeater between" : hops === 1 ? "hop" : "hops"}
        hint={!routed ? "the next message floods and learns one" : `${(c.hash_mode ?? 0) + 1}-byte repeater IDs`} />
      <Stat value={learned ? ago(learned) : routed ? "earlier" : "—"} label="learned"
        hint={learned ? clock(learned) : routed ? "before MeshChat kept track, or by another app" : h?.reset ? `reset ${ago(h.reset.at)}` : "no route yet"} />
      <Stat value={delivery.sent ? `${delivery.delivered}/${delivery.sent}` : "—"} label="recent DMs delivered"
        hint={delivery.sent ? `${Math.round((delivery.delivered / delivery.sent) * 100)}% of the last ${delivery.sent}` : "none sent yet"} />
      <Stat value={delivery.rttDirect != null ? ms(delivery.rttDirect) : "—"} label="round trip on the route" hint="median, send to receipt" />
      <Stat value={delivery.rttFlood != null ? ms(delivery.rttFlood) : "—"} label="round trip by flood" hint="median, send to receipt" />
      <Stat value={h ? h.changes : "—"} label="route changes" hint={h ? `${plural(h.learns, "route", "routes")} learned` : "nothing recorded yet"} />
    </div>
  )
}

// ---------------------------------------------------------------- the path, hop by hop
function Path({ c, hops, resolved, onMap }: { c: Contact; hops: string[]; resolved: (ResolvedHop | null)[]; onMap?: () => void }) {
  const { data: state } = useAppState()
  const sf = useRadioSf()
  const [days] = useRepeaterDays()
  const { data: reps } = useRepeaters(days, { glance: true })
  const me = state?.self.name ?? "You"
  const routed = hasRoute(c)
  if (!routed) return (
    <Section title="Route">
      <p className="rounded-lg border bg-muted/30 p-3 text-sm text-muted-foreground">
        Your radio has no saved route to {c.name}. The next message floods: every repeater that hears it passes it on once, and
        when it arrives, {c.name}'s radio sends back the path it took. That becomes the route for the messages after it.
      </p>
    </Section>
  )
  const loc = (r: ResolvedHop | null) => (r && r.node.lat != null && r.node.lon != null ? { lat: r.node.lat, lon: r.node.lon } : null)
  const them = c.lat != null && c.lon != null ? { lat: c.lat, lon: c.lon } : null
  // the points in order: you, each repeater, them (null where unknown)
  const points = [state?.home ?? null, ...resolved.map(loc), them]
  let total = 0, complete = true
  for (let i = 0; i + 1 < points.length; i++) {
    const a = points[i], b = points[i + 1]
    if (a && b) total += km(a, b); else complete = false
  }
  const leg = (i: number) => { const a = points[i], b = points[i + 1]; return a && b ? `${km(a, b).toFixed(1)} km` : null }
  const steps: { icon: ReactNode; title: ReactNode; sub: ReactNode; warn?: boolean }[] = []
  steps.push({ icon: <UserIcon className="size-3.5" />, title: me, sub: hops.length ? `sends it to ${hopLabel(resolved[0], hops[0])}${leg(0) ? ` · ${leg(0)}` : ""}` : `straight to ${c.name}${leg(0) ? ` · ${leg(0)}` : ""}` })
  hops.forEach((hx, i) => {
    const r = resolved[i]
    const s: RepeaterSummary | undefined = r ? reps?.repeaters.find((x) => x.key === r.node.pubkey) : undefined
    const heard = r?.node.heard?.last_heard ?? r?.node.last_advert
    const quiet = r && reps?.your_repeater === r.node.pubkey && reps.your_repeater_quiet
    const health = s
      ? `passed on ${plural(s.relayed, "packet", "packets")} in the ${days === 1 ? "last 24 h" : `last ${days} days`}${s.last_ts ? `, last ${ago(s.last_ts)}` : ""}`
      : heard ? `advert heard ${ago(heard)}` : "not heard lately"
    steps.push({
      icon: <RadioTowerIcon className="size-3.5" />,
      warn: !!quiet || (!s && !heard),
      title: <><code className="mr-1.5 rounded bg-muted px-1 py-0.5 font-mono text-[11px]">{hx}</code>{r ? r.node.name : <span className="text-muted-foreground">unknown repeater</span>}</>,
      sub: <>
        {[i === 0 ? "must hear you" : "", r?.ambiguous ? `${r.ambiguous} repeaters share this ID: nearest shown` : "", leg(i + 1) ? `${leg(i + 1)} to the next` : ""].filter(Boolean).join(" · ")}
        <span className="block">{quiet ? "gone quiet: nothing heard from it lately" : health}
          {i === 0 && s?.snr_median != null ? <> · you hear it at <span className="inline-flex items-center gap-1 align-[-1px]"><SignalBars snr={s.snr_median} />{s.snr_median} dB</span> ({SNR_LEVELS[snrQuality(s.snr_median, sf)]})</> : null}
        </span>
      </>,
    })
  })
  steps.push({ icon: <NodeAvatar name={c.name} className="size-6" />, title: c.name, sub: c.type === "room" ? "stores the post and confirms it" : "receives it and sends a receipt back" })
  return (
    <Section title="Route" aside={onMap ? <Button size="xs" variant="ghost" onClick={onMap}><MapIcon />On the map</Button> : undefined}>
      <ol className="grid">
        {steps.map((s, i) => (
          <li key={i} className="grid grid-cols-[1.5rem_1fr] gap-x-2">
            <div className="flex flex-col items-center">
              <span className={cn("grid size-6 place-items-center rounded-full border bg-background text-muted-foreground", s.warn && "border-amber-500 text-amber-600 dark:text-amber-400")}>{s.icon}</span>
              {i < steps.length - 1 ? <span className="w-px flex-1 bg-border" /> : null}
            </div>
            <div className="min-w-0 pb-3">
              <p className="truncate text-sm">{s.title}</p>
              <p className="text-xs text-muted-foreground">{s.sub}</p>
            </div>
          </li>
        ))}
      </ol>
      <p className="text-xs text-muted-foreground">
        {hops.length ? `${plural(hops.length + 1, "transmission", "transmissions")} each way` : "One transmission each way"}
        {total ? ` · ${complete ? "" : "at least "}${total.toFixed(1)} km in all` : ""}
        . The receipt comes back along the same repeaters.
      </p>
    </Section>
  )
}

// ---------------------------------------------------------------- history
function History({ c }: { c: Contact }) {
  const { data: state } = useAppState()
  const nodes = useNodes()
  const h = c.route
  const prev = h?.previous
  const prevNames = useMemo(() => {
    if (!prev) return null
    if (prev.out_path_len === 0) return "direct, no repeater"
    const r = resolveRoute(prev.out_path, prev.hash_mode + 1, state?.home, nodes)
    return r.hops.map((x, i) => hopLabel(r.resolved[i], x)).join(" → ")
  }, [prev, state?.home, nodes])
  const routed = hasRoute(c)
  const by = { you: "you (Reset path)", retry: "a DM's last try, which floods to find a new one", app: "another app on this radio", "": "an app" } as const
  const rows: [string, ReactNode][] = []
  if (routed) rows.push(["Learned", h?.learned ? at(h.learned) : "before MeshChat kept track (or by another app)"])
  if (routed && h?.confirmed && h.learned && h.confirmed - h.learned > 30) rows.push(["Re-learned", `${at(h.confirmed)}: the same route again`])
  if (routed && h?.via) rows.push(["Came back", <>in a PATH packet over {h.via.hops === 0 ? "no repeaters" : plural(h.via.hops, "hop", "hops")}
    {h.via.snr != null ? <> at <span className="inline-flex items-center gap-1 align-[-1px]"><SignalBars snr={h.via.snr} />{h.via.snr} dB</span>{h.via.rssi ? `, ${h.via.rssi} dBm` : ""}</> : null}
    <span className="text-muted-foreground"> (packet #{h.via.pkt_id})</span></>])
  if (h) rows.push(["Learned so far", `${plural(h.learns, "time", "times")}, ${h.changes ? `changed ${plural(h.changes, "time", "times")}` : "never changed"}`])
  if (prev) rows.push([h?.reset && !routed ? "Forgotten route" : "Before this", <>{prevNames}<span className="text-muted-foreground">{prev.since ? ` · from ${at(prev.since)}` : ""}</span></>])
  if (h?.reset) rows.push(["Last reset", `${at(h.reset.at)}, by ${by[h.reset.by] ?? "an app"}`])
  return (
    <Section title="History" aside="kept by MeshChat as routes are learned">
      <dl className="grid grid-cols-[7.5rem_1fr] gap-x-3 gap-y-1.5 rounded-lg border p-3 text-sm">
        {rows.map(([k, v]) => <Fragment key={k}><dt className="text-muted-foreground">{k}</dt><dd className="min-w-0 wrap-anywhere">{v}</dd></Fragment>)}
      </dl>
    </Section>
  )
}

// ---------------------------------------------------------------- how your DMs went
type Outcome = "route" | "flood" | "delivered" | "no ack" | "failed" | "pending"
interface DeliveryStats {
  sent: number; delivered: number; firstTry: number; byRoute: number; byFlood: number; noAck: number; failed: number
  rttDirect: number | null; rttFlood: number | null
  recent: { m: Message; outcome: Outcome }[]
  /** of the last few, how many got no receipt (a stale route shows up as a run of these) */
  recentMisses: number
}
function outcome(m: Message): Outcome {
  if (m.status === "sending" || m.status === "sent") return "pending"
  if (m.status === "no ack") return "no ack"
  if (m.status === "failed") return "failed"
  if (m.status !== "delivered") return "pending"
  if (!m.ack_try || !m.tries_flood) return "delivered"
  return m.tries_flood[m.ack_try - 1] ? "flood" : "route"
}
function deliveryStats(all: Message[]): DeliveryStats {
  const out = all.filter((m) => m.direction === "out").slice(-40)
  const done = out.map((m) => ({ m, outcome: outcome(m) })).filter((x) => x.outcome !== "pending")
  const rt = (o: Outcome) => done.filter((x) => x.outcome === o && x.m.rtt_ms).map((x) => x.m.rtt_ms!)
  const last = done.slice(-5)
  return {
    sent: done.length,
    delivered: done.filter((x) => ["route", "flood", "delivered"].includes(x.outcome)).length,
    firstTry: done.filter((x) => x.m.ack_try === 1).length,
    byRoute: done.filter((x) => x.outcome === "route").length,
    byFlood: done.filter((x) => x.outcome === "flood").length,
    noAck: done.filter((x) => x.outcome === "no ack").length,
    failed: done.filter((x) => x.outcome === "failed").length,
    rttDirect: median(rt("route")), rttFlood: median(rt("flood")),
    recent: out.slice(-8).reverse().map((m) => ({ m, outcome: outcome(m) })),
    recentMisses: last.filter((x) => x.outcome === "no ack").length,
  }
}

const OUTCOME: Record<Outcome, { label: string; cls: string }> = {
  route: { label: "delivered on the route", cls: "text-emerald-700 dark:text-emerald-400" },
  flood: { label: "delivered by flood", cls: "text-emerald-700 dark:text-emerald-400" },
  delivered: { label: "delivered", cls: "text-emerald-700 dark:text-emerald-400" },
  "no ack": { label: "no receipt", cls: "text-amber-700 dark:text-amber-400" },
  failed: { label: "not sent", cls: "text-destructive" },
  pending: { label: "waiting", cls: "text-muted-foreground" },
}

/** today: "20:51"; earlier: "Sun 20:51" */
const when = (t: number) => new Date(t * 1000).toDateString() === new Date().toDateString() ? clock(t)
  : `${new Date(t * 1000).toLocaleDateString([], { weekday: "short" })} ${clock(t)}`

function Delivery({ d, c }: { d: DeliveryStats; c: Contact }) {
  const { data: state } = useAppState()
  if (!d.recent.length) return (
    <Section title="Your recent messages"><p className="text-sm text-muted-foreground">You haven't sent any here yet.</p></Section>
  )
  const known = d.byRoute + d.byFlood
  const adv = state?.advertised?.flood ? `your last flood advert went out ${ago(state.advertised.ts)}` : "you haven't sent a flood advert yet"
  return (
    <Section title="Your recent messages" aside={`last ${d.sent} with an outcome`}>
      {d.sent >= 3 && d.delivered === 0 ? (
        <p className="flex gap-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 text-sm">
          <AlertTriangleIcon className="mt-0.5 size-4 shrink-0 text-amber-600 dark:text-amber-400" />
          <span>
            None of these got a receipt, on any route. Either they don't reach {c.name}, or {c.name}'s radio can't read them: it needs
            your advert to know your key ({adv}).{" "}
            {c.last_advert ? `Their last advert reached you ${ago(c.last_advert)}.` : `Your radio has never heard ${c.name}'s advert, so they may be out of range or offline.`}
          </span>
        </p>
      ) : null}
      <div className="grid grid-cols-2 gap-x-6 gap-y-1 rounded-lg border p-3 text-sm sm:grid-cols-3">
        <Count n={d.firstTry} label="first try" />
        <Count n={d.byRoute} label="on the route" />
        <Count n={d.byFlood} label="by flood" />
        <Count n={d.noAck} label="no receipt" warn={d.noAck > 0} />
        <Count n={d.failed} label="not sent" warn={d.failed > 0} />
        <Count n={d.delivered - known} label="delivered (older, no detail)" />
      </div>
      <ol className="divide-y rounded-lg border text-sm">
        {d.recent.map(({ m, outcome: o }) => (
          <li key={m.id} className="grid gap-0.5 px-3 py-2">
            <div className="flex items-baseline gap-2">
              <span className="min-w-0 flex-1 truncate">{m.text}</span>
              <time className="shrink-0 text-xs text-muted-foreground tabular-nums">{when(m.ts)}</time>
            </div>
            <div className="flex flex-wrap items-center gap-x-2 gap-y-0.5 text-xs text-muted-foreground">
              <span className={OUTCOME[o].cls}>{OUTCOME[o].label}{m.ack_try ? ` on try ${m.ack_try}` : ""}</span>
              {m.rtt_ms ? <span className="tabular-nums">· receipt after {ms(m.rtt_ms)}</span> : null}
              {m.tries_flood?.length ? <span>· tries: {m.tries_flood.map((f) => (f ? "flood" : "route")).join(" → ")}</span> : null}
            </div>
          </li>
        ))}
      </ol>
      <p className="text-xs text-muted-foreground">
        Each message goes on the saved route twice, then the radio forgets the route and floods it once. A receipt by flood
        brings a fresh route with it.
      </p>
    </Section>
  )
}
function Count({ n, label, warn }: { n: number; label: string; warn?: boolean }) {
  return (
    <div className="flex items-baseline gap-1.5">
      <span className={cn("font-semibold tabular-nums", warn && "text-amber-700 dark:text-amber-400")}>{n}</span>
      <span className="text-muted-foreground">{label}</span>
    </div>
  )
}

// ---------------------------------------------------------------- airtime
function OnAir({ hops, size }: { hops: number; size: number }) {
  const { data: state } = useAppState()
  const radio = state?.self.radio
  if (!radio) return null
  // a 50-character DM: header, path length, path, then to/from/MAC and the text encrypted in 16-byte blocks
  const text = 50, cipher = Math.ceil((5 + text) / 16) * 16
  const pkt = 2 + hops * size + 4 + cipher
  const ack = 2 + hops * size + 4
  const tx = hops + 1
  const one = airtimeMs(pkt, radio.sf, radio.bw, radio.cr), back = airtimeMs(ack, radio.sf, radio.bw, radio.cr)
  return (
    <Section title="On air" aside={`SF${radio.sf} · ${radio.bw} kHz`}>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
        <Stat value={`${pkt} B`} label="a 50-character DM" hint={`${hops * size} B of it is the route`} />
        <Stat value={ms(one)} label="per transmission" hint={`sent ${plural(tx, "time", "times")} on the way`} />
        <Stat value={ms(one * tx + back * tx)} label="in all, with the receipt" hint={`receipt: ${ack} B, ${ms(back)} a hop`} />
      </div>
      <p className="text-xs text-muted-foreground">A flood costs more: every repeater that hears it sends it once, whether it's on the way or not.</p>
    </Section>
  )
}

// ---------------------------------------------------------------- reset
/** Reset path, from here or the conversation menu: forget the route, then wait for the radio's
 *  contact list (rebuilt a moment later) to show it gone. */
export function useResetPath() {
  const qc = useQueryClient()
  const { run, isBusy } = useAsync()
  const reset = (c: Contact) => run(async () => {
    await api.resetPath(c.pubkey)
    for (let i = 0; i < 6; i++) {
      await new Promise((r) => setTimeout(r, 1000))
      await qc.refetchQueries({ queryKey: keys.state })
      const x = qc.getQueryData<AppState>(keys.state)?.contacts[c.pubkey]
      if (!x || x.out_path_len == null || x.out_path_len < 0) break
    }
  }, { error: "Route not reset", success: { title: "Route forgotten", description: `Your next message to ${c.name} floods and learns a fresh route.` } })
  return { reset, busy: isBusy() }
}

function Reset({ c, delivery }: { c: Contact; delivery: DeliveryStats }) {
  const { reset: resetPath, busy } = useResetPath()
  const isBusy = () => busy
  const routed = hasRoute(c)
  const reset = () => resetPath(c)
  const stale = routed && delivery.recentMisses >= 2
  return (
    <Section title="Reset path">
      {stale ? (
        <p className="flex gap-2 rounded-lg border border-amber-500/40 bg-amber-500/5 p-3 text-sm">
          <AlertTriangleIcon className="mt-0.5 size-4 shrink-0 text-amber-600 dark:text-amber-400" />
          {delivery.recentMisses} of your last {Math.min(5, delivery.sent)} messages got no receipt. A repeater on the route
          may have moved or gone off the air; resetting makes the next one find a new way.
        </p>
      ) : null}
      <p className="text-sm text-muted-foreground">
        Routes mostly heal themselves: when a message gets no receipt on the route twice, its last try floods, and the receipt brings a
        new route. Reset it yourself when you know the route is wrong (a repeater on it was moved or switched off) or when every
        message needs that last try. The next message then floods, which costs more airtime once.
      </p>
      <div className="flex items-center gap-2">
        <Button variant="outline" disabled={!routed || isBusy()} onClick={() => void reset()}>
          {isBusy() ? <Spinner /> : <RouteOffIcon />}{routed ? "Reset path" : "No saved route to reset"}
        </Button>
        {c.route?.reset ? <Badge variant="secondary" className="font-normal">last reset {ago(c.route.reset.at)}</Badge> : null}
      </div>
    </Section>
  )
}
