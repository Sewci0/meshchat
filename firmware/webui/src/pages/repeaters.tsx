import { Hint } from "@/components/hint"
import { Page } from "@/components/page"
import { useActions } from "@/components/app-provider"
import { NodeAvatar, SignalBars, Sparkline, Stat } from "@/components/mesh-bits"
import { QuietRepeaterAlert } from "@/components/quiet-repeater"
import { SignalChart } from "@/components/signal-chart"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty"
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Item, ItemActions, ItemContent, ItemDescription, ItemGroup, ItemMedia, ItemTitle } from "@/components/ui/item"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Skeleton } from "@/components/ui/skeleton"
import { Spinner } from "@/components/ui/spinner"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { useIsMobile } from "@/hooks/use-mobile"
import { api } from "@/lib/api"
import { useLocal } from "@/lib/local"
import { ago, clock, contactByName, daysLabel, duration, fold, plural, snrFloor, SNR_LEVELS, snrQuality } from "@/lib/mesh"
import { RepeaterAdmin } from "@/components/repeater-admin"
import { keys, useAppState, usePeople, useRadioSf, useRepeater, useRepeaterDays, useRepeaters, waitForLive } from "@/lib/queries"
import type { RepeaterDetail, RepeaterList as RepeaterListData, RepeaterLive, RepeaterQuiet, RepeaterSummary, RepeaterUser } from "@/lib/types"
import { cn } from "@/lib/utils"
import { convPath, dmConv } from "@/lib/routes"
import { useQueryClient } from "@tanstack/react-query"
import {
  ArrowLeftIcon, ArrowRightLeftIcon, KeyRoundIcon, MapIcon, MapPinIcon, MessageCircleIcon, RadioTowerIcon, SearchIcon, UsersIcon,
} from "lucide-react"
import { useEffect, useMemo, useState } from "react"
import { Link, useNavigate, useParams } from "react-router"
import { toast } from "sonner"

export function RepeatersPage() {
  const { key } = useParams()
  const navigate = useNavigate()
  const isMobile = useIsMobile()
  const [days, setDays] = useRepeaterDays()
  const { data: list, isLoading } = useRepeaters(days)

  // desktop: always show something on the right
  useEffect(() => {
    if (!key && !isMobile && list?.repeaters.length) navigate(`/repeaters/${list.your_repeater ?? list.repeaters[0].key}`, { replace: true })
  }, [key, isMobile, list, navigate])

  return (
    <Page title="Repeaters"
        description={list ? `${plural(list.repeaters.length, "repeater", "repeaters")} carried traffic you heard, ${daysLabel(days)}${coverageNote(list, days)}` : "Working out who uses which repeater…"} actions={<><Select value={String(days)} onValueChange={(v) => setDays(Number(v))}>
          <SelectTrigger size="sm" className="w-32" aria-label="Time range"><SelectValue /></SelectTrigger>
          <SelectContent align="end">
            <SelectItem value="1">Last 24 h</SelectItem>
            <SelectItem value="7">Last 7 days</SelectItem>
            <SelectItem value="30">Last 30 days</SelectItem>
          </SelectContent>
        </Select></>}>
      <div className="grid min-h-0 flex-1 md:grid-cols-[minmax(17rem,22rem)_1fr]">
        <aside className={cn("min-h-0 border-r", isMobile && key && "hidden")}>
          <RepeaterList list={list?.repeaters} mine={list?.your_repeater ?? null} mineQuiet={list?.your_repeater_quiet ?? null} selected={key} loading={isLoading} />
        </aside>
        <main className={cn("min-h-0 overflow-y-auto", isMobile && !key && "hidden")}>
          {key ? <RepeaterView repeaterKey={key} days={days} mine={list?.your_repeater === key ? list : undefined} /> : (
            <Empty className="h-full"><EmptyHeader><EmptyMedia variant="icon"><RadioTowerIcon /></EmptyMedia>
              <EmptyTitle>Pick a repeater</EmptyTitle></EmptyHeader></Empty>
          )}
        </main>
      </div>
    </Page>
  )
}

