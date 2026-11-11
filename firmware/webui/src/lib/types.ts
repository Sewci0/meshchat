// Shapes the radio's HTTP API (/api) and WebSocket (/ws) return. Everything that originates on the
// mesh (names, text) is untrusted.

export type NodeType = "companion" | "repeater" | "room" | "sensor" | "unknown"

export interface Radio { freq: number; bw: number; sf: number; cr: number }

export interface SelfInfo {
  name: string
  pubkey: string
  tx_power: number
  radio: Radio
  fw?: string
  model?: string
  path_hash_mode?: number
  loc_policy?: number
}

export interface Channel { idx: number; name: string; hash: string }

export interface Contact {
  pubkey: string
  name: string
  type: NodeType
  lat: number | null
  lon: number | null
  last_advert?: number
  out_path_len?: number
  out_path?: string
  hash_mode?: number
  /** what's known about the saved route's history (absent: nothing recorded for this contact) */
  route?: RouteHistory
  /** rooms: the newest post time the radio has, which it sends when logging in */
  sync_since?: number
}

/** Kept per contact by the radio as routes are learned and reset. */
export interface RouteHistory {
  /** when the current route was learned and last re-learned unchanged (null: before tracking, or it's gone) */
  learned: number | null
  confirmed: number | null
  /** routes learned (the same one again counts too), and how often it differed from the one before */
  learns: number
  changes: number
  /** the route before the current one (or the one that was reset) */
  previous: { out_path_len: number; hash_mode: number; out_path: string; since: number | null } | null
  /** the last time it was forgotten: by you (Reset path), a DM's last try (retry) or another app */
  reset: { at: number; by: "you" | "retry" | "app" | "" } | null
  /** the PATH packet that brought the current route: how it reached you */
  via: { pkt_id: number; snr: number | null; rssi: number | null; hops: number; hash_size: number } | null
}

/** A room server you joined (logged in to) from MeshChat */
export interface Room {
  key: string
  joined: number | null
  login_at: number | null
  left: boolean
  left_at: number | null
  /** what the room lets you do (newer room firmware says; null if it didn't) */
  role: RoomRole | null
  admin: boolean
}
export type RoomRole = "guest" | "read-only" | "read-write" | "admin"

export interface Heard {
  pubkey: string
  name: string | null
  type: number | null
  lat: number | null
  lon: number | null
  first_heard: number
  last_heard: number
  snr: number | null
  rssi: number | null
  hops: number | null
  path: string | null
  hash_size: number | null
  count: number
}

export interface Conversation { conv: string; last_id: number; n: number; last_ts: number }

export interface Home { lat: number; lon: number; label?: string }

export interface DeviceWifi {
  supported: boolean
  mode?: "connected" | "connecting" | "setup" | "off" | string
  hostname?: string
  /** the radio's built-in meshcore-xxxx name: always answered too, whatever the hostname */
  default_hostname?: string
  ssid?: string | null
  ip?: string | null
  rssi?: number | null
  password_set?: boolean
  ble_pin_set?: boolean
  /** the network it's on now, and all saved ones (most preferred first; never passwords) */
  connected_ssid?: string | null
  networks?: { ssid: string; password_set: boolean; connected: boolean }[]
  max_networks?: number
}

export interface Listening {
  listening: { name: string; hash: string; found: boolean; count: number; last: number }[]
  /** channel packets no joined or listened channel could read, by 1-byte channel hash */
  unreadable: { hash: string; count: number; last: number }[]
  /** when the counts started (the radio's last restart) */
  since: number
  max: number
}

export interface AppState {
  connected: boolean
  port: string
  self: SelfInfo
  channels: Channel[]
  contacts: Record<string, Contact>
  /** room servers joined from MeshChat (older firmware: absent) */
  rooms?: Room[]
  heard: Record<string, Heard>
  conversations: Record<string, Conversation>
  home: Home
  advertised: { ts: number; flood: boolean; name: string } | null
  limits: { max_text_bytes: number }
}

export type MessageStatus = "received" | "sending" | "sent" | "repeated" | "not heard" | "delivered" | "no ack" | "failed"

