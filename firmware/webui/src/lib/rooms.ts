// Room servers. A room is a contact of type "room": a node that stores posts and pushes them to
// everyone logged in to it. Joining is a login (as a guest with no password, if the room allows
// that); the login tells the room the newest post you have, and it then sends you the newer ones,
// one at a time, and every new post as it arrives, for as long as your radio acknowledges them.
// Posts arrive like DMs from the room, signed with the first bytes of their author's key; your
// own posts are DMs to the room, and its ACK means it stored them. MeshCore has no "leave"
// message, so leaving here means MeshChat stops showing the room's posts.
import { api } from "./api"
import { dmConv } from "./routes"
import { keys, waitForLive } from "./queries"
import type { AppState, Contact, RepeaterLive, Room, RoomRole } from "./types"
import type { QueryClient } from "@tanstack/react-query"

export const roomKey = (conv: string) => (conv.startsWith("dm:") ? conv.slice(3) : null)

export function isRoomConv(state: AppState | undefined, conv: string) {
  const k = roomKey(conv)
  return !!k && state?.contacts[k]?.type === "room"
}

export const roomRecord = (state: AppState | undefined, key: string): Room | null =>
  state?.rooms?.find((r) => r.key === key) ?? null

export interface RoomEntry { key: string; name: string; conv: string; room: Room | null; last_ts: number; posts: number }

/** The rooms for the sidebar: joined here (and not left), or with posts and not left. */
export function roomList(state: AppState | undefined): RoomEntry[] {
  if (!state) return []
  const out = new Map<string, RoomEntry>()
  const add = (c: Contact) => {
    const conv = dmConv(c.pubkey), room = roomRecord(state, c.pubkey), cv = state.conversations[conv]
    out.set(c.pubkey, { key: c.pubkey, name: c.name, conv, room, last_ts: cv?.last_ts ?? room?.login_at ?? 0, posts: cv?.n ?? 0 })
  }
  for (const r of state.rooms ?? []) if (!r.left && state.contacts[r.key]) add(state.contacts[r.key])
  for (const cv of Object.values(state.conversations)) {
    const k = roomKey(cv.conv), c = k ? state.contacts[k] : undefined
    if (c?.type === "room" && !roomRecord(state, c.pubkey)?.left) add(c)
  }
  return [...out.values()].sort((a, b) => b.last_ts - a.last_ts)
}

/** What a role lets you do, in words, and whether you can post. */
export const ROLE_TEXT: Record<RoomRole, { label: string; can: string; post: boolean }> = {
  guest: { label: "Guest", can: "You can read the posts. Posting needs the room's password.", post: false },
  "read-only": { label: "Read only", can: "You can read the posts, not post.", post: false },
  "read-write": { label: "Member", can: "You can read and post.", post: true },
  admin: { label: "Admin", can: "You can read, post and manage the room.", post: true },
}

/** null: we don't know (older room firmware, or not joined from here): let them try. */
export const canPost = (room: Room | null) => !room?.role || ROLE_TEXT[room.role].post

/** Join (log in to) a room. The radio does it in the background and reports over the WebSocket;
 *  resolves with its answer. */
export async function joinRoom(qc: QueryClient, key: string, password: string): Promise<RepeaterLive> {
  const before = qc.getQueryData<Record<string, RepeaterLive>>(keys.repeaterLive)?.[key]
  await api.joinRoom(key, password)
  const live = await waitForLive(key, before, (all) => qc.setQueryData(keys.repeaterLive, all))
  await qc.invalidateQueries({ queryKey: keys.state })
  return live
}

/** The room's clock against ours when it answered, in seconds (positive: it's ahead). */
export const clockSkew = (l: RepeaterLive | null | undefined) =>
  l?.login?.server_time && l.ts ? l.login.server_time - l.ts : null
