import { Page } from "@/components/page"
import { useActions } from "@/components/app-provider"
import { Hint } from "@/components/hint"
import { NodeAvatar, SignalBars, TypeBadge } from "@/components/mesh-bits"
import { Button } from "@/components/ui/button"
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty"
import { Input } from "@/components/ui/input"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { useLocal } from "@/lib/local"
import { ago, fold, hasLoc, km, plural } from "@/lib/mesh"
import { useAppState, useNodes } from "@/lib/queries"
import type { MeshNode } from "@/lib/types"
import { convPath, dmConv } from "@/lib/routes"
import { ArrowDownIcon, InfoIcon, MapPinIcon, MessageCircleIcon, NetworkIcon, RadioTowerIcon, SearchIcon } from "lucide-react"
import { useMemo, useState } from "react"
import { useNavigate } from "react-router"

type SortKey = "heard" | "name" | "distance" | "hops"

export function NodesPage() {
  const { data: state } = useAppState()
  const nodes = useNodes()
  const { showOnMap } = useActions()
  const navigate = useNavigate()
  const [q, setQ] = useState("")
  const [type, setType] = useLocal("nodesType", "all")
  const [sort, setSort] = useLocal<SortKey>("nodesSort", "heard")
  const home = state?.home

  const rows = useMemo(() => {
    // a node's advert time is by its own clock: one in the future (a wrong clock) mustn't sort first
    const now = Date.now() / 1000
    const seen = (n: MeshNode) => n.heard?.last_heard ?? (n.last_advert && n.last_advert <= now + 300 ? n.last_advert : 0)
    const dist = (n: MeshNode) => (home && hasLoc(n) ? km(home, { lat: n.lat!, lon: n.lon! }) : Infinity)
    const hops = (n: MeshNode) => n.heard?.hops ?? (n.out_path_len != null && n.out_path_len >= 0 ? n.out_path_len : 99)
    const list = [...nodes.values()].filter((n) => (n.heard || n.contact) && (type === "all" || n.type === type) && (!q || fold(n.name).includes(fold(q))))
    const cmp: Record<SortKey, (a: MeshNode, b: MeshNode) => number> = {
      heard: (a, b) => seen(b) - seen(a), name: (a, b) => a.name.localeCompare(b.name),
      distance: (a, b) => dist(a) - dist(b), hops: (a, b) => hops(a) - hops(b),
    }
    return list.sort(cmp[sort])
  }, [nodes, type, q, sort, home])

  const header = (key: SortKey, label: string, className?: string) => (
    <TableHead className={className} aria-sort={sort === key ? (key === "heard" ? "descending" : "ascending") : "none"}>
      <button onClick={() => setSort(key)} className="inline-flex items-center gap-1 rounded font-medium hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">
        {label}{sort === key ? <ArrowDownIcon className="size-3" /> : null}
      </button>
    </TableHead>
  )

  return (
    <Page title="Nodes" description={`${plural(rows.length, "node", "nodes")} your radio has heard or added as contacts`}>
      <div className="flex flex-wrap items-center gap-2 border-b px-3 py-2 sm:px-4">
        <div className="relative w-full sm:w-64">
          <SearchIcon className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search by name" aria-label="Search nodes" className="pl-8" />
        </div>
        <ToggleGroup type="single" value={type} onValueChange={(v) => v && setType(v)} variant="outline" size="sm" aria-label="Node type">
          <ToggleGroupItem value="all">All</ToggleGroupItem>
          <ToggleGroupItem value="companion">People</ToggleGroupItem>
          <ToggleGroupItem value="repeater">Repeaters</ToggleGroupItem>
          <ToggleGroupItem value="room">Rooms</ToggleGroupItem>
        </ToggleGroup>
      </div>
      <div className="min-h-0 flex-1 overflow-auto">
        {rows.length ? (
          <Table>
            <TableHeader className="sticky top-0 z-10 bg-background">
              <TableRow>
                {header("name", "Name", "pl-4")}
                <TableHead className="hidden sm:table-cell">Type</TableHead>
                {header("hops", "Hops", "hidden sm:table-cell")}
                <TableHead>
                  <span className="inline-flex items-center gap-1"><span className="sm:hidden">Signal</span><span className="hidden sm:inline">Last-hop signal</span>
                    <Hint content="The node itself if you heard it directly, otherwise the repeater that relayed it to you.">
                      <button type="button" aria-label="About last-hop signal" className="rounded-full text-muted-foreground hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">
                        <InfoIcon className="size-3.5" />
                      </button>
                    </Hint>
                  </span>
                </TableHead>
                {header("distance", "Distance", "hidden sm:table-cell")}
                {header("heard", "Last heard", "hidden sm:table-cell")}
                <TableHead className="pr-4 text-right"><span className="sr-only">Actions</span></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((n) => {
                const hops = n.heard?.hops ?? (n.out_path_len != null && n.out_path_len >= 0 ? n.out_path_len : null)
                return (
                  <TableRow key={n.pubkey}>
                    <TableCell className="max-w-[55vw] pl-4 sm:max-w-64">
                      <span className="flex items-center gap-2"><NodeAvatar name={n.name} className="size-6" />
                        <span className="grid min-w-0">
                          <span className="truncate font-medium">{n.name}</span>
                          {/* phones: what the hidden columns say */}
                          <span className="truncate text-xs text-muted-foreground sm:hidden">
                            {[n.type, hops == null ? null : hops === 0 ? "direct" : `${hops} hops`, home && hasLoc(n) ? `${km(home, { lat: n.lat!, lon: n.lon! }).toFixed(0)} km` : null,
                              n.heard ? ago(n.heard.last_heard) : null].filter(Boolean).join(" · ")}
                          </span>
                        </span>
                      </span>
                    </TableCell>
                    <TableCell className="hidden sm:table-cell"><TypeBadge type={n.type} /></TableCell>
                    <TableCell className="hidden tabular-nums sm:table-cell">{hops == null ? "—" : hops === 0 ? "direct" : hops}</TableCell>
                    <TableCell className="tabular-nums">{n.heard?.snr != null ? <span className="inline-flex items-center gap-1.5"><SignalBars snr={n.heard.snr} />{n.heard.snr} dB</span> : "—"}</TableCell>
                    <TableCell className="hidden tabular-nums sm:table-cell">{home && hasLoc(n) ? `${km(home, { lat: n.lat!, lon: n.lon! }).toFixed(1)} km` : "—"}</TableCell>
                    <TableCell className="hidden text-muted-foreground sm:table-cell">{n.heard ? ago(n.heard.last_heard) : `advert ${ago(n.last_advert)}`}</TableCell>
                    <TableCell className="pr-4 text-right whitespace-nowrap">
                      {n.contact && n.type === "companion" ? <Button size="icon-sm" variant="ghost" aria-label={`Message ${n.name}`} onClick={() => navigate(convPath(dmConv(n.pubkey)))}><MessageCircleIcon /></Button> : null}
                      {n.type === "repeater" || n.type === "room" ? <Button size="icon-sm" variant="ghost" aria-label={`${n.name} details`} onClick={() => navigate(`/repeaters/${n.pubkey}`)}><RadioTowerIcon /></Button> : null}
                      {hasLoc(n) ? <Button size="icon-sm" variant="ghost" aria-label={`Show ${n.name} on map`} onClick={() => showOnMap({ kind: "point", lat: n.lat!, lon: n.lon!, label: n.name })}><MapPinIcon /></Button> : null}
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        ) : (
          <Empty className="h-full"><EmptyHeader><EmptyMedia variant="icon"><NetworkIcon /></EmptyMedia>
            <EmptyTitle>{q || type !== "all" ? "Nothing matches" : "Nothing heard yet"}</EmptyTitle>
            <EmptyDescription>{q || type !== "all" ? "Try another search or type." : "Nodes appear as your radio hears their adverts."}</EmptyDescription></EmptyHeader></Empty>
        )}
      </div>
    </Page>
  )
}
