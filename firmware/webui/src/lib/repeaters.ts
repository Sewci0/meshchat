// What the repeaters around us do, reconstructed in the browser from the packets the radio heard
// (the radio keeps them but has no room to analyse them): per repeater, the traffic it relayed and
// when, who enters the mesh through it, which repeaters it exchanges traffic with, how strongly it
// reaches you and whether it hears you, which one is "yours", and whether it has gone quiet.
//
// Repeaters don't keep a list of "connected" users, but every packet carries the hashes of the
// repeaters it passed through. The first one is where the sender entered the mesh, so adverts and
// channel messages tell us who uses which repeater. Neighbouring hashes in a path are repeaters
// that hear each other. Hashes resolve only to repeaters on our radio settings, nearest first.
import { compatibleRadio, HEARD_TYPES, km, splitPath } from "./mesh"
import type {
  AppState, NodeType, Packet, PacketInfo, PublicNode, RepeaterDetail, RepeaterList, RepeaterLive, RepeaterQuiet, RepeaterSummary, RepeaterUser,
  Route, SignalPoint,
} from "./types"

export interface AnalysisInput {
  state: AppState
  /** newest first, as the API returns them */
  packets: Packet[]
  routes: Route[]
  publicNodes: PublicNode[]
  live: Record<string, RepeaterLive>
}

interface Cand { key: string; name: string | null; type: NodeType; lat: number | null; lon: number | null; contact: boolean; radio?: string | null }
interface User { key: string | null; name: string | null; type: string; count: number; last_ts: number; uncertain: boolean; via: Set<string> }
interface Stat {
  relayed: number; first_hop: number; last_hop: number; uncertain: number; last_ts: number; snr: number[]
  people: Map<string, User>; nodes: Map<string, User>; links: Map<string, { to: number; from: number }>
  hourly: number[]; recent: RepeaterDetail["recent"]
  signal: SignalPoint[]; heard_you: { count: number; last_ts: number }
  /** the newest packet heard straight from it */
  last_direct: number
}
type Hop = { key: string; unc: boolean } | null

export interface Analysis {
  reps: Map<string, Cand>; stats: Map<string, Stat>; unknown: number; packets: number; since: number | null
  /** when each counted packet arrived */
  times: number[]
}

const isRep = (t: NodeType | undefined) => t === "repeater" || t === "room"
const round = (x: number, d: number) => Math.round(x * 10 ** d) / 10 ** d
const located = <T extends { lat?: number | null; lon?: number | null }>(c: T | undefined): c is T & { lat: number; lon: number } =>
  !!c && c.lat != null && c.lon != null

function candidates({ state, publicNodes }: AnalysisInput) {
  const reps = new Map<string, Cand>()
  for (const n of publicNodes) {
    if (isRep(n.type) && compatibleRadio(n.radio, state.self) !== false)
      reps.set(n.pubkey, { key: n.pubkey, name: n.name, type: n.type, lat: n.lat, lon: n.lon, contact: false, radio: n.radio })
  }
  for (const [k, h] of Object.entries(state.heard)) {
    const t = HEARD_TYPES[h.type ?? 0]
    if (!isRep(t)) continue
    const prev = reps.get(k)
    reps.set(k, { ...prev, key: k, name: h.name || prev?.name || null, type: t, lat: h.lat ?? prev?.lat ?? null,
      lon: h.lon ?? prev?.lon ?? null, contact: prev?.contact ?? false })
  }
  for (const [k, c] of Object.entries(state.contacts)) {
    if (!isRep(c.type)) continue
    const prev = reps.get(k)
    reps.set(k, { ...prev, key: k, name: c.name, type: c.type, lat: c.lat ?? prev?.lat ?? null, lon: c.lon ?? prev?.lon ?? null, contact: true })
  }
  return reps
}

/** One entry per hop, origin → us; null where no repeater has that hash. */
function resolve(hops: string[], reps: Map<string, Cand>, cache: Map<string, Cand[]>, home: { lat: number; lon: number }): Hop[] {
  let prev = home
  const out: Hop[] = new Array(hops.length).fill(null)
  for (let i = hops.length - 1; i >= 0; i--) {
    const pfx = hops[i]
    let c = cache.get(pfx)
    if (!c) {
      const all = [...reps.values()].filter((r) => r.key.startsWith(pfx))
      const onlyRepeaters = all.filter((r) => r.type === "repeater")
      c = onlyRepeaters.length ? onlyRepeaters : all
      cache.set(pfx, c)
    }
    if (!c.length) continue
    const loc = c.filter(located)
    const best = c.length === 1 || !loc.length ? c[0] : loc.reduce((a, b) => (km(prev, a) <= km(prev, b) ? a : b))
    out[i] = { key: best.key, unc: c.length > 1 }
    if (located(best)) prev = { lat: best.lat, lon: best.lon }
  }
  return out
}