/** On the radio, the analysis only sees the packets the radio still holds (since its last restart). */
function coverageNote(list: RepeaterListData, days: number) {
  const c = list.coverage
  if (!c) return ""
  if (!c.since) return " · the radio hasn't logged any packets yet"
  const span = Date.now() / 1000 - c.since
  if (span < 120) return " · the radio has only just started logging packets"
  return span < days * 86400 - 3600 ? ` · the radio's log covers the last ${duration(span)}` : ""
}

// ---------------------------------------------------------------- list
type YoursWhy = Pick<RepeaterListData, "your_repeater_basis" | "your_repeater_passed">

/** The "yours" badge, with why this repeater was picked. */
function YoursBadge({ why, children }: { why?: YoursWhy; children: string }) {
  const n = why?.your_repeater_passed ?? 0
  const text = why?.your_repeater_basis === "passes_yours"
    ? `It was the first repeater to pass on ${n === 1 ? "one of your messages" : `${n} of your messages`} in this period, so it hears you.`
    : "You hear it best: most packets reach you straight from it. None of your messages was passed on in this period, so which repeater hears you isn't known yet."
  return (
    <Hint content={text}>
      <button type="button" className="shrink-0 rounded-md focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none"><Badge>{children}</Badge></button>
    </Hint>
  )
}

