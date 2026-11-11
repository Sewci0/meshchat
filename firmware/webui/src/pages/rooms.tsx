// Room servers your radio has learnt over the mesh: its room contacts (added when their adverts arrived)
// and room adverts it has heard since it started. Nothing here comes from the internet, so it works
// offline, and every room listed is on your radio settings (the radio can't decode anything else).
// MeshCore can't search for rooms: room servers don't answer node discovery, so they appear when their
// adverts reach you, usually a few times a day. Shows where each is, how its advert reached you, the
// route to it, whether you've joined and what's been posted; join from here.
import { Page } from "@/components/page"
import { useActions } from "@/components/app-provider"
import { Hint } from "@/components/hint"
import { SignalBars } from "@/components/mesh-bits"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty"
import { Input } from "@/components/ui/input"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { api } from "@/lib/api"
import { useLocal } from "@/lib/local"
import { ago, bearing, fold, hasLoc, km, plural } from "@/lib/mesh"
import { keys, useAppState } from "@/lib/queries"
import { roomRecord, ROLE_TEXT } from "@/lib/rooms"
import { convPath, dmConv } from "@/lib/routes"
import type { AppState, Contact, Heard, Room } from "@/lib/types"
import { useAsync } from "@/lib/use-async"
import { cn } from "@/lib/utils"
import { useQueryClient } from "@tanstack/react-query"
import { ArrowDownIcon, InfoIcon, LogInIcon, MapPinIcon, MessagesSquareIcon, PlusIcon, SearchIcon, UsersRoundIcon } from "lucide-react"
import { useMemo, useState } from "react"
import { useNavigate } from "react-router"

type SortKey = "heard" | "name" | "distance" | "posts"
type Show = "all" | "joined"

interface Row {
  key: string
  name: string
  /** a contact on the radio (heard adverts of rooms that aren't contacts can be added) */
  contact: Contact | null
  /** its advert, heard since the radio started: how it reached you */
  heard: Heard | null
  loc: { lat: number; lon: number } | null
  room: Room | null
  /** joined here (and not left), or posts arriving from it */
  member: boolean
  posts: number
  lastPost: number
  dist: number | null
  /** when its last advert reached you: our clock if heard since the radio started, else its own */
  advert: number
}

const HEARD_ROOM = 3   // advert node type

/** Where you stand with a room, in a word or two */
function standing(r: Row) {
  if (r.room?.left) return { label: "left", cls: "text-muted-foreground" }
  if (r.room) return { label: r.room.role ? ROLE_TEXT[r.room.role].label : "joined", cls: "text-emerald-700 dark:text-emerald-400" }
  if (r.member) return { label: "member", cls: "text-emerald-700 dark:text-emerald-400" }
  if (!r.contact) return { label: "not a contact", cls: "text-muted-foreground" }
  return { label: "not joined", cls: "text-muted-foreground" }
}

/** The rooms the radio knows from the mesh: room contacts, plus room adverts heard that aren't contacts */
function meshRooms(state: AppState | undefined): Row[] {
  if (!state) return []
  const home = state.home
  const out = new Map<string, Row>()
  const add = (key: string, name: string, contact: Contact | null, heard: Heard | null) => {
    const loc = hasLoc(contact) ? { lat: contact!.lat!, lon: contact!.lon! } : hasLoc(heard) ? { lat: heard!.lat!, lon: heard!.lon! } : null
    const room = roomRecord(state, key), cv = state.conversations[dmConv(key)]
    out.set(key, {
      key, name, contact, heard, loc, room, posts: cv?.n ?? 0, lastPost: cv?.last_ts ?? 0,
      member: (!!room && !room.left) || (!room?.left && !!cv?.n),
      dist: home && loc ? km(home, loc) : null,
      advert: heard?.last_heard ?? contact?.last_advert ?? 0,
    })
  }
  for (const c of Object.values(state.contacts)) if (c.type === "room") add(c.pubkey, c.name, c, state.heard[c.pubkey] ?? null)
  for (const h of Object.values(state.heard)) if (h.type === HEARD_ROOM && !out.has(h.pubkey)) add(h.pubkey, h.name || h.pubkey.slice(0, 8), null, h)
  return [...out.values()]
}

