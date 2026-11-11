import "leaflet/dist/leaflet.css"
import { Page } from "@/components/page"
import { useActions, type MapIntent } from "@/components/app-provider"
import { SignalBars, TypeBadge } from "@/components/mesh-bits"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { Separator } from "@/components/ui/separator"
import { Switch } from "@/components/ui/switch"
import { useLocal } from "@/lib/local"
import {
  ago, contactByName, convTitle, hasLoc, hopLabel, km, locatePerson, plural, resolvePath, type PersonLocation,
} from "@/lib/mesh"
import { useAppState, useNodes, usePeople } from "@/lib/queries"
import { useAsync } from "@/lib/use-async"
import { useSetHome } from "@/lib/use-set-home"
import type { AppState, MeshNode, Person } from "@/lib/types"
import { cn } from "@/lib/utils"
import { convPath, dmConv } from "@/lib/routes"
import type { CircleMarker as LCircleMarker, LatLngExpression } from "leaflet"
import { HomeIcon, LayersIcon, MessageCircleIcon, RadioTowerIcon, XIcon } from "lucide-react"
import { useEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from "react"
import { Circle, CircleMarker, MapContainer, Polyline, Popup, TileLayer, Tooltip, useMap, useMapEvents } from "react-leaflet"
import { useNavigate, useSearchParams } from "react-router"

interface Layers { people: boolean; heard: boolean; publicSame: boolean; publicOther: boolean }
const DEFAULT_LAYERS: Layers = { people: true, heard: true, publicSame: true, publicOther: false }

// Colours are fixed hex values (Leaflet draws on canvas, where CSS variables don't apply).
const TYPE_COLOR: Record<string, string> = { repeater: "#3b82f6", companion: "#10b981", room: "#a855f7", sensor: "#f59e0b", unknown: "#94a3b8" }
const PUBLIC = "#94a3b8", ACCENT = "#10b981"

export function MapPage() {
  const { data: state } = useAppState()
  const { data: people } = usePeople()
  const nodes = useNodes()
  const { mapIntent, clearMapIntent } = useActions()
  const [layers, setLayers] = useLocal<Layers>("mapLayers", DEFAULT_LAYERS)
  const personRefs = useRef(new Map<string, LCircleMarker>())
  const [params] = useSearchParams()
  const picking = params.get("pick") === "home"   // Settings → Map home → Pick on map
  const [pick, setPick] = useState<{ lat: number; lon: number } | null>(null)

  const home = state?.home
  const drawn = useMemo(() => spreadStacks(nodes, layers), [nodes, layers])
  const placed = useMemo(() => placePeople(people, state, nodes), [people, state, nodes])
  const counts = useMemo(() => ({
    people: placed.length,
    heard: drawn.filter((d) => d.kind === "heard").length,
  }), [placed, drawn])

  if (!home) return null
  return (
    <Page title="Map" description={`${plural(counts.people, "person", "people")} from channels · ${plural(counts.heard, "node", "nodes")} your radio knows`} actions={<><LayerControl layers={layers} setLayers={setLayers} /></>}>
      {/* isolate: Leaflet's panes use z-index 400–1000; keep them inside the map so the mobile sidebar,
          menus, dialogs and toasts (z-50) stay on top */}
      <div className="relative isolate min-h-0 flex-1">
        <MapContainer center={[home.lat, home.lon]} zoom={10} preferCanvas attributionControl
          className={cn("h-full w-full bg-muted", picking && "cursor-crosshair!")}>
          <TileLayer url="https://tile.openstreetmap.org/{z}/{x}/{y}.png" maxZoom={18}
            attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> · nodes: your radio + map.meshcore.io' />

          {drawn.map(({ node, kind, lat, lon, stacked }) => (
            <CircleMarker key={node.pubkey} center={[lat, lon]}
              {...(kind === "heard" ? { radius: 6, pathOptions: { color: "#fff", weight: 1.5, fillColor: TYPE_COLOR[node.type] ?? PUBLIC, fillOpacity: 0.95 } }
                : kind === "public" ? { radius: 4, pathOptions: { color: PUBLIC, weight: 1, fillColor: PUBLIC, fillOpacity: 0.5 } }
                : { radius: 4, pathOptions: { color: PUBLIC, weight: 1.5, dashArray: "2 2", fill: false } })}>
              <Tooltip direction="top" offset={[0, -6]}>{node.name}</Tooltip>
              <Popup><NodePopup node={node} home={home} stacked={stacked} /></Popup>
            </CircleMarker>
          ))}

          {layers.people ? placed.map(({ person, loc, lat, lon, ring }) => (
            <PersonMarker key={person.name} person={person} loc={loc} lat={lat} lon={lon} ring={ring} state={state}
              register={(m) => { if (m) personRefs.current.set(person.name, m); else personRefs.current.delete(person.name) }} />
          )) : null}

          <CircleMarker center={[home.lat, home.lon]} radius={7} pathOptions={{ color: "#0f172a", weight: 2.5, fillColor: "#fff", fillOpacity: 1 }}>
            <Tooltip direction="top" offset={[0, -6]} permanent={false}>{home.label ?? "Home"} (you)</Tooltip>
          </CircleMarker>

          <IntentOverlay intent={mapIntent} state={state} nodes={nodes} personRefs={personRefs} onMissing={clearMapIntent} />
          <HomeListener />
          {picking ? <PickClicks onPick={setPick} /> : null}
          {picking && pick ? <CircleMarker center={[pick.lat, pick.lon]} radius={8} pathOptions={{ color: ACCENT, weight: 3, fillColor: "#fff", fillOpacity: 1 }} /> : null}
        </MapContainer>
        {picking ? <PickBar pick={pick} /> : null}

        {mapIntent ? <IntentChip intent={mapIntent} state={state} nodes={nodes} onClear={clearMapIntent} /> : null}
        <Legend />
      </div>
    </Page>
  )
}

// ---------------------------------------------------------------- nodes
type DrawKind = "heard" | "public" | "other"
interface Drawn { node: MeshNode; kind: DrawKind; lat: number; lon: number; stacked: string[] }

/** Several devices often share one pin (same operator, same mast): spread them ~120 m apart. */
function spreadStacks(nodes: Map<string, MeshNode>, layers: Layers): Drawn[] {
  const groups = new Map<string, Drawn[]>()
  for (const node of nodes.values()) {
    if (!hasLoc(node)) continue
    const kind: DrawKind = node.heard || node.contact ? "heard" : node.compatible === false ? "other" : "public"
    if ((kind === "heard" && !layers.heard) || (kind === "public" && !layers.publicSame) || (kind === "other" && !layers.publicOther)) continue
    const k = `${node.lat!.toFixed(5)},${node.lon!.toFixed(5)}`
    if (!groups.has(k)) groups.set(k, [])
    groups.get(k)!.push({ node, kind, lat: node.lat!, lon: node.lon!, stacked: [] })
  }
  const out: Drawn[] = []
  for (const g of groups.values()) {
    g.forEach((d, i) => {
      if (g.length > 1) {
        const a = (2 * Math.PI * i) / g.length, r = 0.12
        d.lat += (r / 111) * Math.sin(a)
        d.lon += (r / (111 * Math.cos((d.node.lat! * Math.PI) / 180))) * Math.cos(a)
        d.stacked = g.filter((x) => x !== d).map((x) => x.node.name)
      }
      out.push(d)
    })
  }
  // heard nodes on top
  return out.sort((a, b) => Number(a.kind === "heard") - Number(b.kind === "heard"))
}

function NodePopup({ node, home, stacked }: { node: MeshNode; home: { lat: number; lon: number }; stacked: string[] }) {
  const navigate = useNavigate()
  const h = node.heard
  return (
    <PopupBody>
      <div className="flex items-center gap-2">
        <span className="truncate font-semibold">{node.name}</span>
        <TypeBadge type={node.type} />
      </div>
      {h ? (
        <p className="flex items-center gap-1.5"><SignalBars snr={h.snr} />heard {ago(h.last_heard)} · {h.hops ? `${plural(h.hops, "hop", "hops")} · last-hop` : "direct ·"} SNR {h.snr ?? "?"} dB</p>
      ) : (
        <p className="text-muted-foreground">{node.contact ? `in your contacts · advert ${ago(node.last_advert)}` : `not heard by you · on public map ${ago(node.last_advert)}`}</p>
      )}
      {node.compatible === false ? (
        <p className="text-amber-600 dark:text-amber-400">⚠ {node.radio}: different radio settings. It can't hear you or relay your messages.</p>
      ) : node.radio ? <p className="text-muted-foreground">{node.radio}</p> : null}
      <p className="text-muted-foreground">{km(home, { lat: node.lat!, lon: node.lon! }).toFixed(1)} km from home · key {node.pubkey.slice(0, 10)}…</p>
      {stacked.length ? <p className="text-xs text-muted-foreground">Same pin as {stacked.join(", ")}</p> : null}
      <div className="flex gap-2 pt-1">
        {node.contact && node.type === "companion" ? (
          <Button size="sm" onClick={() => navigate(convPath(dmConv(node.pubkey)))}><MessageCircleIcon />Message</Button>
        ) : null}
        {(node.type === "repeater" || node.type === "room") && node.compatible !== false ? (
          <Button size="sm" variant="outline" onClick={() => navigate(`/repeaters/${node.pubkey}`)}><RadioTowerIcon />Repeater details</Button>
        ) : null}
      </div>
    </PopupBody>
  )
}

// ---------------------------------------------------------------- people
interface Placed { person: Person; loc: PersonLocation; lat: number; lon: number; ring: boolean }

/** People behind the same repeater are spread on a small ring around it. */
function placePeople(people: Map<string, Person> | undefined, state: AppState | undefined, nodes: Map<string, MeshNode>): Placed[] {
  const groups = new Map<string, { loc: PersonLocation; people: Person[] }>()
  for (const p of people?.values() ?? []) {
    if (p.name === state?.self.name) continue
    const loc = locatePerson(p, state, nodes)
    if (!loc) continue
    const k = loc.exact ? `exact:${p.name}` : `${loc.lat.toFixed(4)},${loc.lon.toFixed(4)}`
    if (!groups.has(k)) groups.set(k, { loc, people: [] })
    groups.get(k)!.people.push(p)
  }
  const out: Placed[] = []
  for (const { loc, people: ps } of groups.values()) {
    ps.forEach((person, i) => {
      let lat = loc.lat, lon = loc.lon
      if (!loc.exact) {
        const a = (2 * Math.PI * i) / ps.length - Math.PI / 2, r = 1.4 + 0.15 * ps.length
        lat += (r / 111) * Math.sin(a)
        lon += (r / (111 * Math.cos((loc.lat * Math.PI) / 180))) * Math.cos(a)
      }
      out.push({ person, loc, lat, lon, ring: !loc.exact && i === 0 })
    })
  }
  return out
}

function PersonMarker({ person, loc, lat, lon, ring, state, register }: Placed & { state: AppState | undefined; register: (m: LCircleMarker | null) => void }) {
  const navigate = useNavigate()
  const contact = contactByName(state, person.name)
  return (
    <>
      {ring ? <Circle center={[loc.lat, loc.lon]} radius={loc.direct ? 3000 : 5000} interactive={false}
        pathOptions={{ color: ACCENT, weight: 1, dashArray: "4 6", fillColor: ACCENT, fillOpacity: 0.07 }} /> : null}
      <CircleMarker ref={register} center={[lat, lon]} radius={loc.exact ? 8 : 7}
        pathOptions={loc.exact ? { color: "#0f172a", weight: 2.5, fillColor: ACCENT, fillOpacity: 1 }
          : { color: "#0f172a", weight: 2, dashArray: "3 3", fillColor: ACCENT, fillOpacity: 0.55 }}>
        <Tooltip direction="top" offset={[0, -8]}>{person.name}</Tooltip>
        <Popup>
          <PopupBody>
            <span className="font-semibold">{person.name}</span>
            <p>Last post {ago(person.last_ts)} in {convTitle(state, person.last_conv)}</p>
            <p className="text-muted-foreground">{plural(person.n, "message", "messages")} in {person.convs.map((c) => convTitle(state, c)).join(", ")}</p>
            <p>{loc.exact ? "📍 " : "≈ "}{loc.how}</p>
            {person.hops != null ? <p className="text-muted-foreground">{person.hops === 0 ? "direct, no repeaters" : `${plural(person.hops, "hop", "hops")} away`}</p> : null}
            <div className="flex flex-wrap gap-2 pt-1">
              {contact ? <Button size="sm" onClick={() => navigate(convPath(dmConv(contact.pubkey)))}><MessageCircleIcon />Message</Button>
                : <span className="text-xs text-muted-foreground">No advert heard yet, so no DMs</span>}
              <Button size="sm" variant="outline" onClick={() => navigate(convPath(person.last_conv))}>Open channel</Button>
            </div>
          </PopupBody>
        </Popup>
      </CircleMarker>
    </>
  )
}

// ---------------------------------------------------------------- intents (route, person, repeater links, point)
function IntentOverlay({ intent, state, nodes, personRefs, onMissing }: {
  intent: MapIntent | null; state: AppState | undefined; nodes: Map<string, MeshNode>
  personRefs: RefObject<Map<string, LCircleMarker>>; onMissing: () => void
}) {
  const map = useMap()
  const geometry = useMemo(() => {
    if (!intent || !state) return null
    const home = state.home
    if (intent.kind === "route") {
      const { resolved } = resolvePath(intent.message.path, intent.message.hash_size, home, nodes)
      const pts: LatLngExpression[] = [[home.lat, home.lon], ...resolved.slice().reverse().filter(Boolean).map((r) => [r!.node.lat!, r!.node.lon!] as LatLngExpression)]
      return { lines: [pts], highlight: pts.slice(1), fit: pts }
    }
    if (intent.kind === "repeater") {
      const d = intent.detail
      if (d.lat == null) return null
      const lines = d.links_list.filter((l) => l.lat != null).map((l) => [[d.lat!, d.lon!], [l.lat!, l.lon!]] as LatLngExpression[])
      return { lines, highlight: [[d.lat, d.lon] as LatLngExpression], fit: [[d.lat, d.lon] as LatLngExpression, ...lines.map((l) => l[1])],
        weights: d.links_list.filter((l) => l.lat != null).map((l) => 1 + Math.min(5, Math.log2(1 + l.to + l.from))) }
    }
    if (intent.kind === "point") return { lines: [], highlight: [[intent.lat, intent.lon] as LatLngExpression], fit: [[intent.lat, intent.lon] as LatLngExpression] }
    return null
  }, [intent, state, nodes])

  useEffect(() => {
    if (!intent) return
    if (intent.kind === "person") {
      const t = setTimeout(() => {
        const m = personRefs.current.get(intent.name)
        if (!m) { onMissing(); return }
        map.setView(m.getLatLng(), Math.max(map.getZoom(), 11), { animate: false })
        personRefs.current.get(intent.name)?.openPopup()
      }, 50)
      return () => clearTimeout(t)
    }
    if (geometry?.fit.length) {
      if (geometry.fit.length === 1) map.setView(geometry.fit[0], 13)
      else map.fitBounds(geometry.fit as [number, number][], { padding: [40, 40], maxZoom: 12 })
    }
  }, [intent, geometry, map, personRefs, onMissing])

  if (!geometry) return null
  return (
    <>
      {geometry.lines.map((pts, i) => (
        <Polyline key={i} positions={pts} pathOptions={{ color: ACCENT, weight: "weights" in geometry ? geometry.weights![i] : 3,
          dashArray: intent?.kind === "route" ? "6 6" : undefined, opacity: 0.85 }} />
      ))}
      {geometry.highlight.map((p, i) => (
        <CircleMarker key={i} center={p} radius={12} pathOptions={{ color: ACCENT, weight: 3, fill: false }} interactive={false} />
      ))}
    </>
  )
}

function IntentChip({ intent, state, nodes, onClear }: { intent: MapIntent; state: AppState | undefined; nodes: Map<string, MeshNode>; onClear: () => void }) {
  let text = ""
  if (intent.kind === "route" && intent.label) text = intent.label
  else if (intent.kind === "route") {
    const { hops, resolved } = resolvePath(intent.message.path, intent.message.hash_size, state?.home, nodes)
    const who = intent.message.direction === "out" ? "Your message" : intent.message.sender ?? "Message"
    const unknown = resolved.filter((r) => !r).length
    text = `${who}: ${[...hops.map((h, i) => hopLabel(resolved[i], h)), "you"].join(" → ")}${unknown ? ` (${plural(unknown, "hop", "hops")} not on the map)` : ""}`
  } else if (intent.kind === "repeater") text = `${intent.detail.name}: links to ${plural(intent.detail.links_list.length, "repeater", "repeaters")} · line width = traffic`
  else if (intent.kind === "person") text = `Showing ${intent.name}`
  else text = intent.label
  return (
    <div className="pointer-events-none absolute inset-x-0 top-3 z-[500] flex justify-center px-3">
      <div className="pointer-events-auto flex max-w-2xl items-center gap-2 rounded-full border bg-background/95 py-1 pr-1 pl-3 text-xs shadow-md backdrop-blur">
        <span className="line-clamp-2">{text}</span>
        <Button size="icon-xs" variant="ghost" onClick={onClear} aria-label="Clear"><XIcon /></Button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------- controls
function LayerControl({ layers, setLayers }: { layers: Layers; setLayers: (l: Layers) => void }) {
  const items: { key: keyof Layers; label: string; hint: string; swatch: ReactNode }[] = [
    { key: "people", label: "People in channels", hint: "Posted in the last 7 days. Solid = GPS, dashed = near their first repeater.", swatch: <Dot className="border-2 border-slate-900 bg-emerald-500" /> },
    { key: "heard", label: "Nodes your radio knows", hint: "Heard their advert, or in your contacts", swatch: <Dot className="bg-sky-500" /> },
    { key: "publicSame", label: "Public map, your settings", hint: "From map.meshcore.io, not heard by you yet", swatch: <Dot className="bg-slate-400/70" /> },
    { key: "publicOther", label: "Public map, other settings", hint: "Can't hear you (e.g. SF8)", swatch: <Dot className="border border-dashed border-slate-400" /> },
  ]
  return (
    <Popover>
      <PopoverTrigger asChild><Button size="sm" variant="outline"><LayersIcon />Layers</Button></PopoverTrigger>
      <PopoverContent align="end" className="w-80">
        <div className="grid gap-3">
          {items.map((it) => (
            <div key={it.key} className="flex items-start gap-3">
              <Switch id={`layer-${it.key}`} checked={layers[it.key]} onCheckedChange={(v) => setLayers({ ...layers, [it.key]: v })} className="mt-0.5" />
              <Label htmlFor={`layer-${it.key}`} className="grid gap-0.5 font-normal">
                <span className="flex items-center gap-2 font-medium">{it.swatch}{it.label}</span>
                <span className="text-xs text-muted-foreground">{it.hint}</span>
              </Label>
            </div>
          ))}
        </div>
      </PopoverContent>
    </Popover>
  )
}

const Dot = ({ className }: { className?: string }) => <span aria-hidden className={cn("inline-block size-2.5 rounded-full", className)} />

function Legend() {
  // The legend sits outside MapContainer, so "home" recentres via an event HomeListener handles.
  return (
    <div className="absolute bottom-6 left-3 z-[500] flex items-center gap-3 rounded-lg border bg-background/95 px-3 py-1.5 text-xs shadow-sm backdrop-blur">
      <span className="flex items-center gap-1.5"><Dot className="bg-sky-500" />repeater</span>
      <span className="flex items-center gap-1.5"><Dot className="bg-emerald-500" />companion</span>
      <span className="hidden items-center gap-1.5 sm:flex"><Dot className="bg-violet-500" />room</span>
      <Separator orientation="vertical" className="data-[orientation=vertical]:h-4" />
      <button className="inline-flex items-center gap-1 rounded hover:underline focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none"
        onClick={() => window.dispatchEvent(new CustomEvent("meshchat:home"))}>
        <HomeIcon className="size-3" />home
      </button>
    </div>
  )
}

function PopupBody({ children }: { children: ReactNode }) {
  return <div className="grid min-w-56 gap-1 font-sans text-[13px] leading-snug text-popover-foreground">{children}</div>
}

function HomeListener() {
  const map = useMap()
  const { data: state } = useAppState()
  useEffect(() => {
    const go = () => state && map.setView([state.home.lat, state.home.lon], 11)
    window.addEventListener("meshchat:home", go)
    return () => window.removeEventListener("meshchat:home", go)
  }, [map, state])
  return null
}

// ---------------------------------------------------------------- picking the map home
function PickClicks({ onPick }: { onPick: (p: { lat: number; lon: number }) => void }) {
  useMapEvents({ click: (e) => onPick({ lat: +e.latlng.lat.toFixed(5), lon: +e.latlng.lng.toFixed(5) }) })
  return null
}

function PickBar({ pick }: { pick: { lat: number; lon: number } | null }) {
  const navigate = useNavigate()
  const { data: state } = useAppState()
  const setHome = useSetHome()
  const { run, isBusy } = useAsync()
  const save = () => pick && run(async () => { await setHome(pick.lat, pick.lon, state?.home.label); navigate("/settings") }, {
    error: "Not saved", success: { title: "Home saved", description: "The radio downloads the public map again for this area." },
  })
  return (
    <div className="absolute inset-x-3 top-3 z-[1000] mx-auto flex max-w-lg flex-wrap items-center gap-2 rounded-xl border bg-popover p-2 pl-3 text-sm text-popover-foreground shadow-lg">
      <HomeIcon className="size-4 shrink-0 text-muted-foreground" />
      <span className="min-w-0 flex-1">{pick ? `${pick.lat}, ${pick.lon}` : "Tap the map where home is. Zoom in for accuracy."}</span>
      <Button size="sm" variant="ghost" onClick={() => navigate("/settings")}>Cancel</Button>
      <Button size="sm" disabled={!pick || isBusy()} onClick={() => void save()}>Set as home</Button>
    </div>
  )
}