export interface Message {
  id: number
  ts: number
  sender_ts: number | null
  conv: string
  direction: "in" | "out"
  sender: string | null
  text: string
  hops: number | null
  path: string | null
  hash_size: number | null
  snr: number | null
  rssi: number | null
  status: MessageStatus
  repeats: number
  msg_hash: number | null
  /** transmissions so far (channel messages are re-sent until a repeater echo is heard) */
  attempts?: number | null
  /** our DMs: for each try, whether it went by flood (no saved route) rather than the saved route */
  tries_flood?: boolean[]
  /** our DMs: the try the ACK answered (1-3), and the radio's round trip for it in ms */
  ack_try?: number
  rtt_ms?: number | null
  /** room posts: the first 4 bytes (8 hex) of the author's key */
  author?: string
}

/** One copy of a message's packet as the radio heard it: every copy has the same payload
 *  fingerprint, but each came by its own route (or, for ours, from another repeater). */
export interface MessageCopy {
  id: number
  ts: number
  /** after the first copy */
  after_ms: number
  route: string
  type: string
  hops: number
  hash_size: number
  path: string
  snr: number | null
  rssi: number | null
  /** bytes, and the packet itself in hex: header, transport codes, path, payload */
  len: number
  raw: string
}

/** GET /api/message-info: everything known about one message */
export interface MessageInfo {
  id: number
  kind: "channel" | "dm" | "listened"
  dir: "in" | "out"
  ts: number
  sender_ts: number
  status: string
  attempts: number
  repeats: number
  sender: string
  text: string
  hops: number
  hash_size: number
  path: string
  has_rf: boolean
  snr: number
  rssi: number
  /** its packet's fingerprint (SHA-256 of the payload, first 4 bytes); null if it couldn't be linked */
  fp: string | null
  channel?: { idx: number; hash: string; key: "hashtag" | "public" | "private"; name: string }
  /** DMs: the other side's public key */
  peer?: string
  copies: MessageCopy[]
  /** the oldest packet in the log: copies before it are gone (the radio's log restarts empty) */
  log_since: number
  /** from the decrypted packet: 0 plain text, 1 CLI, 2 signed (room servers); attempt 0-3 */
  txt_type?: number
  attempt?: number
}

export interface Packet {
  id?: number
  ts: number
  route: string
  type: string
  hops: number | null
  path: string | null
  hash_size: number | null
  snr: number | null
  rssi: number | null
  info: string
}

/** a channel message's route, for the repeater analysis. `out`: one of yours, as a repeater passed it on (its echo) */
export interface Route { id?: number; ts: number; sender: string; path: string; hash_size: number | null; out?: boolean }

/** one packet heard directly from a repeater: how strong it arrived */
export interface SignalPoint { ts: number; snr: number; rssi: number | null; type: string }

export interface PublicNodes {
  fetched: number
  nodes: PublicNode[]
  /** the radio downloads the public map itself */
  status?: { running: boolean; took_s?: number; received?: number; size?: number; seen?: number; error: string | null }
}

export interface PacketInfo { name?: string; node_type?: string; key?: string; channel?: string; channel_hash?: string }

export interface PublicNode {
  pubkey: string
  name: string
  type: NodeType
  lat: number
  lon: number
  last_advert: number
  km: number
  radio: string | null
}

export interface Person {
  name: string
  n: number
  convs: string[]
  last_ts: number
  last_conv: string
  path: string | null
  hash_size?: number | null
  hops: number | null
}

/** A node as the UI sees it: merged from contacts, adverts we heard, and the public map. */
export interface MeshNode {
  pubkey: string
  name: string
  type: NodeType
  lat: number | null
  lon: number | null
  last_advert?: number
  radio?: string | null
  contact: boolean
  heard?: Heard
  /** false = different radio settings, can't hear us; null = unknown */
  compatible: boolean | null
  out_path_len?: number
}

