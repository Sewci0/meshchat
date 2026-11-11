// meshcore:// links, as the MeshCore apps put them in QR codes (docs.meshcore.io/qr_codes):
//   meshcore://contact/add?name=Example+Contact&public_key=<64 hex>&type=1   (1 companion, 2 repeater, 3 room, 4 sensor)
//   meshcore://channel/add?name=Public&secret=<32 hex>
export type ContactType = 1 | 2 | 3 | 4
export type MeshLink =
  | { kind: "contact"; name: string; publicKey: string; type: ContactType }
  | { kind: "channel"; name: string; secret: string }

export const CONTACT_TYPE_NAME: Record<ContactType, string> = { 1: "companion", 2: "repeater", 3: "room server", 4: "sensor" }

const HEX = (n: number) => new RegExp(`^[0-9a-f]{${n}}$`)

/** The radio keeps names in 32 bytes (31 and a terminator): cut on a whole UTF-8 character. */
export function fitName(name: string, bytes = 31) {
  const enc = new TextEncoder()
  let out = ""
  for (const ch of name.trim()) {
    if (enc.encode(out + ch).length > bytes) break
    out += ch
  }
  return out
}

/** A meshcore:// contact or channel link, or null if the text isn't one we can use. */
export function parseMeshLink(text: string): MeshLink | null {
  const m = /^meshcore:\/\/(contact|channel)\/add\?(.*)$/i.exec(text.trim())
  if (!m) return null
  const q = new URLSearchParams(m[2])   // decodes %xx and "+" for spaces, as the apps write them
  const name = fitName(q.get("name") ?? "")
  if (m[1].toLowerCase() === "contact") {
    const publicKey = (q.get("public_key") ?? "").toLowerCase()
    const type = Number(q.get("type") ?? 1)
    if (!HEX(64).test(publicKey) || ![1, 2, 3, 4].includes(type)) return null
    return { kind: "contact", name: name || publicKey.slice(0, 8), publicKey, type: type as ContactType }
  }
  const secret = (q.get("secret") ?? "").toLowerCase()
  if (!name || !HEX(32).test(secret)) return null
  return { kind: "channel", name, secret }
}

/** The link the MeshCore apps scan to add this contact. */
export function contactLink(name: string, publicKey: string, type: ContactType = 1) {
  return `meshcore://contact/add?${new URLSearchParams({ name, public_key: publicKey, type: String(type) })}`
}

/** "f5032d01…080c2dbc", the way the MeshCore app shows a key */
export const shortKey = (k: string) => `${k.slice(0, 8)}…${k.slice(-8)}`