function RepeaterList({ list, mine, mineQuiet, selected, loading }: {
  list?: RepeaterSummary[]; mine: string | null; mineQuiet: RepeaterQuiet | null; selected?: string; loading: boolean
}) {
  const [q, setQ] = useState("")
  const filtered = useMemo(() => (list ?? []).filter((r) => !q || fold(r.name).includes(fold(q))), [list, q])
  const direct = filtered.filter((r) => r.direct), far = filtered.filter((r) => !r.direct)
  const section = (title: string, rows: RepeaterSummary[]) => rows.length ? (
    <section>
      <h2 className="px-3 pt-3 pb-1 text-xs font-medium text-muted-foreground">{title} · {rows.length}</h2>
      <ul className="px-1.5">
        {rows.map((r) => (
          <li key={r.key}>
            <Link to={`/repeaters/${r.key}`} aria-current={r.key === selected ? "page" : undefined}
              className={cn("grid gap-0.5 rounded-lg px-2.5 py-2 outline-none hover:bg-muted focus-visible:ring-2 focus-visible:ring-ring",
                r.key === selected && "bg-muted")}>
              <span className="flex items-center gap-2">
                <span className="truncate text-sm font-medium">{r.name}</span>
                {/* plain here: the row is a link; the repeater's own page explains why it's yours */}
                {r.key === mine ? <Badge className="shrink-0">yours</Badge> : null}
                {r.key === mine && mineQuiet
                  ? <Badge variant="outline" className="shrink-0 border-amber-500/50 text-amber-700 dark:text-amber-400">silent since {clock(mineQuiet.since)}</Badge>
                  : null}
              </span>
              <span className="flex items-end justify-between gap-2 text-xs text-muted-foreground">
                <span className="truncate">{r.relayed} relayed · {plural(r.people, "person", "people")}{r.km != null ? ` · ${r.km} km` : ""}</span>
                {r.direct && r.snr_median != null
                  ? <span className="inline-flex shrink-0 items-center gap-1 tabular-nums" title="median signal at your radio"><SignalBars snr={r.snr_median} />{r.snr_median} dB</span>
                  : <Sparkline values={r.hourly} />}
              </span>
            </Link>
          </li>
        ))}
      </ul>
    </section>
  ) : null

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="border-b p-2">
        <div className="relative">
          <SearchIcon className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Filter repeaters" aria-label="Filter repeaters" className="pl-8" />
        </div>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto pb-3">
        {loading ? <div className="grid gap-2 p-3">{[...Array(6)].map((_, i) => <Skeleton key={i} className="h-11" />)}</div> : null}
        {section("Heard directly by your radio", direct)}
        {section("Further along the mesh", far)}
        {!loading && !filtered.length ? (
          <p className="p-4 text-sm text-muted-foreground">{q ? "No repeater matches." : "No repeater traffic recorded yet. Leave MeshChat running and repeaters appear as packets arrive."}</p>
        ) : null}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------- detail
function RepeaterView({ repeaterKey, days, mine }: { repeaterKey: string; days: number; mine?: YoursWhy }) {
  const { data: d, isLoading, error } = useRepeater(repeaterKey, days)
  const { showOnMap } = useActions()
  const [tab, setTab] = useLocal("repTab", "overview")

  if (error) return <p className="p-6 text-sm text-destructive">{(error as Error).message}</p>
  if (isLoading || !d) return <div className="grid gap-3 p-6"><Skeleton className="h-8 w-64" /><Skeleton className="h-24" /><Skeleton className="h-40" /></div>

  const meta = [d.km != null ? `${d.km} km from home` : "no position published", d.radio, `key ${d.key.slice(0, 8)}…`].filter(Boolean).join(" · ")
  return (
    <div className="@container mx-auto grid max-w-4xl gap-5 p-4 sm:p-6">
      <div className="flex flex-wrap items-start gap-3">
        <Button asChild variant="ghost" size="icon-sm" className="md:hidden"><Link to="/repeaters" aria-label="Back to list"><ArrowLeftIcon /></Link></Button>
        <div className="min-w-0 flex-1">
          <div className="mb-1 flex flex-wrap gap-1.5">
            {mine ? <YoursBadge why={mine}>your repeater</YoursBadge> : null}
            {d.direct ? <Badge variant="secondary">heard directly</Badge> : null}
            {d.type === "room" ? <Badge variant="secondary">room server</Badge> : null}
            {d.uncertain_share > 0.2 ? (
              <Hint content="Its short ID is shared with another repeater, so some of these packets may belong to that one.">
                <button type="button" className="rounded-md focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">
                  <Badge variant="outline" className="border-amber-500/50 text-amber-700 dark:text-amber-400">{Math.round(d.uncertain_share * 100)}% uncertain</Badge>
                </button>
              </Hint>
            ) : null}
          </div>
          <h2 className="truncate text-xl font-semibold">{d.name}</h2>
          <p className="text-sm text-muted-foreground">{meta}</p>
        </div>
        {d.lat != null ? <Button variant="outline" size="sm" onClick={() => showOnMap({ kind: "repeater", detail: d })}><MapIcon />Show links on map</Button> : null}
      </div>
      {d.quiet ? <QuietRepeaterAlert quiet={d.quiet} snr={d.snr_median} yours={!!mine} /> : null}

      <Tabs value={tab} onValueChange={setTab}>
        <TabsList>
          <TabsTrigger value="overview">Overview</TabsTrigger>
          <TabsTrigger value="people">People <span className="text-muted-foreground tabular-nums">{d.people_list.length + d.nodes_list.length}</span></TabsTrigger>
          <TabsTrigger value="links">Links <span className="text-muted-foreground tabular-nums">{d.links_list.length}</span></TabsTrigger>
          <TabsTrigger value="live">Live</TabsTrigger>
          <TabsTrigger value="admin">Admin</TabsTrigger>
        </TabsList>
        <TabsContent value="overview" className="grid gap-5 pt-2"><Overview d={d} days={days} /></TabsContent>
        <TabsContent value="people" className="pt-2"><People d={d} /></TabsContent>
        <TabsContent value="links" className="pt-2"><Links d={d} /></TabsContent>
        <TabsContent value="live" className="pt-2"><Live d={d} /></TabsContent>
        <TabsContent value="admin" className="pt-2"><RepeaterAdmin d={d} /></TabsContent>
      </Tabs>
    </div>
  )
}

/** Your link with a repeater: how strongly it reaches you (packets heard straight from it), and
 *  whether it hears you (it was the first to pass on one of your messages). */
function SignalSection({ d, days }: { d: RepeaterDetail; days: number }) {
  const sf = useRadioSf()
  const snrs = d.signal.map((p) => p.snr).sort((a, b) => a - b)
  const latest = d.signal.at(-1)
  const margin = latest ? latest.snr - snrFloor(sf) : null
  return (
    <section aria-labelledby="sig" className="grid gap-2">
      <h3 id="sig" className="text-sm font-medium">
        Signal at your radio <span className="font-normal text-muted-foreground">· {plural(d.signal.length, "packet", "packets")} heard straight from it, {daysLabel(days)}</span>
      </h3>
      {d.signal.length ? <SignalChart points={d.signal} sf={sf} /> : null}
      <p className="text-sm text-muted-foreground">
        {latest ? <>Latest <b className="font-medium text-foreground">{latest.snr} dB</b>{margin != null ? ` (${margin >= 0 ? `${margin} dB above` : `${-margin} dB below`} the decode limit: ${SNR_LEVELS[snrQuality(latest.snr, sf)]})` : ""}, median {snrs[Math.floor(snrs.length / 2)]} dB, weakest {snrs[0]} dB. </> : null}
        {d.heard_you.count
          ? <>It hears you: it was the first repeater to pass on {d.heard_you.count === 1 ? "one of your messages" : `${d.heard_you.count} of your messages`}, last {ago(d.heard_you.last_ts)}.</>
          : d.direct ? "No sign yet that it hears you: none of your channel messages came back through it first." : null}
      </p>
    </section>
  )
}

function Overview({ d, days }: { d: RepeaterDetail; days: number }) {
  return (
    <>
      <div className="grid grid-cols-2 gap-3 @2xl:grid-cols-4">
        <Stat value={d.relayed} label="packets relayed" hint={`that reached you, ${daysLabel(days)}`} />
        <Stat value={d.first_hop} label="entered the mesh here" hint="it was the sender's first repeater" />
        <Stat value={d.last_hop} label="heard directly by you" hint={d.snr_median != null ? <span className="inline-flex items-center gap-1"><SignalBars snr={d.snr_median} />median SNR {d.snr_median} dB</span> : "never direct"} />
        <Stat value={d.last_ts ? ago(d.last_ts) : "—"} label="last activity" />
      </div>
      {d.signal.length || d.heard_you.count ? <SignalSection d={d} days={days} /> : null}
      <section aria-labelledby="act">
        <h3 id="act" className="mb-2 text-sm font-medium">Activity <span className="font-normal text-muted-foreground">· packets per hour, last 24 h</span></h3>
        <Sparkline values={d.hourly} tall />
        <div className="mt-1 flex justify-between text-[11px] text-muted-foreground"><span>24 h ago</span><span>12 h ago</span><span>now</span></div>
      </section>
      <section aria-labelledby="recent">
        <h3 id="recent" className="mb-2 text-sm font-medium">Recent packets through it</h3>
        {d.recent.length ? (
          <ItemGroup className="rounded-xl border">
            {d.recent.slice(0, 10).map((p, i) => (
              <Item key={i} size="sm" className={cn(i > 0 && "border-t")}>
                <ItemContent>
                  <ItemTitle>{p.type}{p.what ? <span className="font-normal text-muted-foreground"> · {p.what}</span> : null}</ItemTitle>
                  <ItemDescription>hop {p.position} of {p.hops}{p.snr != null ? ` · reached you directly at ${p.snr} dB` : ""}</ItemDescription>
                </ItemContent>
                <ItemActions className="text-xs text-muted-foreground">{ago(p.ts)}</ItemActions>
              </Item>
            ))}
          </ItemGroup>
        ) : <p className="text-sm text-muted-foreground">None in this period.</p>}
      </section>
    </>
  )
}

function People({ d }: { d: RepeaterDetail }) {
  const { data: state } = useAppState()
  const { data: people } = usePeople()
  const { showOnMap } = useActions()
  const navigate = useNavigate()
  const me = state?.self.pubkey
  const row = (u: RepeaterUser, i: number) => {
    const isMe = !!u.key && u.key === me
    const contact = u.key ? state?.contacts[u.key] : u.name ? contactByName(state, u.name) : null
    return (
      <Item key={`${u.key ?? u.name}`} size="sm" className={cn(i > 0 && "border-t")}>
        <ItemMedia><NodeAvatar name={u.name ?? "?"} /></ItemMedia>
        <ItemContent>
          <ItemTitle>{u.name ?? u.key?.slice(0, 8)}{isMe ? <Badge variant="secondary">you</Badge> : null}{u.type !== "companion" ? <Badge variant="outline">{u.type}</Badge> : null}</ItemTitle>
          <ItemDescription className="line-clamp-none">last {ago(u.last_ts)} · {plural(u.count, "packet", "packets")} · seen via {u.via.join(" & ")}{u.uncertain ? " · uncertain" : ""}</ItemDescription>
        </ItemContent>
        {!isMe ? (
          <ItemActions>
            {contact?.type === "companion" ? <Button size="sm" variant="ghost" onClick={() => navigate(convPath(dmConv(contact.pubkey)))}><MessageCircleIcon /><span className="sr-only sm:not-sr-only">Message</span></Button> : null}
            {u.name && people?.has(u.name) ? <Button size="sm" variant="ghost" onClick={() => showOnMap({ kind: "person", name: u.name! })}><MapPinIcon /><span className="sr-only sm:not-sr-only">Map</span></Button> : null}
          </ItemActions>
        ) : null}
      </Item>
    )
  }
  const all = [...d.people_list, ...d.nodes_list]
  return (
    <div className="grid gap-3">
      <p className="text-sm text-muted-foreground">People whose adverts or channel messages entered the mesh through this repeater, so it was the first repeater that heard them.</p>
      {all.length ? <ItemGroup className="rounded-xl border">{all.map(row)}</ItemGroup> : (
        <Empty className="border"><EmptyHeader><EmptyMedia variant="icon"><UsersIcon /></EmptyMedia>
          <EmptyTitle>Nobody entered the mesh here</EmptyTitle>
          <EmptyDescription>In this period, all the traffic it carried came from further away. Try a longer time range.</EmptyDescription></EmptyHeader></Empty>
      )}
    </div>
  )
}

function Links({ d }: { d: RepeaterDetail }) {
  return (
    <div className="grid gap-3">
      <p className="text-sm text-muted-foreground">Repeaters next to it in packet routes, so the two hear each other. → is packets it passed to them, ← is packets it got from them.</p>
      {d.links_list.length ? (
        <ItemGroup className="rounded-xl border">
          {d.links_list.map((l, i) => (
            <Item key={l.key} size="sm" asChild className={cn(i > 0 && "border-t")}>
              <Link to={`/repeaters/${l.key}`}>
                <ItemMedia variant="icon"><RadioTowerIcon /></ItemMedia>
                <ItemContent><ItemTitle>{l.name}</ItemTitle><ItemDescription>{l.km != null ? `${l.km} km apart` : "position unknown"}</ItemDescription></ItemContent>
                <ItemActions className="gap-3 text-xs tabular-nums text-muted-foreground">
                  <span title={`${d.name} passed ${l.to} packets to ${l.name}`}>→ {l.to}</span>
                  <span title={`${d.name} received ${l.from} packets from ${l.name}`}>← {l.from}</span>
                </ItemActions>
              </Link>
            </Item>
          ))}
        </ItemGroup>
      ) : <Empty className="border"><EmptyHeader><EmptyMedia variant="icon"><ArrowRightLeftIcon /></EmptyMedia><EmptyTitle>No links seen yet</EmptyTitle></EmptyHeader></Empty>}
    </div>
  )
}

function Live({ d }: { d: RepeaterDetail }) {
  const qc = useQueryClient()
  const { data: state } = useAppState()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [password, setPassword] = useState("")
  const [showPw, setShowPw] = useState(false)
  const live = d.live, st = live?.status
  const running = busy || !!live?.running

  const ask = async () => {
    setBusy(true); setError(null)
    try {   // the radio runs it in the background; its answer arrives over the WebSocket or by polling
      const before = qc.getQueryData<Record<string, RepeaterLive>>(keys.repeaterLive)?.[d.key]
      await api.startRepeaterQuery(d.key, password || null)
      const res = await waitForLive(d.key, before, (all) => qc.setQueryData(keys.repeaterLive, all))
      if (res.ok) toast.success(`${d.name} answered`)
      else setError(res.error ?? "No answer")
    } catch (e) { setError((e as Error).message) } finally { setBusy(false) }
  }

  const disabled = !d.can_query || running || !state?.connected
  return (
    <div className="grid gap-4">
      <div className="flex flex-col gap-3 rounded-xl border p-4 @xl:flex-row @xl:flex-wrap @xl:items-center">
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium">Ask the repeater for its status and neighbours</p>
          <p className="text-sm text-muted-foreground">
            Logs in as a guest (or with a password) and asks for its status and the repeaters it hears directly.
            That's three short transmissions, and replies take 5–30 s. If the saved route to it doesn't answer, it asks once more by flood.
            {live && !live.running ? ` Last answer ${ago(live.ts)}${live.login ? `, as ${live.login.admin ? "admin" : "guest"}` : ""}.` : ""}
          </p>
          {!d.can_query ? <p className="mt-1 text-sm text-amber-700 dark:text-amber-400">Not available yet: your radio needs this repeater's advert before it can address it.</p> : null}
        </div>
        <div className="flex items-center gap-2">
          <Button variant="ghost" size="sm" onClick={() => setShowPw((s) => !s)} aria-expanded={showPw}><KeyRoundIcon />Password</Button>
          <Button onClick={() => void ask()} disabled={disabled}>{running ? <><Spinner />Waiting…</> : live?.ok ? "Ask again" : "Ask now"}</Button>
        </div>
        {showPw ? (
          <Field className="w-full max-w-xs">
            <FieldLabel htmlFor="rpw">Password</FieldLabel>
            <Input id="rpw" type="password" autoComplete="off" maxLength={15} value={password} onChange={(e) => setPassword(e.target.value)} />
            <FieldDescription>Only if you run this repeater. It's sent to the repeater and not stored.</FieldDescription>
          </Field>
        ) : null}
      </div>

      {error ? <Alert variant="destructive"><AlertTitle>No answer</AlertTitle><AlertDescription>{error}</AlertDescription></Alert> : null}

      {st ? (
        <div className="grid grid-cols-2 gap-3 @2xl:grid-cols-4">
          <Stat value={duration(st.uptime)} label="uptime" />
          <Stat value={st.bat ? `${(st.bat / 1000).toFixed(2)} V` : "mains"} label="power" />
          <Stat value={`${st.noise_floor} dBm`} label="noise floor" hint="lower is better" />
          <Stat value={`${st.last_rssi} dBm`} label="last signal it heard" hint={`SNR ${st.last_snr} dB`} />
          <Stat value={`${st.nb_recv} / ${st.nb_sent}`} label="packets received / sent" />
          <Stat value={st.uptime ? `${((st.airtime / st.uptime) * 100).toFixed(1)}%` : "—"} label="time transmitting" hint="EU limit in this band: 10%" />
          <Stat value={`${st.sent_flood} / ${st.sent_direct}`} label="sent flood / direct" />
          <Stat value={st.flood_dups + st.direct_dups} label="duplicates dropped" />
        </div>
      ) : live?.ok && !live.running && !live.room ? (
        <p className="text-sm text-muted-foreground">It didn't send its status (uptime, power, traffic) back in time: the request or its answer was lost on the way. Ask again.</p>
      ) : null}

      {live?.neighbours ? (
        <section>
          <h3 className="mb-2 text-sm font-medium">Repeaters it hears directly · {live.neighbours_total ?? live.neighbours.length}</h3>
          <ItemGroup className="rounded-xl border">
            {[...live.neighbours].sort((a, b) => b.snr - a.snr).map((n, i) => {
              const body = (
                <>
                  <ItemMedia variant="icon"><RadioTowerIcon /></ItemMedia>
                  <ItemContent>
                    <ItemTitle>{n.name ?? `unknown ${n.pubkey}`}</ItemTitle>
                    <ItemDescription>{n.km != null ? `${n.km} km away · ` : ""}heard {ago(Date.now() / 1000 - n.secs_ago)}</ItemDescription>
                  </ItemContent>
                  <ItemActions className="gap-1.5 text-xs tabular-nums"><SignalBars snr={n.snr} />{n.snr} dB</ItemActions>
                </>
              )
              return n.key
                ? <Item key={n.pubkey} size="sm" asChild className={cn(i > 0 && "border-t")}><Link to={`/repeaters/${n.key}`}>{body}</Link></Item>
                : <Item key={n.pubkey} size="sm" className={cn(i > 0 && "border-t")}>{body}</Item>
            })}
          </ItemGroup>
        </section>
      ) : live?.ok ? <p className="text-sm text-muted-foreground">It didn't share its neighbour list. Some repeaters only show it to admins.</p> : null}
    </div>
  )
}