const parseInfo = (s: string): PacketInfo => {
  try { return (JSON.parse(s || "{}") as PacketInfo) ?? {} } catch { return {} }
}

export function analyse(inp: AnalysisInput, days: number, now = Date.now() / 1000): Analysis {
  const since = now - days * 86400
  const home = inp.state.home
  const reps = candidates(inp), cache = new Map<string, Cand[]>(), stats = new Map<string, Stat>()
  let unknown = 0
  const S = (key: string) => {
    let s = stats.get(key)
    if (!s) {
      s = { relayed: 0, first_hop: 0, last_hop: 0, uncertain: 0, last_ts: 0, snr: [], people: new Map(), nodes: new Map(),
        links: new Map(), hourly: new Array(24).fill(0), recent: [],
        signal: [], heard_you: { count: 0, last_ts: 0 }, last_direct: 0 }
      stats.set(key, s)
    }
    return s
  }
  const link = (a: string, b: string) => {   // a passed a packet on to b
    const la = S(a).links, lb = S(b).links
    if (!la.has(b)) la.set(b, { to: 0, from: 0 })
    if (!lb.has(a)) lb.set(a, { to: 0, from: 0 })
    la.get(b)!.to++
    lb.get(a)!.from++
  }
  const user = (s: Stat, key: string | null, name: string | null | undefined, ntype: string | null | undefined, ts: number, unc: boolean, via: string) => {
    const bucket = ntype == null || ntype === "companion" ? s.people : s.nodes
    const id = key ?? `name:${name}`
    let e = bucket.get(id)
    if (!e) { e = { key, name: name ?? null, type: ntype || "companion", count: 0, last_ts: 0, uncertain: true, via: new Set() }; bucket.set(id, e) }
    e.count++
    e.last_ts = Math.max(e.last_ts, ts)
    e.uncertain = e.uncertain && unc
    e.via.add(via)
    e.name = name || e.name
  }
  const repByPrefix = (pfx: string) => { for (const k of reps.keys()) if (k.startsWith(pfx)) return k; return null }
  const contactKeys = Object.keys(inp.state.contacts)

  let counted = 0, oldest: number | null = null
  const times: number[] = []
  for (let p = inp.packets.length - 1; p >= 0; p--) {   // oldest first, like ORDER BY id
    const r = inp.packets[p]
    if (r.ts <= since) continue
    counted++
    times.push(r.ts)
    oldest = oldest == null ? r.ts : Math.min(oldest, r.ts)
    const info = parseInfo(r.info)
    const hops = splitPath(r.path, r.hash_size)
    if (!hops.length) {
      // a repeater's own advert heard straight from it: we hear that repeater directly
      if (r.type === "ADVERT" && info.node_type === "repeater" && info.key) {
        const k = repByPrefix(info.key)
        if (k) {
          const s = S(k)
          s.last_ts = Math.max(s.last_ts, r.ts)
          heardDirect(s, r)
        }
      }
      continue
    }
    const res = resolve(hops, reps, cache, home)
    res.forEach((hop, i) => {
      if (!hop) { unknown++; return }
      const s = S(hop.key)
      s.relayed++
      s.uncertain += hop.unc ? 1 : 0
      s.last_ts = Math.max(s.last_ts, r.ts)
      const age = Math.floor((now - r.ts) / 3600)
      if (age >= 0 && age < 24) s.hourly[23 - age]++
      const next = res[i + 1]
      if (next && next.key !== hop.key) link(hop.key, next.key)
      if (i === res.length - 1) heardDirect(s, r)   // the copy we heard came from this repeater
      if (i === 0) {
        s.first_hop++
        if (r.type === "ADVERT" && info.key) {
          if (info.node_type === "repeater") {
            const own = repByPrefix(info.key)
            if (own && own !== hop.key) link(own, hop.key)   // that repeater's own advert was heard first by this one
          } else {
            const full = contactKeys.find((k) => k.startsWith(info.key!)) ?? info.key
            user(s, full, info.name, info.node_type, r.ts, hop.unc, "advert")
          }
        }
      }
      if (s.recent.length >= 15) s.recent.shift()
      s.recent.push({ ts: r.ts, type: r.type, hops: r.hops ?? hops.length, position: i + 1, snr: i === res.length - 1 ? r.snr : null,
        what: info.name || info.channel || info.channel_hash || null })
    })
  }

  // channel messages name their sender: who sent through which repeater
  // (and your own, as a repeater passed them on: the first repeater on the route heard you directly)
  for (const m of inp.routes) {
    if (m.ts <= since || !m.sender || !m.path) continue
    const res = resolve(splitPath(m.path, m.hash_size), reps, cache, home)
    if (!res[0]) continue
    const s = S(res[0].key)
    if (m.out) { s.heard_you.count++; s.heard_you.last_ts = Math.max(s.heard_you.last_ts, m.ts) }
    else user(s, null, m.sender, null, m.ts, res[0].unc, "channel")
  }

  // merge "name:" entries into the advert entry with the same name
  for (const s of stats.values()) {
    for (const [nk, e] of [...s.people]) {
      if (!nk.startsWith("name:")) continue
      const twin = [...s.people].find(([k, v]) => !k.startsWith("name:") && v.name === e.name)?.[1]
      if (!twin) continue
      twin.count += e.count
      twin.last_ts = Math.max(twin.last_ts, e.last_ts)
      e.via.forEach((v) => twin.via.add(v))
      twin.uncertain = twin.uncertain && e.uncertain
      s.people.delete(nk)
    }
  }
  return { reps, stats, unknown, packets: counted, since: oldest, times }
}

