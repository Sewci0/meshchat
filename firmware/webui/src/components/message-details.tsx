// Message details: everything the radio knows about one message. Every copy it heard (one per route,
// or per repeater that passed ours on), the route of each with names and distances, signal, timing,
// the channel and its key, the sender's flags, and the packet byte by byte. Data from
// the radio's GET /api/message-info.
import { useActions } from "@/components/app-provider"
import { NodeAvatar, SignalBars, Stat } from "@/components/mesh-bits"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet"
import { Skeleton } from "@/components/ui/skeleton"
import { api } from "@/lib/api"
import { copyText } from "@/lib/clipboard"
import { shortKey } from "@/lib/meshcore-links"
import { clock, convTitle, duration, hopLabel, km, plural, resolvePath, SNR_LEVELS, snrQuality, type ResolvedHop } from "@/lib/mesh"
import { airtimeMs, analysePacket, bitsOf, MAX_PACKET, MAX_PATH, MAX_PAYLOAD, PAYLOAD_TYPES, ROUTE_TYPES, TXT_TYPES, type Part } from "@/lib/packet-anatomy"
import { useAppState, useNodes, useRadioSf } from "@/lib/queries"
import type { Message, MessageCopy, MessageInfo } from "@/lib/types"
import { cn } from "@/lib/utils"
import { useQuery } from "@tanstack/react-query"
import { CopyIcon, InfoIcon, MapIcon, RadioTowerIcon, UserIcon } from "lucide-react"
import { useMemo, useState, type ReactNode } from "react"
import { toast } from "sonner"

export function MessageDetails({ message, onClose }: { message: Message | null; onClose: () => void }) {
  return (
    <Sheet open={!!message} onOpenChange={(o) => { if (!o) onClose() }}>
      <SheetContent side="right" className="gap-0 p-0 pt-safe pb-safe data-[side=right]:w-full data-[side=right]:sm:max-w-xl [&>[data-slot=sheet-close]]:top-[calc(env(safe-area-inset-top)+0.75rem)]">
        <SheetHeader className="border-b pr-12">
          <SheetTitle>Message details</SheetTitle>
          <SheetDescription>Everything your radio knows about this message.</SheetDescription>
        </SheetHeader>
        {message ? <Details m={message} /> : null}
      </SheetContent>
    </Sheet>
  )
}

