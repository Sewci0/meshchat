// What the radio reports lives in TanStack Query. The WebSocket (live.ts) patches these caches
// in place, so components just read queries and re-render when the mesh changes.
import { useQuery, type QueryClient } from "@tanstack/react-query"
import { useDeferredValue, useEffect, useMemo, useState } from "react"
import { api } from "./api"
import { useLocal } from "./local"
import { buildNodes } from "./mesh"
import { analyse, repeaterDetail, repeaterList, type Analysis, type AnalysisInput } from "./repeaters"
import type { Packet, Person, PublicNode, RepeaterLive, Route } from "./types"

/** how much of the radio's packet log the browser loads for the repeater analysis (the radio keeps 3000) */
export const ANALYSIS_PACKETS = 3000

export const keys = {
  state: ["state"] as const,
  messages: (conv: string) => ["messages", conv] as const,
  packets: ["packets"] as const,
  publicNodes: ["public-nodes"] as const,
  people: ["people"] as const,
  analysisPackets: ["analysis-packets"] as const,
  routes: ["routes"] as const,
  repeaterLive: ["repeater-live"] as const,
  listening: ["listening"] as const,
  wifi: ["device-wifi"] as const,
  cli: (key: string) => ["cli", key] as const,
}

export const useAppState = () => useQuery({ queryKey: keys.state, queryFn: api.state, staleTime: Infinity })
export const useMessages = (conv: string | undefined) =>
  useQuery({ queryKey: keys.messages(conv ?? ""), queryFn: () => api.messages(conv!), enabled: !!conv, staleTime: Infinity })
/** Start loading a conversation's messages before it opens (a finger on its sidebar link): a tap's
 *  touch comes ~100 ms before its click. Cached conversations aren't fetched again. */
export const prefetchMessages = (qc: QueryClient, conv: string) =>
  qc.prefetchQuery({ queryKey: keys.messages(conv), queryFn: () => api.messages(conv), staleTime: Infinity })

/** The latest login/status answers from repeaters and rooms, by key (kept current by "live" events). */
export const useLive = () =>
  useQuery({ queryKey: keys.repeaterLive, queryFn: api.repeaterLive, staleTime: 60_000, retry: false })
export const usePackets = () => useQuery({ queryKey: keys.packets, queryFn: () => api.packets(), staleTime: Infinity })
export const usePublicNodes = () =>
  useQuery({ queryKey: keys.publicNodes, queryFn: api.publicNodes, staleTime: 10 * 60_000, refetchInterval: 10 * 60_000 })
export const usePeople = () =>
  useQuery({ queryKey: keys.people, queryFn: () => api.people(7), staleTime: Infinity, select: (rows: Person[]) => new Map(rows.map((p) => [p.name, p])) })

/** The radio's WiFi: status, hostname, saved networks (never passwords). Polls while shown. */
export const useDeviceWifi = (enabled: boolean, poll = true) =>
  useQuery({ queryKey: keys.wifi, queryFn: api.wifi, enabled, refetchInterval: poll ? 15_000 : false, retry: false })

/** Channels the radio listens to, asked for once the state has loaded. Counts change with every
 *  packet, so poll gently. */
export function useListening() {
  const { data: state } = useAppState()
  return useQuery({ queryKey: keys.listening, queryFn: api.listening, enabled: !!state,
    staleTime: 20_000, refetchInterval: 30_000 })
}

/** The radio's spreading factor (sets the decode limit); 6 until the state loads. */
export function useRadioSf() {
  const { data } = useAppState()
  return data?.self.radio.sf ?? 6
}

/** Contacts ∪ heard adverts ∪ public map, memoised on its inputs. */
export function useNodes() {
  const { data: state } = useAppState()
  const { data: pub } = usePublicNodes()
  return useMemo(() => buildNodes(state, pub?.nodes), [state, pub])
}

// ---------------------------------------------------------------- repeaters
// The radio keeps the data but has no room to analyse it, so the browser does: it loads the radio's
// packet log and channel routes once (after the state), live.ts keeps them current, and
// lib/repeaters.ts does the rest.