const emptyStat = (): Stat => ({ relayed: 0, first_hop: 0, last_hop: 0, uncertain: 0, last_ts: 0, snr: [], people: new Map(),
  nodes: new Map(), links: new Map(), hourly: new Array(24).fill(0), recent: [], signal: [], heard_you: { count: 0, last_ts: 0 }, last_direct: 0 })
const MAX_SIGNAL = 2000

/** a packet heard straight from this repeater: count it and remember how strong it was */
function heardDirect(s: Stat, r: Packet) {
  s.last_hop++
  s.last_direct = Math.max(s.last_direct, r.ts)
  if (r.snr == null) return
  s.snr.push(r.snr)
  s.signal.push({ ts: r.ts, snr: r.snr, rssi: r.rssi, type: r.type })
}

function summary(key: string, rep: Partial<Cand>, s: Stat, home: { lat: number; lon: number }): RepeaterSummary {
  const snr = [...s.snr].sort((a, b) => a - b)
  return {
    key, name: rep.name || key.slice(0, 8), type: rep.type ?? "repeater", contact: rep.contact ?? false,
    lat: rep.lat ?? null, lon: rep.lon ?? null, radio: rep.radio,
    km: located(rep) ? round(km(home, rep), 1) : null,
    relayed: s.relayed, first_hop: s.first_hop, last_hop: s.last_hop,
    uncertain_share: s.relayed ? round(s.uncertain / s.relayed, 2) : 0,
    direct: s.last_hop > 0, snr_median: snr.length ? snr[Math.floor(snr.length / 2)] : null,
    people: s.people.size, nodes: s.nodes.size, links: s.links.size, last_ts: s.last_ts, hourly: s.hourly,
  }
}

/** A repeater gone quiet: one you heard straight from regularly (10+ packets), then nothing from it
 *  for a while, though so much else arrived that, at its usual share of what you hear, a good
 *  number of those packets should have been its own. That points at the repeater (switched off,
 *  broken, reconfigured), not at a quiet mesh. */
export const QUIET_AFTER_S = 15 * 60, QUIET_MIN_HEARD = 10, QUIET_EXPECTED = 8, QUIET_NEXT_S = 30 * 60