function Details({ m }: { m: Message }) {
  // copies keep arriving for a few seconds after a message (other routes, other repeaters): refresh
  const { data: d, error, isLoading } = useQuery({ queryKey: ["message-info", m.id], queryFn: () => api.messageInfo(m.id), refetchInterval: 4000 })
  const { data: state } = useAppState()
  const { showOnMap } = useActions()
  const [selected, setSelected] = useState(0)
  if (error) return <p className="p-4 text-sm text-destructive">{(error as Error).message}</p>
  if (isLoading || !d) return <div className="grid gap-3 p-4"><Skeleton className="h-16" /><Skeleton className="h-28" /><Skeleton className="h-40" /></div>
  const copy = d.copies[Math.min(selected, d.copies.length - 1)]
  const where = d.kind === "dm" ? (d.dir === "in" ? `from ${d.sender}` : `to ${convTitle(state, m.conv)}`) : convTitle(state, m.conv)

  return (
    <div className="min-h-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain">
      <div className="grid gap-6 p-4">
        <Quote d={d} where={where} />
        <Glance d={d} m={m} />
        <RouteSection d={d} copy={d.copies[0]} onMap={m.path || d.copies[0]?.path ? () => showOnMap({ kind: "route", message: { ...m, path: m.path || d.copies[0]?.path || null, hash_size: m.hash_size ?? d.copies[0]?.hash_size ?? 1 } }) : undefined} />
        <Copies d={d} selected={selected} onSelect={setSelected} />
        <Security d={d} />
        {copy ? <Anatomy d={d} copy={copy} index={d.copies.indexOf(copy)} /> : null}
        <Coverage d={d} />
      </div>
    </div>
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

function Quote({ d, where }: { d: MessageInfo; where: string }) {
  return (
    <figure className="grid gap-1">
      <figcaption className="flex items-center gap-2 text-xs text-muted-foreground">
        {d.dir === "in" ? <NodeAvatar name={d.sender || "?"} className="size-5" /> : null}
        <span className="truncate"><span className="font-medium text-foreground">{d.dir === "in" ? d.sender || "unknown sender" : "You"}</span> · {where}</span>
      </figcaption>
      <blockquote className={cn("rounded-2xl px-3 py-2 text-sm whitespace-pre-wrap wrap-anywhere", d.dir === "out" ? "bg-primary text-primary-foreground" : "bg-muted")}>{d.text}</blockquote>
    </figure>
  )
}

/** "12 s", "3 min 4 s" */
const span = (s: number) => (Math.abs(s) < 60 ? `${Math.round(Math.abs(s))} s` : duration(Math.abs(s)))

function timing(d: MessageInfo): { value: string; hint: string } {
  if (!d.sender_ts) return { value: "—", hint: "no timestamp from the sender" }
  const skew = d.ts - d.sender_ts
  if (d.dir === "out") return { value: clock(d.sender_ts), hint: "your radio's clock" }
  if (Math.abs(skew) <= 5) return { value: "in step", hint: "sender's clock agrees with yours" }
  if (skew < 0) return { value: `${span(skew)} ahead`, hint: "sender's clock is ahead of yours" }
  if (skew > 120) return { value: `${span(skew)} later`, hint: "it waited in a queue, or the sender's clock is behind" }
  return { value: `${span(skew)} later`, hint: "arrived after it was sent (travel and retries, or a slow clock)" }
}

/** Our DM: which try the receipt answered, how each try went out, and the round trip */
function receipt(m: Message) {
  if (!m.tries_flood?.length) return null
  const tries = m.tries_flood.map((f) => (f ? "flood" : "route")).join(" → ")
  if (!m.ack_try) return `tries: ${tries}`
  const rtt = m.rtt_ms ? `, receipt after ${m.rtt_ms < 1000 ? `${m.rtt_ms} ms` : `${(m.rtt_ms / 1000).toFixed(1)} s`}` : ""
  return `try ${m.ack_try} of ${m.tries_flood.length} (${tries})${rtt}`
}

function Glance({ d, m }: { d: MessageInfo; m: Message }) {
  const sf = useRadioSf()
  const first = d.copies[0]
  const snr = first?.snr ?? (d.has_rf ? d.snr : null), rssi = first?.rssi ?? (d.has_rf ? d.rssi : null)
  const routes = new Set(d.copies.map((c) => c.path)).size
  const spread = d.copies.length > 1 ? d.copies[d.copies.length - 1].after_ms : 0
  const t = timing(d)
  const hops = first?.hops ?? d.hops
  return (
    <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
      <Stat value={clock(d.ts)} label={d.dir === "in" ? "received" : "sent"} hint={new Date(d.ts * 1000).toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" })} />
      <Stat value={t.value} label={d.dir === "in" ? "sender's clock" : "timestamp"} hint={t.hint} />
      <Stat value={hops < 0 ? "?" : hops === 0 ? "direct" : hops} label={hops > 0 ? plural(hops, "hop", "hops").replace(/^\d+ /, "") : "route"}
        hint={hops > 0 ? `${(first?.hash_size ?? d.hash_size)}-byte repeater IDs` : hops === 0 ? "no repeater in between" : "route unknown"} />
      <Stat value={snr != null ? <span className="inline-flex items-center gap-1.5">{snr} dB<SignalBars snr={snr} /></span> : "—"}
        label={d.dir === "in" ? "signal (SNR)" : "echo signal"} hint={snr != null ? `${SNR_LEVELS[snrQuality(snr, sf)]}${rssi ? ` · ${rssi} dBm` : ""}` : "not measured"} />
      {/* copies from the packet log; for older messages only the echo count (ours) survives */}
      <Stat value={d.copies.length || (d.dir === "out" ? d.repeats : "—")} label={d.dir === "in" ? "copies heard" : "echoes heard"}
        hint={d.copies.length > 1 ? `${plural(routes, "route", "routes")} over ${spread < 1000 ? `${spread} ms` : `${(spread / 1000).toFixed(1)} s`}`
          : d.copies.length ? "one route" : d.dir === "out" && d.repeats ? "counted then; not in the log now" : "not in the log"} />
      {d.dir === "out"
        ? <Stat value={d.status} label="status" hint={receipt(m) ?? `${plural(d.attempts || 1, "transmission", "transmissions")}${d.repeats ? ` · repeated ×${d.repeats}` : ""}`} />
        : <Stat value={d.attempt != null ? `#${d.attempt + 1}` : "—"} label="sender's attempt" hint={d.attempt ? "an earlier try didn't get through" : d.attempt === 0 ? "sent once" : "not readable here"} />}
    </div>
  )
}

/** The route of the first copy: origin → repeaters → you, with names, ambiguity and distances. */
function RouteSection({ d, copy, onMap }: { d: MessageInfo; copy?: MessageCopy; onMap?: () => void }) {
  const { data: state } = useAppState()
  const nodes = useNodes()
  const path = copy?.path ?? d.path, size = copy?.hash_size ?? d.hash_size
  const { hops, resolved } = useMemo(() => resolvePath(path, size, state?.home, nodes), [path, size, state?.home, nodes])
  const me = state?.self.name ?? "You"
  const located = (r: ResolvedHop | null) => (r && r.node.lat != null && r.node.lon != null ? { lat: r.node.lat, lon: r.node.lon } : null)
  const steps: { icon: ReactNode; title: ReactNode; sub: string }[] = []
  steps.push({ icon: <UserIcon className="size-3.5" />, title: d.dir === "in" ? d.sender || "sender" : me, sub: d.dir === "in" ? "wrote it" : "sent it" })
  hops.forEach((h, i) => {
    const r = resolved[i], here = located(r), next = i + 1 < hops.length ? located(resolved[i + 1]) : state?.home ?? null
    const dist = here && next ? `${km(here, next).toFixed(1)} km to the next` : ""
    steps.push({
      icon: <RadioTowerIcon className="size-3.5" />,
      title: <><code className="mr-1.5 rounded bg-muted px-1 py-0.5 font-mono text-[11px]">{h}</code>{r ? r.node.name : <span className="text-muted-foreground">unknown repeater</span>}</>,
      sub: [i === 0 ? (d.dir === "in" ? "heard the sender" : "heard you") : "", r?.ambiguous ? `${r.ambiguous} repeaters share this ID: nearest shown` : "", dist].filter(Boolean).join(" · ") || "passed it on",
    })
  })
  steps.push({ icon: <UserIcon className="size-3.5" />, title: d.dir === "in" ? me : `${me} (echo)`, sub: copy?.snr != null ? `heard it at ${copy.snr} dB` : d.dir === "in" ? "received it" : "heard it come back" })

  return (
    <Section title="Route" aside={onMap ? <Button size="xs" variant="ghost" onClick={onMap}><MapIcon />On the map</Button> : undefined}>
      {hops.length || copy || d.hops === 0 ? (
        <ol className="grid">
          {steps.map((s, i) => (
            <li key={i} className="grid grid-cols-[1.5rem_1fr] gap-x-2">
              <div className="flex flex-col items-center">
                <span className="grid size-6 place-items-center rounded-full border bg-background text-muted-foreground">{s.icon}</span>
                {i < steps.length - 1 ? <span className="w-px flex-1 bg-border" /> : null}
              </div>
              <div className="min-w-0 pb-3">
                <p className="truncate text-sm">{s.title}</p>
                <p className="text-xs text-muted-foreground">{s.sub}</p>
              </div>
            </li>
          ))}
        </ol>
      ) : <p className="text-sm text-muted-foreground">No route recorded for this message.</p>}
      {d.copies.length > 1 ? <p className="text-xs text-muted-foreground">The first copy's route; the others are under Copies.</p> : null}
    </Section>
  )
}

function Copies({ d, selected, onSelect }: { d: MessageInfo; selected: number; onSelect: (i: number) => void }) {
  const { data: state } = useAppState()
  const nodes = useNodes()
  if (!d.copies.length) return null
  return (
    <Section title={d.dir === "in" ? "Copies heard" : "Echoes heard"} aside={d.dir === "in" ? "one per route it took" : "each repeater that passed yours on"}>
      <div className="overflow-hidden rounded-lg border">
        <table className="w-full text-xs">
          <thead className="bg-muted/50 text-muted-foreground">
            <tr className="text-left">
              <th className="px-2 py-1.5 font-medium">#</th><th className="px-2 py-1.5 font-medium">After</th>
              <th className="px-2 py-1.5 font-medium">Last repeater</th><th className="px-2 py-1.5 font-medium">Hops</th>
              <th className="px-2 py-1.5 font-medium">SNR</th><th className="hidden px-2 py-1.5 font-medium sm:table-cell">RSSI</th>
            </tr>
          </thead>
          <tbody>
            {d.copies.map((c, i) => {
              const { hops, resolved } = resolvePath(c.path, c.hash_size, state?.home, nodes)
              const last = hops.at(-1)
              return (
                <tr key={c.id} onClick={() => onSelect(i)} aria-selected={i === selected}
                  className={cn("cursor-pointer border-t hover:bg-muted/40", i === selected && "bg-muted/60")}>
                  <td className="px-2 py-1.5 tabular-nums text-muted-foreground">{i + 1}</td>
                  <td className="px-2 py-1.5 tabular-nums">{i === 0 ? "first" : c.after_ms < 1000 ? `+${c.after_ms} ms` : `+${(c.after_ms / 1000).toFixed(1)} s`}</td>
                  <td className="max-w-0 truncate px-2 py-1.5">{last ? hopLabel(resolved.at(-1) ?? null, last) : "direct"}</td>
                  <td className="px-2 py-1.5 tabular-nums">{c.hops}</td>
                  <td className="px-2 py-1.5 tabular-nums"><span className="inline-flex items-center gap-1">{c.snr != null ? <><SignalBars snr={c.snr} />{c.snr}</> : "—"}</span></td>
                  <td className="hidden px-2 py-1.5 tabular-nums sm:table-cell">{c.rssi ?? "—"}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      <p className="text-xs text-muted-foreground">Tap a copy to see its bytes below.</p>
    </Section>
  )
}

function Row({ k, v }: { k: string; v: ReactNode }) {
  return (
    <div className="grid grid-cols-[8rem_1fr] gap-2 py-1.5 text-sm sm:grid-cols-[10rem_1fr]">
      <dt className="text-muted-foreground">{k}</dt>
      <dd className="min-w-0 wrap-anywhere">{v}</dd>
    </div>
  )
}

function Security({ d }: { d: MessageInfo }) {
  const { data: state } = useAppState()
  const c = d.channel, first = d.copies[0]
  const KEY = { hashtag: "from the name (SHA-256 of it): anyone who knows the name can read it", public: "the well-known Public key: anyone can read it", private: "a random secret, shared by invitation" }
  return (
    <Section title="Encryption and packet">
      <dl className="divide-y rounded-lg border px-3">
        {c ? <>
          <Row k="Channel" v={<>{c.name} <Badge variant="secondary" className="ml-1">{d.kind === "listened" ? "listening" : c.key}</Badge></>} />
          <Row k="Channel ID" v={<><code className="font-mono">{c.hash}</code> <span className="text-muted-foreground">(1 of 256: other channels can share it)</span></>} />
          <Row k="Key" v={KEY[c.key]} />
        </> : <>
          <Row k="Encryption" v="end to end: a secret only you and they can work out from your two keys" />
          {d.peer ? <Row k={d.dir === "in" ? "Sender's key" : "Recipient's key"} v={<><code className="font-mono text-xs">{shortKey(d.peer)}</code>{state?.contacts[d.peer] ? null : <span className="text-muted-foreground"> · not in your contacts</span>}</>} /> : null}
        </>}
        <Row k="Message type" v={d.txt_type != null ? TXT_TYPES[d.txt_type] ?? `type ${d.txt_type}` : d.kind === "dm" ? "direct message" : "—"} />
        {first ? <>
          <Row k="Packet" v={`${first.type} · ${first.route.toLowerCase().replace("_", " ")} route · ${first.len} bytes`} />
          <Row k="Fingerprint" v={<><code className="font-mono">{d.fp}</code> <span className="text-muted-foreground">SHA-256 of the payload: the same on every copy</span></>} />
        </> : null}
      </dl>
    </Section>
  )
}

const PART_TONE: Record<Part, string> = {
  header: "bg-slate-500", transport: "bg-amber-500", path: "bg-sky-500", address: "bg-violet-500", mac: "bg-rose-500", cipher: "bg-emerald-500", payload: "bg-emerald-500",
}
const PART_NAME: Record<Part, string> = { header: "header", transport: "transport codes", path: "path", address: "addresses", mac: "MAC", cipher: "ciphertext", payload: "payload" }

/** One byte as bit groups, each named underneath: 01 | 000001 */
function Bits({ byte, groups }: { byte: number; groups: { bits: number; name: string }[] }) {
  const parts = bitsOf(byte, groups.map((g) => g.bits))
  return (
    <div className="mt-1 flex gap-1">
      {groups.map((g, i) => (
        <div key={i} className="grid justify-items-center rounded-md border bg-muted/40 px-1.5 py-0.5">
          <code className="font-mono text-xs tracking-widest">{parts[i]}</code>
          <span className="text-[10px] text-muted-foreground">{g.name}</span>
        </div>
      ))}
    </div>
  )
}

function Anatomy({ d, copy, index }: { d: MessageInfo; copy: MessageCopy; index: number }) {
  const a = useMemo(() => analysePacket(copy.raw), [copy.raw])
  const { data: state } = useAppState()
  const nodes = useNodes()
  if (!a) return null
  const radio = state?.self.radio
  const air = radio ? airtimeMs(a.total, radio.sf, radio.bw, radio.cr) : null
  const pathCost = radio && a.routing > 1 ? air! - airtimeMs(a.total - (a.routing - 1), radio.sf, radio.bw, radio.cr) : 0
  const resolved = resolvePath(a.hops.join(""), a.pathLen?.size, state?.home, nodes).resolved
  // inside the ciphertext: timestamp (4), flags (1), text, zero padding to a 16-byte block
  const plain = d.kind === "dm" ? d.text : `${d.dir === "out" ? state?.self.name ?? d.sender : d.sender}: ${d.text}`
  const textBytes = new TextEncoder().encode(plain).length
  const pad = a.cipher - 5 - textBytes
  const copyRaw = async () => { const ok = await copyText(copy.raw); toast[ok ? "success" : "error"](ok ? "Raw bytes copied" : "Couldn't copy") }

  // the size bar: one segment per field, as wide as its bytes
  const segs = a.fields.map((f) => ({ part: f.part, n: f.hex.length / 2, label: f.label }))
  const parts = [...new Set(segs.map((s) => s.part))]

  return (
    <Section title={`Packet, byte by byte (copy ${index + 1})`} aside={<Button size="xs" variant="ghost" onClick={() => void copyRaw()}><CopyIcon />Copy hex</Button>}>
      <div className="grid gap-2 rounded-lg border p-3">
        <p className="flex flex-wrap items-baseline justify-between gap-x-3 text-sm">
          <span><span className="text-lg font-semibold tabular-nums">{a.total}</span> <span className="text-muted-foreground">of {MAX_PACKET} bytes</span></span>
          {air != null ? <span className="text-muted-foreground">≈ <span className="font-medium text-foreground tabular-nums">{Math.round(air)} ms</span> on air at SF{radio!.sf} · {radio!.bw} kHz · CR 4/{radio!.cr}</span> : null}
        </p>
        <div className="flex h-3 w-full gap-0.5" role="img" aria-label={segs.map((s) => `${s.label} ${s.n} bytes`).join(", ")}>
          {segs.map((sg, i) => <span key={i} title={`${sg.label}: ${sg.n} B`} className={cn("h-full min-w-1 rounded-sm first:rounded-l-md last:rounded-r-md", PART_TONE[sg.part])} style={{ flexGrow: sg.n }} />)}
          <span className="h-full rounded-r-md bg-muted" style={{ flexGrow: MAX_PACKET - a.total }} title={`unused: ${MAX_PACKET - a.total} B`} />
        </div>
        <ul className="flex flex-wrap gap-x-3 gap-y-1 text-xs text-muted-foreground">
          {parts.map((p) => <li key={p} className="inline-flex items-center gap-1"><span className={cn("size-2 rounded-full", PART_TONE[p])} />{PART_NAME[p]} {segs.filter((s) => s.part === p).reduce((t, s) => t + s.n, 0)} B</li>)}
        </ul>
        <dl className="grid grid-cols-2 gap-x-3 gap-y-1 text-xs sm:grid-cols-4">
          <div><dt className="text-muted-foreground">routing</dt><dd className="tabular-nums">{a.routing} B</dd></div>
          <div><dt className="text-muted-foreground">payload</dt><dd className="tabular-nums">{a.payload} of {MAX_PAYLOAD} B</dd></div>
          {a.pathLen ? <div><dt className="text-muted-foreground">route can grow to</dt><dd className="tabular-nums">{a.pathLen.maxHops} hops</dd></div> : null}
          {pathCost > 0.5 ? <div><dt className="text-muted-foreground">path airtime</dt><dd className="tabular-nums">≈ {Math.round(pathCost)} ms</dd></div> : null}
        </dl>
      </div>

      <ul className="divide-y rounded-lg border">
        {a.fields.map((f, i) => (
          <li key={i} className="grid grid-cols-[0.5rem_1fr] gap-x-2.5 px-3 py-2">
            <span className={cn("mt-1.5 size-2 rounded-full", PART_TONE[f.part])} aria-hidden />
            <div className="min-w-0">
              <p className="flex items-baseline justify-between gap-2 text-sm"><span>{f.label}</span><span className="text-xs text-muted-foreground tabular-nums">{f.hex.length / 2} B</span></p>
              {f.label === "Path" ? (
                <ol className="mt-1 flex flex-wrap gap-1">
                  {a.hops.map((h, k) => (
                    <li key={k} className="inline-flex max-w-full items-center gap-1 rounded-md border bg-muted/40 px-1.5 py-0.5 text-xs">
                      <code className="font-mono">{h}</code>
                      <span className="truncate text-muted-foreground">{resolved[k] ? `${resolved[k]!.node.name}${resolved[k]!.ambiguous ? ` (+${resolved[k]!.ambiguous - 1})` : ""}` : "unknown"}</span>
                    </li>
                  ))}
                </ol>
              ) : <p className="font-mono text-xs wrap-anywhere">{f.hex}</p>}
              {f.label === "Header" ? <Bits byte={a.header.byte} groups={[{ bits: 2, name: `v${a.header.ver + 1}` }, { bits: 4, name: PAYLOAD_TYPES[a.header.type] }, { bits: 2, name: ROUTE_TYPES[a.header.route].replace("transport ", "t. ") }]} /> : null}
              {f.label === "Path length" && a.pathLen ? (
                <Bits byte={a.pathLen.byte} groups={[{ bits: 2, name: `${a.pathLen.size}-byte IDs` }, { bits: 6, name: `${a.pathLen.hops} ${a.pathLen.hops === 1 ? "hop" : "hops"}` }]} />
              ) : null}
              <p className="mt-0.5 text-xs text-muted-foreground">
                {f.note}
                {f.label === "Path length" && a.pathLen ? `. With ${a.pathLen.size}-byte IDs a route can hold ${a.pathLen.maxHops} hops (${MAX_PATH} bytes of path)${a.pathLen.size === 1 ? "; only 256 IDs, so repeaters often share one" : ""}.` : ""}
              </p>
              {f.part === "cipher" && pad >= 0 && pad < 16 ? (
                <div className="mt-1.5 grid gap-1">
                  <p className="text-[11px] text-muted-foreground">inside, once decrypted:</p>
                  <div className="flex h-2 w-full gap-0.5">
                    {[[4, "bg-slate-400"], [1, "bg-amber-400"], [textBytes, "bg-emerald-400"], [pad, "bg-muted"]].map(([n, c], k) => (
                      <span key={k} className={cn("h-full min-w-0.5 rounded-sm", c as string)} style={{ flexGrow: n as number }} />
                    ))}
                  </div>
                  <p className="text-xs text-muted-foreground">
                    timestamp 4 B{d.sender_ts ? ` (${clock(d.sender_ts)})` : ""} · flags 1 B{d.txt_type != null ? ` (${TXT_TYPES[d.txt_type] ?? `type ${d.txt_type}`}, attempt ${(d.attempt ?? 0) + 1})` : ""} · text {textBytes} B · padding {pad} B
                  </p>
                </div>
              ) : null}
            </div>
          </li>
        ))}
      </ul>
    </Section>
  )
}

function Coverage({ d }: { d: MessageInfo }) {
  const note = !d.fp
    ? "Your radio couldn't tie this message to a packet: it came in before the radio last restarted, or before message details existed."
    : !d.copies.length
      ? "Its packets have left the log: the radio keeps the latest 3000 packets, from its last restart."
      : null
  return (
    <p className="flex items-start gap-1.5 text-xs text-muted-foreground">
      <InfoIcon className="mt-0.5 size-3 shrink-0" aria-hidden />
      {note ?? `Copies come from the radio's packet log${d.log_since ? `, which goes back to ${new Date(d.log_since * 1000).toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit" })}` : ""}.`}
    </p>
  )
}
