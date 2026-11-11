// Pure helpers for mesh data. No React here, so components can memoise freely.
import type { AppState, Contact, Home, MeshNode, NodeType, Person, PublicNode } from "./types"

export const HEARD_TYPES: Record<number, NodeType> = { 1: "companion", 2: "repeater", 3: "room", 4: "sensor" }

export const encoder = new TextEncoder()
export const byteLength = (s: string) => encoder.encode(s).length

/** accent-insensitive search: "lodz" finds "Łódź" */
export const fold = (s: string) =>
  s.normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[łŁ]/g, "l").toLowerCase()

export function km(a: { lat: number; lon: number }, b: { lat: number; lon: number }) {
  const r = Math.PI / 180
  const x = Math.sin(((b.lat - a.lat) * r) / 2) ** 2 +
    Math.cos(a.lat * r) * Math.cos(b.lat * r) * Math.sin(((b.lon - a.lon) * r) / 2) ** 2
  return 2 * 6371 * Math.asin(Math.sqrt(x))
}

const COMPASS = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
/** Which way b is from a, as one of eight compass words. */
export function bearing(a: { lat: number; lon: number }, b: { lat: number; lon: number }) {
  const r = Math.PI / 180, dl = (b.lon - a.lon) * r
  const y = Math.sin(dl) * Math.cos(b.lat * r)
  const x = Math.cos(a.lat * r) * Math.sin(b.lat * r) - Math.sin(a.lat * r) * Math.cos(b.lat * r) * Math.cos(dl)
  const deg = (Math.atan2(y, x) / r + 360) % 360
  return COMPASS[Math.round(deg / 45) % 8]
}

/** A usable position: present, not 0,0 (none), and within range (a contact added without one can
 *  carry garbage from the radio's memory) */
export const hasLoc = (n: { lat: number | null; lon: number | null } | null | undefined): n is { lat: number; lon: number } =>
  !!n && n.lat != null && n.lon != null && !(n.lat === 0 && n.lon === 0) && Math.abs(n.lat) <= 90 && Math.abs(n.lon) <= 180

export function ago(sec?: number | null) {
  if (!sec) return "never"
  const d = Date.now() / 1000 - sec
  if (d < 0) return "clock ahead"
  if (d < 45) return "just now"
  if (d < 3600) return `${Math.max(1, Math.round(d / 60))} min ago`
  if (d < 86400) return `${Math.floor(d / 3600)} h ago`
  return `${Math.floor(d / 86400)} d ago`
}

export const clock = (sec: number) => new Date(sec * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
export const dayLabel = (sec: number) => {
  const d = new Date(sec * 1000), today = new Date()
  const y = new Date(); y.setDate(today.getDate() - 1)
  if (d.toDateString() === today.toDateString()) return "Today"
  if (d.toDateString() === y.toDateString()) return "Yesterday"
  return d.toLocaleDateString([], { weekday: "long", day: "numeric", month: "long" })
}

export function duration(s?: number | null) {
  if (s == null) return "—"
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60)
  return d ? `${d} d ${h} h` : h ? `${h} h ${m} min` : `${m} min`
}