function quiet(a: Analysis, key: string, now: number): RepeaterQuiet | null {
  const s = a.stats.get(key)
  if (!s || s.last_hop < QUIET_MIN_HEARD || now - s.last_direct < QUIET_AFTER_S) return null
  let before = 0, after = 0
  for (const t of a.times) if (t > s.last_direct) after++; else before++
  const expected = before ? (s.last_hop / before) * after : 0
  if (expected < QUIET_EXPECTED) return null
  // the repeater that reaches you best now: the last half hour, at least 3 packets straight from it
  const from = Math.max(s.last_direct, now - QUIET_NEXT_S)
  let next: RepeaterQuiet["next"] = null
  for (const [k, o] of a.stats) {
    if (k === key) continue
    const snr = o.signal.filter((p) => p.ts > from).map((p) => p.snr).sort((x, y) => x - y)
    if (snr.length < 3) continue
    const med = snr[Math.floor(snr.length / 2)]
    const r = a.reps.get(k)
    if (!next || med > next.snr) next = { key: k, name: r?.name || k.slice(0, 8), snr: med, lat: r?.lat ?? null, lon: r?.lon ?? null }
  }
  return { since: s.last_direct, missed: after, expected: Math.round(expected), next }
}

export function repeaterList(a: Analysis, inp: AnalysisInput, days: number, now = Date.now() / 1000): RepeaterList {
  const out = [...a.stats].map(([k, s]) => summary(k, a.reps.get(k) ?? {}, s, inp.state.home))
  out.sort((x, y) => y.relayed - x.relayed || x.name.localeCompare(y.name))
  const yours = pickYours(a, out)
  return { days, your_repeater: yours?.key ?? null, your_repeater_basis: yours?.basis ?? null, your_repeater_passed: yours?.passed ?? 0,
    your_repeater_quiet: yours ? quiet(a, yours.key, now) : null, repeaters: out, unknown_hops: a.unknown, coverage: { packets: a.packets, since: a.since, held: inp.packets.length } }
}

/** "Your" repeater: the one that most often passed on your messages first, so it demonstrably hears
 *  you (the latest on a tie). With none in this period, the one you hear most packets from directly. */
function pickYours(a: Analysis, out: RepeaterSummary[]) {
  let best: [string, Stat] | null = null
  for (const [k, s] of a.stats) {
    const h = s.heard_you, b = best?.[1].heard_you
    if (h.count && (!b || h.count > b.count || (h.count === b.count && h.last_ts > b.last_ts))) best = [k, s]
  }
  if (best) return { key: best[0], basis: "passes_yours" as const, passed: best[1].heard_you.count }
  let most: RepeaterSummary | null = null
  for (const r of out) if (!most || r.last_hop > most.last_hop) most = r
  return most && most.last_hop ? { key: most.key, basis: "heard_most" as const, passed: 0 } : null
}

export function repeaterDetail(a: Analysis, inp: AnalysisInput, key: string, now = Date.now() / 1000): RepeaterDetail | null {
  const rep = a.reps.get(key), st = a.stats.get(key)
  if (!rep && !st) return null
  const s = st ?? emptyStat()
  const home = inp.state.home
  const fix = (e: User): RepeaterUser => ({ ...e, via: [...e.via].sort() })
  const byRecent = (x: RepeaterUser, y: RepeaterUser) => y.last_ts - x.last_ts
  const dist = (o: Partial<Cand> | undefined) =>
    located(rep) && located(o) ? round(km(rep, o), 1) : null
  const links = [...s.links].map(([k, c]) => {
    const o = a.reps.get(k)
    return { key: k, name: o?.name || k.slice(0, 8), lat: o?.lat ?? null, lon: o?.lon ?? null, to: c.to, from: c.from, km: dist(o) }
  }).sort((x, y) => y.to + y.from - (x.to + x.from))
  const raw = inp.live[key]
  const live: RepeaterLive | null = raw ? {
    ...raw,
    neighbours: raw.neighbours?.map((n) => {
      const m = [...a.reps.values()].find((r) => r.key.startsWith(n.pubkey))
      return { ...n, name: m?.name ?? null, key: m?.key ?? null, km: dist(m) }
    }) ?? null,
  } : null
  const sum = summary(key, rep ?? {}, s, home)
  return {
    ...sum,
    people_list: [...s.people.values()].map(fix).sort(byRecent),
    nodes_list: [...s.nodes.values()].map(fix).sort(byRecent),
    links_list: links,
    recent: [...s.recent].reverse(),
    signal: s.signal.slice(-MAX_SIGNAL),
    heard_you: s.heard_you,
    quiet: quiet(a, key, now),
    live,
    can_query: key in inp.state.contacts,
  }
}
