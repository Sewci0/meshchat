// One WebSocket per tab, to the radio's /ws. Its events are applied to the query cache, so every
// screen updates without polling. Reconnects with backoff and resyncs state on reconnect.
import { useQueryClient, type QueryClient } from "@tanstack/react-query"
import { useEffect, useSyncExternalStore } from "react"
import { ANALYSIS_PACKETS, keys } from "./queries"
import type { AppState, CliLog, LiveEvent, Message, Packet, Person, RepeaterLive, Route } from "./types"

type Status = "connecting" | "open" | "closed"
let status: Status = "connecting"
const listeners = new Set<() => void>()
const setStatus = (s: Status) => { status = s; listeners.forEach((l) => l()) }
export const useSocketStatus = () =>
  useSyncExternalStore((l) => { listeners.add(l); return () => listeners.delete(l) }, () => status)

function applyMessage(qc: QueryClient, m: Message) {
  qc.setQueryData<Message[]>(keys.messages(m.conv), (old) => {
    if (!old) return old
    const i = old.findIndex((x) => x.id === m.id)
    if (i >= 0) { const next = old.slice(); next[i] = m; return next }
    return [...old, m]
  })
  qc.setQueryData<AppState>(keys.state, (s) => {
    if (!s) return s
    const c = s.conversations[m.conv]
    return { ...s, conversations: { ...s.conversations, [m.conv]: { conv: m.conv, n: (c?.n ?? 0) + (c && c.last_id >= m.id ? 0 : 1),
      last_id: Math.max(c?.last_id ?? 0, m.id), last_ts: Math.max(c?.last_ts ?? 0, m.ts) } } }
  })
  // for the repeater analysis: who sent through which repeater, and which repeaters passed on yours
  if (!m.conv.startsWith("dm:") && m.sender && m.path) {
    const r: Route = { id: m.id, ts: m.ts, sender: m.sender, path: m.path, hash_size: m.hash_size, out: m.direction === "out" }
    qc.setQueryData<Route[]>(keys.routes, (old) => (old ? [...old.filter((x) => x.id !== m.id), r] : old))
  }
  if (m.direction === "in" && m.conv.startsWith("chan:") && m.sender) {
    qc.setQueryData<Person[]>(keys.people, (rows) => {
      if (!rows) return rows
      const prev = rows.find((p) => p.name === m.sender)
      const p: Person = { name: m.sender!, n: (prev?.n ?? 0) + 1, convs: prev?.convs.includes(m.conv) ? prev.convs : [...(prev?.convs ?? []), m.conv],
        last_ts: m.ts, last_conv: m.conv, path: m.path ?? prev?.path ?? null, hash_size: m.path != null ? m.hash_size : prev?.hash_size,
        hops: m.path != null ? m.hops : prev?.hops ?? null }
      return [...rows.filter((x) => x.name !== m.sender), p]
    })
  }
}

function apply(qc: QueryClient, ev: LiveEvent) {
  switch (ev.kind) {
    case "message": applyMessage(qc, ev.data); break
    case "packet":
      qc.setQueryData<Packet[]>(keys.packets, (old) => (old ? [ev.data, ...old].slice(0, 2000) : old))
      qc.setQueryData<Packet[]>(keys.analysisPackets, (old) => (old ? [ev.data, ...old].slice(0, ANALYSIS_PACKETS) : old))
      break
    case "heard": {
      const h = ev.data
      qc.setQueryData<AppState>(keys.state, (s) => (s ? { ...s, heard: { ...s.heard, [h.pubkey]: h } } : s))
      break
    }
    case "cli": {   // a command sent to a repeater, its progress, or the repeater's answer
      const { key, line } = ev.data
      qc.setQueryData<CliLog>(keys.cli(key), (old) => {
        const lines = (old?.lines ?? []).filter((l) => l.id !== line.id)
        return { key, lines: [...lines, line].sort((a, b) => a.id - b.id).slice(-40) }
      })
      break
    }
    case "live": {   // a repeater query's or room login's progress
      const l = ev.data
      if (l.key) qc.setQueryData<Record<string, RepeaterLive>>(keys.repeaterLive, (old) => ({ ...old, [l.key!]: l }))
      break
    }
    case "stale":   // something changed on the radio: refetch what depends on it
      if (ev.data === "all") { qc.invalidateQueries(); break }   // switched network: every view changes
      if (ev.data === "messages") {   // deleted: conversations, their lists and what's derived from them
        for (const k of [["messages"], keys.state, keys.people, keys.routes]) qc.invalidateQueries({ queryKey: k })
        break
      }
      qc.invalidateQueries({ queryKey: { public: keys.publicNodes, listening: keys.listening, wifi: keys.wifi, state: keys.state }[ev.data] })
      break
  }
}

export function useLiveUpdates() {
  const qc = useQueryClient()
  useEffect(() => {
    let ws: WebSocket | null = null, delay = 1000, stopped = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const connect = () => {
      setStatus("connecting")
      ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`)
      ws.onopen = () => {
        delay = 1000
        setStatus("open")
        // we may have missed events while disconnected
        qc.invalidateQueries({ queryKey: keys.state })
        qc.invalidateQueries({ queryKey: ["messages"] })
        qc.invalidateQueries({ queryKey: keys.packets })
        qc.invalidateQueries({ queryKey: keys.analysisPackets })
        qc.invalidateQueries({ queryKey: keys.routes })
      }
      ws.onmessage = (e) => apply(qc, JSON.parse(e.data) as LiveEvent)
      ws.onclose = () => {
        setStatus("closed")
        if (!stopped) timer = setTimeout(connect, delay)
        delay = Math.min(delay * 2, 15_000)
      }
    }
    connect()

    // Phones freeze a backgrounded app (above all a home-screen app on iOS) and its socket dies,
    // sometimes still claiming to be open. On return, reconnect at once instead of waiting for
    // the backoff; onopen then refreshes everything that may have been missed.
    let hiddenAt = 0
    const resume = () => {
      if (document.visibilityState === "hidden") { hiddenAt = Date.now(); return }
      const stale = hiddenAt && Date.now() - hiddenAt > 10_000
      hiddenAt = 0
      if (!stale && ws?.readyState === WebSocket.OPEN) return
      clearTimeout(timer)
      delay = 1000
      if (ws) { ws.onclose = null; ws.close() }
      connect()
    }
    document.addEventListener("visibilitychange", resume)
    window.addEventListener("online", resume)
    return () => {
      stopped = true; clearTimeout(timer); ws?.close()
      document.removeEventListener("visibilitychange", resume)
      window.removeEventListener("online", resume)
    }
  }, [qc])
}