export interface RepeaterSummary {
  key: string
  name: string
  type: NodeType
  contact: boolean
  lat: number | null
  lon: number | null
  radio?: string | null
  km: number | null
  relayed: number
  first_hop: number
  last_hop: number
  uncertain_share: number
  direct: boolean
  snr_median: number | null
  people: number
  nodes: number
  links: number
  last_ts: number
  hourly: number[]
}

export interface RepeaterUser {
  key: string | null
  name: string | null
  type: string
  count: number
  last_ts: number
  uncertain: boolean
  via: string[]
}

export interface RepeaterLink {
  key: string
  name: string
  lat: number | null
  lon: number | null
  to: number
  from: number
  km: number | null
}

export interface RepeaterStatus {
  bat: number
  tx_queue_len: number
  noise_floor: number
  last_rssi: number
  nb_recv: number
  nb_sent: number
  airtime: number
  uptime: number
  sent_flood: number
  sent_direct: number
  recv_flood: number
  recv_direct: number
  full_evts: number
  last_snr: number
  direct_dups: number
  flood_dups: number
  /** room servers: posts stored since it started, and posts it pushed to members */
  posted?: number
  post_pushes?: number
}

export interface RepeaterLive {
  key?: string
  /** the radio runs queries in the background: true until the answer is in */
  running?: boolean
  ts: number
  ok: boolean
  error?: string
  login: {
    admin: boolean
    permissions: number
    /** newer firmware: what the login lets you do, its clock, and its firmware level */
    role?: RoomRole | null
    server_time?: number
    fw_level?: number
  } | null
  /** a room server (joined, not just queried) */
  room?: boolean
  status: RepeaterStatus | null
  neighbours: { pubkey: string; secs_ago: number; snr: number; name?: string | null; key?: string | null; km?: number | null }[] | null
  neighbours_total: number | null
}

/** A repeater that has gone quiet (see quiet() in repeaters.ts) */
export interface RepeaterQuiet {
  /** the last packet heard straight from it */
  since: number
  /** packets heard since, from anyone */
  missed: number
  /** how many of those would have come from it, at its usual share */
  expected: number
  /** the repeater that reaches you best now: median SNR of what you heard straight from it lately */
  next: { key: string; name: string; snr: number; lat: number | null; lon: number | null } | null
}

export interface RepeaterDetail extends RepeaterSummary {
  /** packets you heard straight from it, oldest first: its signal at your radio over time */
  signal: SignalPoint[]
  /** your messages it was the first to pass on, so it heard you directly */
  heard_you: { count: number; last_ts: number }
  /** set while it has gone quiet */
  quiet?: RepeaterQuiet | null
  people_list: RepeaterUser[]
  nodes_list: RepeaterUser[]
  links_list: RepeaterLink[]
  recent: { ts: number; type: string; hops: number; position: number; snr: number | null; what?: string | null }[]
  live: RepeaterLive | null
  can_query: boolean
}

export interface RepeaterList {
  days: number
  your_repeater: string | null
  /** why: it passed on your messages first (so it hears you), or, without any, you hear it most */
  your_repeater_basis?: "passes_yours" | "heard_most" | null
  /** how many of your messages it passed on first, in this period */
  your_repeater_passed?: number
  /** set while your repeater has gone quiet: your messages may not get through */
  your_repeater_quiet?: RepeaterQuiet | null
  repeaters: RepeaterSummary[]
  unknown_hops: number
  /** how much of the radio's packet log the analysis covers */
  coverage?: { packets: number; since: number | null; held: number }
}

export type LiveEvent =
  | { kind: "message"; data: Message }
  | { kind: "packet"; data: Packet }
  | { kind: "heard"; data: Heard }
  | { kind: "live"; data: RepeaterLive }
  | { kind: "cli"; data: { key: string; line: CliLine } }
  | { kind: "stale"; data: "state" | "public" | "listening" | "wifi" | "messages" | "all" }

/** One line of a repeater's command line, as sent from here or answered. */
export interface CliLine {
  id: number
  ts: number
  dir: "command" | "answer"
  status: "sending" | "sent" | "failed" | "received"
  text: string
}
export interface CliLog { key: string; lines: CliLine[] }
