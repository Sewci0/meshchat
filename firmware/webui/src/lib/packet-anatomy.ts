// A MeshCore packet, byte by byte, for the message Details view:
//   header (route type, payload type, version) · transport codes (TRANSPORT_* routes only, 4 bytes)
//   · path length (ID size, hops) · path (repeater IDs) · payload
// Payloads we can label: GRP_TXT (channel hash, MAC, ciphertext) and TXT_MSG (to, from, MAC, ciphertext).
export const ROUTE_TYPES = ["transport flood", "flood", "direct", "transport direct"] as const
export const PAYLOAD_TYPES = ["REQ", "RESPONSE", "TXT_MSG", "ACK", "ADVERT", "GRP_TXT", "GRP_DATA", "ANON_REQ",
  "PATH", "TRACE", "MULTIPART", "CONTROL", "type 12", "type 13", "type 14", "RAW_CUSTOM"] as const

/** MeshCore's limits (src/MeshCore.h): a whole packet, its payload, and the path field */
export const MAX_PACKET = 255, MAX_PAYLOAD = 184, MAX_PATH = 64

export type Part = "header" | "transport" | "path" | "address" | "mac" | "cipher" | "payload"
export interface PacketField {
  label: string
  hex: string
  /** what the bytes mean */
  note: string
  /** which part of the packet: colours its swatch and its share of the size bar */
  part: Part
}

export interface Anatomy {
  fields: PacketField[]
  /** byte 0: 2 bits version, 4 bits payload type, 2 bits route type */
  header: { byte: number; ver: number; type: number; route: number }
  /** the path length byte: 2 bits ID size (0 = 1 byte, 1 = 2, 2 = 3), 6 bits hop count */
  pathLen: { byte: number; hops: number; size: number; maxHops: number } | null
  /** each repeater ID in the path, first to last */
  hops: string[]
  total: number
  /** header, transport codes, path length and path: what the routing costs */
  routing: number
  payload: number
  /** the ciphertext, for the plaintext layout */
  cipher: number
}

const hexOf = (b: Uint8Array, from: number, to: number) => Array.from(b.slice(from, to), (x) => x.toString(16).padStart(2, "0")).join("")
const blocks = (n: number) => `${n / 16} ${n === 16 ? "block" : "blocks"}`

export function analysePacket(raw: string): Anatomy | null {
  const b = new Uint8Array((raw.match(/../g) ?? []).map((h) => parseInt(h, 16)))
  if (b.length < 2) return null
  const fields: PacketField[] = []
  const route = b[0] & 3, type = (b[0] >> 2) & 15, ver = b[0] >> 6
  fields.push({ label: "Header", hex: hexOf(b, 0, 1), note: `${ROUTE_TYPES[route]} route · ${PAYLOAD_TYPES[type]} · version ${ver + 1}`, part: "header" })
  let i = 1
  if (route === 0 || route === 3) {
    fields.push({ label: "Transport codes", hex: hexOf(b, i, i + 4), note: "region scope: which areas' repeaters may pass it on", part: "transport" })
    i += 4
  }
  let pathLen: Anatomy["pathLen"] = null
  const hops: string[] = []
  if (i < b.length) {
    const pl = b[i], n = pl & 63, size = (pl >> 6) + 1
    pathLen = { byte: pl, hops: n, size, maxHops: Math.floor(MAX_PATH / size) }
    fields.push({ label: "Path length", hex: hexOf(b, i, i + 1), note: `${n} ${n === 1 ? "hop" : "hops"} × ${size}-byte repeater IDs`, part: "header" })
    i += 1
    if (n) {
      fields.push({ label: "Path", hex: hexOf(b, i, i + n * size), note: "the repeaters it passed, first to last", part: "path" })
      for (let k = 0; k < n; k++) hops.push(hexOf(b, i + k * size, i + (k + 1) * size))
      i += n * size
    }
  }
  const routing = i, pay = b.length - i
  let cipher = 0
  if (type === 5 && pay >= 3) {
    cipher = pay - 3
    fields.push({ label: "Channel ID", hex: hexOf(b, i, i + 1), note: "first byte of SHA-256 of the channel key", part: "address" })
    fields.push({ label: "MAC", hex: hexOf(b, i + 1, i + 3), note: "HMAC-SHA256, 2 bytes: proves the key is right", part: "mac" })
    fields.push({ label: "Ciphertext", hex: hexOf(b, i + 3, b.length), note: `AES-128, ${blocks(cipher)}`, part: "cipher" })
  } else if (type === 2 && pay >= 4) {
    cipher = pay - 4
    fields.push({ label: "To", hex: hexOf(b, i, i + 1), note: "first byte of the recipient's key", part: "address" })
    fields.push({ label: "From", hex: hexOf(b, i + 1, i + 2), note: "first byte of the sender's key", part: "address" })
    fields.push({ label: "MAC", hex: hexOf(b, i + 2, i + 4), note: "HMAC-SHA256, 2 bytes, with your shared secret", part: "mac" })
    fields.push({ label: "Ciphertext", hex: hexOf(b, i + 4, b.length), note: `AES-128, ${blocks(cipher)}`, part: "cipher" })
  } else if (pay) {
    fields.push({ label: "Payload", hex: hexOf(b, i, b.length), note: `${pay} bytes`, part: "payload" })
  }
  return { fields, header: { byte: b[0], ver, type, route }, pathLen, hops, total: b.length, routing, payload: pay, cipher }
}

/** Kept for callers that only want the field list */
export const packetAnatomy = (raw: string) => analysePacket(raw)?.fields ?? []

/** Time on air (ms) of a LoRa packet of `len` bytes, as RadioLib works it out for the SX126x and
 *  with MeshCore's preamble (32 symbols at SF8 and below, else 16), explicit header and CRC on. */
export function airtimeMs(len: number, sf: number, bwKhz: number, cr: number) {
  const tsym = (2 ** sf) / bwKhz                       // ms per symbol
  const preamble = sf <= 8 ? 32 : 16
  const low = sf <= 6                                   // SX126x SF5/6: 6.25 symbols of sync, no +8 bits
  const ldro = tsym > 16                                // low data rate optimisation
  const bits = 8 * len + 16 - 4 * sf + (low ? 0 : 8) + 20
  const symbols = Math.max(0, Math.ceil(bits / (4 * (ldro ? sf - 2 : sf)))) * cr
  return (preamble + 8 + (low ? 6.25 : 4.25) + symbols) * tsym
}

/** The sender's flags byte: message kind (low bits are the attempt number) */
export const TXT_TYPES = ["plain text", "CLI command", "signed (room server post)"]

/** "0101" style groups of a byte's bits, high bit first */
export const bitsOf = (byte: number, groups: number[]) => {
  const s = byte.toString(2).padStart(8, "0"), out: string[] = []
  let i = 0
  for (const g of groups) { out.push(s.slice(i, i + g)); i += g }
  return out
}
