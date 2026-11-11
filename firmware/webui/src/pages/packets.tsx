import { Page } from "@/components/page"
import { SignalBars, Stat } from "@/components/mesh-bits"
import { Badge } from "@/components/ui/badge"
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty"
import { Label } from "@/components/ui/label"
import { Switch } from "@/components/ui/switch"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { hopLabel, resolveHop, snrFloor, splitPath } from "@/lib/mesh"
import { useAppState, useNodes, usePackets, useRadioSf } from "@/lib/queries"
import type { Packet, PacketInfo } from "@/lib/types"
import { ScrollTextIcon } from "lucide-react"
import { useEffect, useMemo, useState } from "react"

const TYPE_TONE: Record<string, string> = {
  GRP_TXT: "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300",
  TXT_MSG: "bg-sky-500/10 text-sky-700 dark:text-sky-300",
  ADVERT: "bg-violet-500/10 text-violet-700 dark:text-violet-300",
}

export function PacketsPage() {
  const sf = useRadioSf()
  const { data: packets } = usePackets()
  const { data: state } = useAppState()
  const nodes = useNodes()
  // pausing freezes the list you're reading; live data keeps arriving underneath
  const [frozen, setFrozen] = useState<Packet[] | null>(null)
  const paused = frozen !== null
  const setPaused = (on: boolean) => setFrozen(on ? packets ?? [] : null)
  const [, tick] = useState(0)
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 30_000); return () => clearInterval(t) }, [])

  const shown = (frozen ?? packets ?? []).slice(0, 300)
  const stats = useMemo(() => {
    const now = Date.now() / 1000, recent = (packets ?? []).filter((p) => now - p.ts < 600)
    const snrs = recent.map((p) => p.snr).filter((x): x is number => x != null).sort((a, b) => a - b)
    const types = new Map<string, number>()
    recent.forEach((p) => types.set(p.type, (types.get(p.type) ?? 0) + 1))
    return { count: recent.length, median: snrs.length ? snrs[Math.floor(snrs.length / 2)] : null,
      chat: (types.get("GRP_TXT") ?? 0) + (types.get("TXT_MSG") ?? 0), adverts: types.get("ADVERT") ?? 0 }
  }, [packets])
  const newer = frozen && packets ? packets.length - frozen.length : 0

  return (
    <Page title="Packets" description="Everything your radio decodes, live" actions={
      <div className="flex items-center gap-2">
        <Switch id="pause" checked={paused} onCheckedChange={setPaused} />
        <Label htmlFor="pause" className="text-sm font-normal">Pause{newer > 0 ? ` (${newer} new)` : ""}</Label>
      </div>
    }>
      <div className="grid grid-cols-2 gap-3 border-b p-3 sm:grid-cols-4 sm:px-4">
        <Stat value={stats.count} label="packets, last 10 min" />
        <Stat value={stats.median != null ? `${stats.median} dB` : "—"} label="median SNR" hint={`decodes down to about ${snrFloor(sf)} dB at SF${sf}`} />
        <Stat value={stats.chat} label="messages" hint="channel + direct" />
        <Stat value={stats.adverts} label="adverts" />
      </div>
      <div className="min-h-0 flex-1 overflow-auto">
        {shown.length ? (
          <Table>
            <TableHeader className="sticky top-0 z-10 bg-background">
              <TableRow>
                <TableHead className="pl-4">Time</TableHead><TableHead>Type</TableHead><TableHead className="hidden md:table-cell">Route</TableHead>
                <TableHead className="hidden sm:table-cell">Hops</TableHead><TableHead className="hidden sm:table-cell">Via</TableHead><TableHead>SNR</TableHead>
                <TableHead className="hidden md:table-cell">RSSI</TableHead><TableHead className="pr-4">Info</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {shown.map((p, i) => {
                const info = parseInfo(p.info)
                const hops = splitPath(p.path, p.hash_size), last = hops.at(-1)
                const via = last ? hopLabel(resolveHop(last, state?.home ?? null, nodes), last) : "direct"
                return (
                  <TableRow key={p.id ?? `${p.ts}-${i}`}>
                    <TableCell className="pl-4 tabular-nums text-muted-foreground">{new Date(p.ts * 1000).toLocaleTimeString()}</TableCell>
                    <TableCell><Badge variant="secondary" className={TYPE_TONE[p.type] ?? ""}>{p.type}</Badge></TableCell>
                    <TableCell className="hidden text-muted-foreground md:table-cell">{p.route.toLowerCase().replace("_", " ")}</TableCell>
                    <TableCell className="hidden tabular-nums sm:table-cell">{p.hops ?? "—"}</TableCell>
                    <TableCell className="hidden max-w-48 truncate sm:table-cell">{via}</TableCell>
                    <TableCell className="tabular-nums">{p.snr != null ? <span className="inline-flex items-center gap-1.5"><SignalBars snr={p.snr} />{p.snr}</span> : "—"}</TableCell>
                    <TableCell className="hidden tabular-nums md:table-cell">{p.rssi ?? "—"}</TableCell>
                    <TableCell className="max-w-[30vw] truncate pr-4 text-muted-foreground sm:max-w-64">
                      {info.name ? `${info.name} (${info.node_type ?? "?"})` : info.channel ? `channel ${info.channel}` : info.channel_hash ? `private channel ${info.channel_hash}` : ""}
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        ) : (
          <Empty className="h-full"><EmptyHeader><EmptyMedia variant="icon"><ScrollTextIcon /></EmptyMedia>
            <EmptyTitle>No packets yet</EmptyTitle><EmptyDescription>They appear here the moment your radio decodes one.</EmptyDescription></EmptyHeader></Empty>
        )}
      </div>
    </Page>
  )
}

function parseInfo(raw: string): PacketInfo {
  try { return JSON.parse(raw || "{}") as PacketInfo } catch { return {} }
}
