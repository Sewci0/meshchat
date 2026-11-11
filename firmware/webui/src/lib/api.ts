// The radio's HTTP API (/api), as the MeshChat firmware implements it.
import type { AppState, CliLog, DeviceWifi, Listening, Message, MessageInfo, Packet, Person, PublicNodes, RepeaterLive, Route } from "./types"

export class ApiError extends Error {
  readonly status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(path, init)
  if (!res.ok) {
    const text = (await res.text()).trim()
    throw new ApiError(res.status, text || res.statusText)
  }
  return res.json() as Promise<T>
}

const post = <T,>(path: string, body: unknown) =>
  request<T>(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) })

export const api = {
  state: () => request<AppState>("/api/state"),
  messages: (conv: string) => request<Message[]>(`/api/messages?conv=${encodeURIComponent(conv)}`),
  packets: (limit?: number) => request<Packet[]>(limit ? `/api/packets?limit=${limit}` : "/api/packets"),
  publicNodes: () => request<PublicNodes>("/api/public-nodes"),
  /** channel messages with their routes, for the repeater analysis */
  routes: () => request<Route[]>("/api/routes"),
  /** the latest status/neighbour answers, by repeater key */
  repeaterLive: () => request<Record<string, RepeaterLive>>("/api/repeaters/live"),
  /** channels the radio listens to without joining, and the ones it can't read */
  listening: () => request<Listening>("/api/listening"),
  listen: (name: string) => post<{ ok: boolean; matched?: number }>("/api/listening", { name }),
  unlisten: (name: string) => post<{ ok: boolean }>("/api/listening", { name, remove: true }),
  /** switch network (radio settings), applied at once */
  setRadio: (r: { freq: number; bw: number; sf: number; cr: number }) => post<{ ok: boolean }>("/api/radio", r),
  /** log in to a repeater (as a guest with no password) and ask for its status and neighbours: 202 {started},
   *  the answer comes as a "live" event */
  startRepeaterQuery: (key: string, password: string | null) => post<{ started: boolean }>(`/api/repeaters/${key}/query`, { password: password ?? "" }),
  /** a repeater's command line (needs an admin login): what was sent from here, and its answers */
  cli: (key: string) => request<CliLog>(`/api/repeaters/${key}/cli`),
  runCommand: (key: string, command: string) => post<{ ok: boolean }>(`/api/repeaters/${key}/cli`, { command }),
  people: (days = 7) => request<Person[]>(`/api/people?days=${days}`),

  send: (conv: string, text: string) => post<Message>("/api/send", { conv, text }),
  resend: (id: number) => post<Message>(`/api/messages/${id}/resend`, {}),
  /** from MeshChat's history only: the other side keeps their copy */
  deleteMessage: (id: number) => request<{ ok: boolean }>(`/api/messages/${id}`, { method: "DELETE" }),
  deleteConversation: (conv: string) => request<{ ok: boolean; deleted: number }>(`/api/conversations/${encodeURIComponent(conv)}`, { method: "DELETE" }),
  advert: (flood: boolean) => post<{ ok: boolean }>("/api/advert", { flood }),
  rename: (name: string) => post<AppState>("/api/name", { name }),
  joinChannel: (name: string, secret: string | null) => post<AppState>("/api/channels", { name, secret }),
  /** forget the saved route to a contact: the next message floods and learns a fresh one */
  resetPath: (key: string) => post<{ ok: boolean }>(`/api/contacts/${key}/reset-path`, {}),
  messageInfo: (id: number) => request<MessageInfo>(`/api/message-info?id=${id}`),
  /** from a QR code or meshcore:// link; one that's already a contact is left as it is */
  addContact: (c: { public_key: string; name: string; type: number }) => post<{ added?: boolean; exists?: boolean }>("/api/contacts", c),
  leaveChannel: (idx: number) => request<AppState>(`/api/channels/${idx}`, { method: "DELETE" }),
  setHome: (lat: number, lon: number, label?: string) => post<AppState["home"]>("/api/home", { lat, lon, label }),
  wifi: () => request<DeviceWifi>("/api/device/wifi"),
  setHostname: (hostname: string) => post<DeviceWifi>("/api/device/wifi/hostname", { hostname }),
  /** add or update a saved network (empty password keeps the saved one); connect: prefer it and restart now */
  addWifi: (ssid: string, password: string, connect: boolean) => post<{ ok: boolean; rebooting?: boolean }>("/api/device/wifi/networks", { ssid, password, connect }),
  removeWifi: (ssid: string) => post<{ ok: boolean }>("/api/device/wifi/networks/remove", { ssid }),
  preferWifi: (ssid: string) => post<{ ok: boolean }>("/api/device/wifi/networks/prefer", { ssid }),
  openWifiSetup: () => post<{ ok: boolean }>("/api/device/wifi/setup", {}),
  setBlePin: (pin: string) => post<{ ok: boolean; note?: string }>("/api/device/ble-pin", { pin }),
  rebootRadio: () => post<{ ok: boolean }>("/api/device/reboot", {}),
  syncTime: () => post<{ ok: boolean }>("/api/time", { now: Math.floor(Date.now() / 1000) }),
  /** 202 {started}: the answer comes as a "live" event */
  joinRoom: (key: string, password: string) => post<{ started: true }>(`/api/rooms/${key}/join`, { password }),
  leaveRoom: (key: string) => post<{ ok: boolean }>(`/api/rooms/${key}/leave`, {}),
}