export const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`
export const daysLabel = (d: number) => (d === 1 ? "last 24 h" : `last ${d} days`)

export function splitPath(hex: string | null | undefined, size?: number | null) {
  const n = Math.max(1, size || 1) * 2, out: string[] = []
  for (let i = 0; hex && i < hex.length; i += n) out.push(hex.slice(i, i + n))
  return out
}

/** The weakest SNR (dB) LoRa still decodes at a spreading factor: −2.5 dB per step from SF5
 *  (SX126x datasheet: SF6 −5, SF7 −7.5, SF8 −10 … SF12 −20). */
export const snrFloor = (sf = 6) => -2.5 * (sf - 4)
/** How much headroom a signal has above that floor, in four levels (0: no data). LoRa links want
 *  about 10 dB of fade margin, and you only ever see the packets that made it, so a signal just
 *  above the floor looks better than the link is. 1 below the floor (got through by luck),
 *  2 marginal (0–5 dB: fading and collisions lose many packets), 3 fair (5–10 dB), 4 good (10+). */
export type SnrLevel = 0 | 1 | 2 | 3 | 4
export const SNR_LEVELS = ["no data", "below the limit", "marginal", "fair", "good"] as const
/** headroom (dB above the floor) where marginal, fair and good begin */
export const SNR_STEPS = [0, 5, 10] as const
export function snrQuality(snr: number | null | undefined, sf = 6): SnrLevel {
  if (snr == null) return 0
  const m = snr - snrFloor(sf)
  return m < SNR_STEPS[0] ? 1 : m < SNR_STEPS[1] ? 2 : m < SNR_STEPS[2] ? 3 : 4
}

export function initials(name: string) {
  const clean = name.replace(/[^\p{L}\p{N} ]/gu, " ").trim()
  const parts = clean.split(/\s+/).filter(Boolean)
  if (!parts.length) return name.slice(0, 2).toUpperCase()
  return (parts.length > 1 ? parts[0][0] + parts[1][0] : parts[0].slice(0, 2)).toUpperCase()
}

/** Stable hue per name, for avatars. */
export function nameHue(name: string) {
  let h = 0
  for (const ch of name) h = (h * 31 + ch.codePointAt(0)!) % 360
  return h
}

// ---------------------------------------------------------------- conversations
export const isChannel = (conv: string) => conv.startsWith("chan:")
/** a hashtag channel the radio reads without having joined it */
export const isListened = (conv: string) => conv.startsWith("watch:")
export function convTitle(state: AppState | undefined, conv: string) {
  const [kind, id] = conv.split(/:(.*)/s)
  if (kind === "chan") return state?.channels.find((c) => String(c.idx) === id)?.name ?? `Channel ${id}`
  if (kind === "watch") return id
  return state?.contacts[id]?.name ?? id.slice(0, 8)
}

/** Split text into plain strings and @[Name] tags (the MeshCore mention convention). */
export function tokenize(text: string): ({ text: string } | { tag: string })[] {
  const out: ({ text: string } | { tag: string })[] = [], re = /@\[([^\]]{1,40})\]/g
  let last = 0, m: RegExpExecArray | null
  while ((m = re.exec(text))) {
    if (m.index > last) out.push({ text: text.slice(last, m.index) })
    out.push({ tag: m[1] })
    last = re.lastIndex
  }
  if (last < text.length) out.push({ text: text.slice(last) })
  return out
}

// ---------------------------------------------------------------- nodes
/** Frequency, bandwidth and SF must match to hear each other; coding rate doesn't matter. */
export function compatibleRadio(radio: string | null | undefined, self?: AppState["self"]): boolean | null {
  const r = self?.radio
  if (!radio || !r) return null
  const [f, bw, sf] = radio.split("/")
  return Math.abs(parseFloat(f) - r.freq) < 0.002 && parseFloat(bw) === r.bw && parseInt(sf?.replace("SF", "") ?? "", 10) === r.sf
}

export function buildNodes(state: AppState | undefined, publicNodes: PublicNode[] | undefined): Map<string, MeshNode> {
  const out = new Map<string, MeshNode>()
  for (const p of publicNodes ?? []) {
    out.set(p.pubkey, { pubkey: p.pubkey, name: p.name, type: p.type, lat: p.lat, lon: p.lon, last_advert: p.last_advert,
      radio: p.radio, contact: false, compatible: compatibleRadio(p.radio, state?.self) })
  }
  for (const [k, c] of Object.entries(state?.contacts ?? {})) {
    const prev = out.get(k)
    out.set(k, { ...prev, pubkey: k, name: c.name, type: c.type, lat: c.lat ?? prev?.lat ?? null, lon: c.lon ?? prev?.lon ?? null,
      last_advert: c.last_advert, out_path_len: c.out_path_len, contact: true, compatible: true })
  }
  for (const [k, h] of Object.entries(state?.heard ?? {})) {
    const prev = out.get(k)
    out.set(k, { ...prev, pubkey: k, name: h.name ?? prev?.name ?? k.slice(0, 8),
      type: prev?.type ?? HEARD_TYPES[h.type ?? 0] ?? "unknown", lat: h.lat ?? prev?.lat ?? null, lon: h.lon ?? prev?.lon ?? null,
      heard: h, contact: prev?.contact ?? false, compatible: true })
  }
  return out
}

export function contactByName(state: AppState | undefined, name: string): Contact | null {
  const c = Object.values(state?.contacts ?? {}).filter((x) => x.name === name && x.type === "companion")
  return c.sort((a, b) => (b.last_advert ?? 0) - (a.last_advert ?? 0))[0] ?? null
}

export interface ResolvedHop { node: MeshNode; ambiguous: number }

/** Path hashes are 1–3 byte key prefixes of the forwarding repeaters. Only repeaters on our
 *  settings can forward; among several, take the one nearest the neighbouring hop. */
export function resolveHop(prefix: string, near: { lat: number; lon: number } | null, nodes: Map<string, MeshNode>): ResolvedHop | null {
  const cands = [...nodes.values()].filter((n) => n.pubkey.startsWith(prefix) && hasLoc(n) && n.compatible !== false)
  const rpt = cands.filter((n) => n.type === "repeater")
  const pool = rpt.length ? rpt : cands.filter((n) => n.type === "room")
  if (!pool.length) return null
  const dist = (n: MeshNode) => km(near!, { lat: n.lat!, lon: n.lon! })   // pool is filtered by hasLoc
  const best = near ? [...pool].sort((a, b) => dist(a) - dist(b))[0] : pool[0]
  return { node: best, ambiguous: pool.length > 1 ? pool.length : 0 }
}

/** Resolve a whole path, origin → you, chaining proximity from your home backwards. */
export function resolvePath(hex: string | null | undefined, size: number | null | undefined, home: Home | undefined, nodes: Map<string, MeshNode>) {
  const hops = splitPath(hex, size), resolved: (ResolvedHop | null)[] = new Array(hops.length).fill(null)
  let prev: { lat: number; lon: number } | null = home ?? null
  for (let i = hops.length - 1; i >= 0; i--) {
    const r = resolveHop(hops[i], prev, nodes)
    if (r) { resolved[i] = r; prev = r.node as { lat: number; lon: number } }
  }
  return { hops, resolved }
}

export const hopLabel = (r: ResolvedHop | null, prefix: string) => (r ? `${r.node.name}${r.ambiguous ? " (?)" : ""}` : `? ${prefix}`)

export interface PersonLocation {
  lat: number
  lon: number
  exact: boolean
  direct?: boolean
  via?: MeshNode
  how: string
}

/** Exact if their advert carries GPS; otherwise near the first repeater that heard them. */
export function locatePerson(p: Person, state: AppState | undefined, nodes: Map<string, MeshNode>): PersonLocation | null {
  const exact = [...nodes.values()].filter((n) => n.name === p.name && hasLoc(n))
    .sort((a, b) => (b.heard?.last_heard ?? b.last_advert ?? 0) - (a.heard?.last_heard ?? a.last_advert ?? 0))[0]
  if (exact && hasLoc(exact)) return { lat: exact.lat, lon: exact.lon, exact: true, how: "GPS position from their advert" }
  let path = p.path, size = p.hash_size, hops = p.hops
  if (path == null) {
    const adv = Object.values(state?.heard ?? {}).filter((h) => h.name === p.name && h.path != null).sort((a, b) => b.last_heard - a.last_heard)[0]
    if (adv) { path = adv.path; size = adv.hash_size; hops = adv.hops }
  }
  const home = state?.home
  if (hops === 0 && home) return { lat: home.lat, lon: home.lon, exact: false, direct: true, how: "heard directly by your radio, within a few km" }
  if (path) {
    const { resolved } = resolvePath(path, size, home, nodes)
    const i = resolved.findIndex(Boolean)
    if (i >= 0) {
      const r = resolved[i]!
      const n = r.node as MeshNode & { lat: number; lon: number }
      const how = (i === 0 ? `near ${n.name}, the first repeater that heard them` : `beyond ${n.name} (${i} more hop${i > 1 ? "s" : ""} not on the map)`) +
        (r.ambiguous ? `; uncertain, ${r.ambiguous} repeaters share that ID` : "")
      return { lat: n.lat, lon: n.lon, exact: false, via: n, how }
    }
  }
  return null
}