const EMPTY_PUBLIC: PublicNode[] = []
let memo: { inputs: unknown[]; days: number; out: Analysis } | null = null

function useAnalysis(days: number, on: boolean) {
  const { data: state } = useAppState()
  const enabled = on && !!state
  const packets = useQuery({ queryKey: keys.analysisPackets, queryFn: () => api.packets(ANALYSIS_PACKETS), enabled, staleTime: Infinity })
  const routes = useQuery({ queryKey: keys.routes, queryFn: api.routes, enabled, staleTime: Infinity })
  const live = useQuery({ queryKey: keys.repeaterLive, queryFn: api.repeaterLive, enabled, staleTime: Infinity })
  const { data: pub } = usePublicNodes()
  // packets arrive every few seconds; let React skip intermediate states while it's busy
  const pk = useDeferredValue(packets.data)
  const input = useMemo<AnalysisInput | null>(() => state && pk && routes.data ? {
    state, packets: pk as Packet[], routes: routes.data as Route[], publicNodes: pub?.nodes ?? EMPTY_PUBLIC,
    live: (live.data ?? {}) as Record<string, RepeaterLive>,
  } : null, [state, pk, routes.data, pub, live.data])
  const analysis = useMemo(() => {
    if (!input || !enabled) return null
    // the list and the detail pane share one pass over the packets
    const inputs = [input.state, input.packets, input.routes, input.publicNodes]
    if (memo && memo.days === days && memo.inputs.every((x, i) => x === inputs[i])) return memo.out
    const out = analyse(input, days)
    memo = { inputs, days, out }
    return out
  }, [input, days, enabled])
  return { input, analysis, isLoading: enabled && (packets.isLoading || routes.isLoading), error: packets.error ?? routes.error }
}

/** The period the Repeaters page shows, which the composer's warning follows too. */
export const useRepeaterDays = () => useLocal("repDays", 7)

/** true once `ms` have passed since mount */
function useAfter(ms: number) {
  const [done, setDone] = useState(ms <= 0)
  useEffect(() => {
    if (done) return
    const t = setTimeout(() => setDone(true), ms)
    return () => clearTimeout(t)
  }, [done, ms])
  return done
}

/** @param glance for a look from another page: starts a moment later, so that page loads first */
export function useRepeaters(days: number, { glance = false } = {}) {
  const ready = useAfter(glance ? 2500 : 0)
  const la = useAnalysis(days, ready)
  const data = useMemo(() => (la.analysis && la.input ? repeaterList(la.analysis, la.input, days) : undefined), [la.analysis, la.input, days])
  return { data, isLoading: la.isLoading, error: la.error }
}

export function useRepeater(key: string | undefined, days: number) {
  const la = useAnalysis(days, !!key)
  const data = useMemo(() => (key && la.analysis && la.input ? repeaterDetail(la.analysis, la.input, key) : undefined), [key, la.analysis, la.input])
  const missing = !la.isLoading && la.analysis && data === null
  return { data: data ?? undefined, isLoading: la.isLoading, error: missing ? new Error("unknown repeater") : la.error }
}

/** Your repeater, while it has gone quiet (so your messages may not get through), else null. */
export function useQuietRepeater() {
  const [days] = useRepeaterDays()
  const { data } = useRepeaters(days, { glance: true })
  return useMemo(() => {
    const q = data?.your_repeater_quiet, key = data?.your_repeater
    if (!q || !key) return null
    const r = data.repeaters.find((x) => x.key === key)
    return { key, name: r?.name ?? key.slice(0, 8), snr: r?.snr_median ?? null, quiet: q }
  }, [data])
}

/** The radio runs repeater queries and room logins in the background; wait for its answer. */
export async function waitForLive(key: string, before: RepeaterLive | undefined, onUpdate: (all: Record<string, RepeaterLive>) => void) {
  const deadline = Date.now() + 4 * 60_000
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 2000))
    const all = await api.repeaterLive().catch(() => null)
    if (!all) continue
    onUpdate(all)
    const l = all[key]
    if (l && !l.running && (!before || l.ts !== before.ts || l.error !== before.error)) return l
  }
  throw new Error("The radio didn't finish the query in time.")
}