export function RoomsPage() {
  const { data: state } = useAppState()
  const { showOnMap, joinRoom } = useActions()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { run, busy } = useAsync()
  const [q, setQ] = useState("")
  const [show, setShow] = useLocal<Show>("roomsShow", "all")
  const [sort, setSort] = useLocal<SortKey>("roomsSort", "distance")
  const home = state?.home

  const all = useMemo(() => meshRooms(state), [state])
  const rows = useMemo(() => {
    const keep = (r: Row) => (show !== "joined" || r.member) && (!q || fold(r.name).includes(fold(q)))
    const cmp: Record<SortKey, (a: Row, b: Row) => number> = {
      heard: (a, b) => b.advert - a.advert,
      name: (a, b) => a.name.localeCompare(b.name),
      distance: (a, b) => (a.dist ?? Infinity) - (b.dist ?? Infinity),
      posts: (a, b) => b.posts - a.posts || b.lastPost - a.lastPost,
    }
    // joined rooms first whatever the sort: they're the ones you use
    return all.filter(keep).sort((a, b) => Number(b.member) - Number(a.member) || cmp[sort](a, b))
  }, [all, show, q, sort])
  const joined = all.filter((r) => r.member).length

  // a room whose advert was heard but isn't a contact (the radio's contact list was full, say): add it
  // from its advert, wait for the radio to list it, then open the join form
  const addAndJoin = (r: Row) => run(async () => {
    await api.addContact({ public_key: r.key, name: r.name.slice(0, 31), type: HEARD_ROOM })
    for (let i = 0; i < 10; i++) {
      await qc.refetchQueries({ queryKey: keys.state })
      if (qc.getQueryData<AppState>(keys.state)?.contacts[r.key]) break
      await new Promise((res) => setTimeout(res, 1000))
    }
    joinRoom(r.key)
  }, { error: "Couldn't add it", success: { title: `Added ${r.name}`, description: "Now join it: a password if it has one, or none to join as a guest." } }, r.key)

  const header = (key: SortKey, label: string, className?: string) => (
    <TableHead className={className} aria-sort={sort === key ? (key === "name" || key === "distance" ? "ascending" : "descending") : "none"}>
      <button onClick={() => setSort(key)} className="inline-flex items-center gap-1 rounded font-medium hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">
        {label}{sort === key ? <ArrowDownIcon className="size-3" /> : null}
      </button>
    </TableHead>
  )

  return (
    <Page title={<span className="flex items-center gap-1.5"><UsersRoundIcon className="size-4 text-muted-foreground" />Rooms</span>}
      description={`${plural(all.length, "room server", "room servers")} heard on the mesh · ${joined} joined`}>
      <div className="flex flex-wrap items-center gap-2 border-b px-3 py-2 sm:px-4">
        <div className="relative w-full sm:w-64">
          <SearchIcon className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search rooms" aria-label="Search rooms" className="pl-8" />
        </div>
        <ToggleGroup type="single" value={show} onValueChange={(v) => v && setShow(v as Show)} variant="outline" size="sm" aria-label="Which rooms">
          <ToggleGroupItem value="all">All</ToggleGroupItem>
          <ToggleGroupItem value="joined">Joined</ToggleGroupItem>
        </ToggleGroup>
      </div>
      <div className="min-h-0 flex-1 overflow-auto">
        {rows.length ? (
          <Table>
            <TableHeader className="sticky top-0 z-10 bg-background">
              <TableRow>
                {header("name", "Room", "pl-4")}
                <TableHead className="hidden md:table-cell">You</TableHead>
                {header("posts", "Posts", "hidden sm:table-cell")}
                <TableHead className="hidden xl:table-cell">
                  <span className="inline-flex items-center gap-1">Heard
                    <Hint content="How its last advert reached you since the radio started: straight (with its signal) or over repeaters.">
                      <button type="button" aria-label="About Heard" className="rounded-full text-muted-foreground hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none"><InfoIcon className="size-3.5" /></button>
                    </Hint>
                  </span>
                </TableHead>
                <TableHead className="hidden lg:table-cell">Route</TableHead>
                {header("distance", "Distance", "hidden sm:table-cell")}
                {header("heard", "Last advert", "hidden md:table-cell")}
                <TableHead className="pr-4 text-right"><span className="sr-only">Actions</span></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((r) => {
                const st = standing(r), h = r.heard, c = r.contact
                const dir = home && r.loc && r.dist != null && r.dist >= 1 ? bearing(home, r.loc) : null
                const routed = c?.out_path_len != null && c.out_path_len >= 0
                const heardText = h?.hops != null ? (h.hops === 0 ? "direct" : plural(h.hops, "hop", "hops")) : null
                return (
                  <TableRow key={r.key}>
                    <TableCell className="max-w-[55vw] pl-4 sm:max-w-80 sm:min-w-52">
                      <span className="flex items-center gap-2">
                        <span className={cn("grid size-6 shrink-0 place-items-center rounded-full", r.member ? "bg-violet-500/15 text-violet-700 dark:text-violet-300" : "bg-muted text-muted-foreground")}>
                          <UsersRoundIcon className="size-3.5" />
                        </span>
                        <span className="grid min-w-0">
                          {c
                            ? <button type="button" onClick={() => navigate(convPath(dmConv(r.key)))} className="truncate rounded text-left font-medium hover:underline focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">{r.name}</button>
                            : <span className="truncate font-medium">{r.name}</span>}
                          {/* the columns small screens hide, in one line */}
                          <span className="truncate text-xs text-muted-foreground md:hidden">
                            {[<span key="s" className={st.cls}>{st.label}</span>,
                              r.posts ? plural(r.posts, "post", "posts") : null,
                              r.dist != null ? `${r.dist.toFixed(0)} km${dir ? ` ${dir}` : ""}` : null,
                              `advert ${ago(r.advert)}`].filter(Boolean).flatMap((x, i) => (i ? [" · ", x] : [x]))}
                          </span>
                          <span className="hidden truncate font-mono text-[11px] text-muted-foreground md:block">{r.key.slice(0, 8)}</span>
                        </span>
                      </span>
                    </TableCell>
                    <TableCell className="hidden md:table-cell">
                      {r.room && !r.room.left ? <Badge variant="secondary" className="border-0 bg-emerald-500/10 font-medium text-emerald-700 dark:text-emerald-300">{st.label}</Badge>
                        : <span className={cn("text-sm", st.cls)}>{st.label}</span>}
                    </TableCell>
                    <TableCell className="hidden tabular-nums sm:table-cell">
                      {r.posts ? <span className="grid leading-tight"><span>{r.posts}</span><span className="text-xs text-muted-foreground">last {ago(r.lastPost)}</span></span> : "—"}
                    </TableCell>
                    <TableCell className="hidden tabular-nums xl:table-cell">
                      {heardText ? <span className="inline-flex items-center gap-1.5">{h?.hops === 0 && h.snr != null ? <><SignalBars snr={h.snr} />{h.snr} dB</> : heardText}</span> : "—"}
                    </TableCell>
                    <TableCell className="hidden tabular-nums lg:table-cell">
                      {!c ? "—" : routed ? (c.out_path_len === 0 ? "direct" : plural(c.out_path_len!, "hop", "hops")) : <span className="text-muted-foreground">flood</span>}
                    </TableCell>
                    <TableCell className="hidden tabular-nums sm:table-cell">
                      {r.dist != null ? <span className="grid leading-tight"><span>{r.dist.toFixed(1)} km</span>{dir ? <span className="text-xs text-muted-foreground">{dir}</span> : null}</span> : "—"}
                    </TableCell>
                    <TableCell className="hidden text-muted-foreground md:table-cell">{ago(r.advert)}</TableCell>
                    <TableCell className="pr-4 text-right whitespace-nowrap">
                      {c ? <>
                        {!r.room || r.room.left ? (
                          <Button size="sm" variant="outline" className="mr-1" onClick={() => joinRoom(r.key)} disabled={!state?.connected}>
                            <LogInIcon /><span className="hidden sm:inline">{r.room?.left ? "Join again" : r.member ? "Log in" : "Join"}</span>
                          </Button>
                        ) : null}
                        <Button size="icon-sm" variant="ghost" aria-label={`Open ${r.name}`} onClick={() => navigate(convPath(dmConv(r.key)))}><MessagesSquareIcon /></Button>
                      </> : (
                        <Button size="sm" variant="outline" className="mr-1" disabled={busy === r.key || !state?.connected} onClick={() => void addAndJoin(r)}>
                          <PlusIcon /><span className="hidden sm:inline">Add & join</span>
                        </Button>
                      )}
                      {r.loc ? <Button size="icon-sm" variant="ghost" aria-label={`Show ${r.name} on map`} onClick={() => showOnMap({ kind: "point", lat: r.loc!.lat, lon: r.loc!.lon, label: r.name })}><MapPinIcon /></Button> : null}
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </Table>
        ) : (
          <Empty className="h-full"><EmptyHeader><EmptyMedia variant="icon"><UsersRoundIcon /></EmptyMedia>
            <EmptyTitle>{q || show !== "all" ? "Nothing matches" : "No room servers heard yet"}</EmptyTitle>
            <EmptyDescription>{q || show !== "all" ? "Try another search or filter." : "Rooms appear when their adverts reach your radio, usually a few times a day."}</EmptyDescription>
          </EmptyHeader></Empty>
        )}
      </div>
      <p className="border-t px-4 py-2 text-xs text-muted-foreground">
        Rooms your radio has heard over the mesh: no internet needed. A room server keeps posts and passes them to everyone who
        joined. New ones appear when their adverts reach you.
      </p>
    </Page>
  )
}
