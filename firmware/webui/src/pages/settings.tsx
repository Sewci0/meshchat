import { Page, PageBody } from "@/components/page"
import { useActions } from "@/components/app-provider"
import { ConnectionCard } from "@/components/connection-card"
import { FirmwareUpdate } from "@/components/firmware-update"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter,
  AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Item, ItemActions, ItemContent, ItemDescription, ItemGroup, ItemTitle } from "@/components/ui/item"
import { Spinner } from "@/components/ui/spinner"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { api } from "@/lib/api"
import { ago, byteLength } from "@/lib/mesh"
import { canGeolocate, isIOS, isStandalone } from "@/lib/device"
import { keys, useAppState, useDeviceWifi, usePublicNodes } from "@/lib/queries"
import { useAsync } from "@/lib/use-async"
import { useSetHome } from "@/lib/use-set-home"
import { useTheme, type Theme } from "@/lib/theme"
import type { AppState } from "@/lib/types"
import { cn } from "@/lib/utils"
import { useQueryClient } from "@tanstack/react-query"
import {
  BluetoothIcon, EyeOffIcon, LocateFixedIcon, MapPinIcon, MegaphoneIcon, MonitorIcon, MoonIcon, RadioIcon, RotateCcwIcon, SmartphoneIcon, SunIcon, WaypointsIcon,
} from "lucide-react"
import { useEffect, useState, type FormEvent, type ReactNode } from "react"
import { useNavigate } from "react-router"
import { toast } from "sonner"

export function SettingsPage() {
  const { data: state } = useAppState()
  if (!state) return null
  return (
    <Page title="Settings" description="Your node, the mesh, connections and this app">
      <PageBody>
        <Group title="Your node"><YourNode state={state} /></Group>
        <Group title="Mesh">
          <Network state={state} />
          <Radio state={state} />
        </Group>
        <Group title="Connections">
          <ConnectionCard state={state} />
          <Bluetooth state={state} />
        </Group>
        <Group title="Map"><MapHome state={state} /></Group>
        <Group title="This app">
          <Appearance />
          <InstallTip />
        </Group>
      </PageBody>
    </Page>
  )
}

/** A titled group of cards. Channels live in the sidebar (+ to join or listen, ⋯ in a channel to leave). */
function Group({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="grid gap-3">
      <h2 className="px-1 pt-2 text-xs font-medium tracking-wide text-muted-foreground uppercase">{title}</h2>
      {children}
    </section>
  )
}

/** Your name, and whether others can see you (adverts) */
function YourNode({ state }: { state: AppState }) {
  const qc = useQueryClient()
  const { advertise } = useActions()
  const [name, setName] = useState(state.self.name)
  const { run, isBusy } = useAsync()
  const busy = isBusy()
  useEffect(() => setName(state.self.name), [state.self.name])
  const bytes = byteLength(name.trim())
  const save = (e: FormEvent) => {
    e.preventDefault()
    void run(async () => qc.setQueryData(keys.state, await api.rename(name.trim())),
      { error: "Not saved", success: { title: "Name saved", description: "Others see it after your next flood advert." } })
  }
  const zeroHop = () => run(() => api.advert(false),
    { error: "Not sent", success: { title: "Zero-hop advert sent", description: "Only radios that hear you directly receive it." } })
  const adv = state.advertised
  return (
    <Card>
      <CardContent className="grid gap-4">
        <form onSubmit={save}>
          <Field>
            <FieldLabel htmlFor="name">Public name</FieldLabel>
            <div className="flex gap-2">
              <Input id="name" value={name} onChange={(e) => setName(e.target.value)} maxLength={31} aria-describedby="name-help" />
              <Button type="submit" disabled={busy || !name.trim() || name.trim() === state.self.name || bytes > 31}>{busy ? <Spinner /> : null}Save</Button>
            </div>
            <FieldDescription id="name-help">Shown next to everything you send. Up to 31 bytes; send a flood advert afterwards so others' lists update.</FieldDescription>
          </Field>
        </form>
        <ItemGroup className="rounded-xl border">
          <Item size="sm" className="flex-wrap">
            <ItemContent className="min-w-40">
              <ItemTitle>{adv?.flood ? `Visible as ${adv.name}` : "Not visible yet"}</ItemTitle>
              <ItemDescription className="line-clamp-none">
                {adv ? `Last advert ${ago(adv.ts)}. ` : "You haven't sent a flood advert. "}Others can only see you and read your DMs after their radio hears it.
              </ItemDescription>
            </ItemContent>
            <ItemActions className="flex-wrap">
              <Button size="sm" variant="outline" onClick={() => void zeroHop()} disabled={busy || !state.connected}>Zero-hop</Button>
              <Button size="sm" onClick={advertise} disabled={!state.connected}><MegaphoneIcon />Flood advert…</Button>
            </ItemActions>
          </Item>
          <Item size="sm" className="border-t">
            <ItemContent>
              <ItemTitle><EyeOffIcon className="size-4" />Location hidden</ItemTitle>
              <ItemDescription className="line-clamp-none">Your adverts carry no position. Your rough area can still be inferred from the first repeater your packets reach.</ItemDescription>
            </ItemContent>
          </Item>
        </ItemGroup>
      </CardContent>
    </Card>
  )
}

// "52.2297, 21.0122", "52.2297 21.0122", or a Google/Apple Maps link with coordinates in it
function parseCoords(text: string): [number, number] | null {
  const m = text.match(/@(-?\d+\.\d+),(-?\d+\.\d+)/) ?? text.match(/[?&](?:ll|q|query|center)=(-?\d+\.?\d*)(?:,|%2C)\s*(-?\d+\.?\d*)/i)
    ?? text.match(/^\s*(-?\d+(?:[.,]\d+)?)\s*[,;\s]\s*(-?\d+(?:[.,]\d+)?)\s*$/)
  if (!m) return null
  const a = parseFloat(m[1].replace(",", ".")), b = parseFloat(m[2].replace(",", "."))
  return Math.abs(a) <= 90 && Math.abs(b) <= 180 ? [a, b] : null
}

function MapHome({ state }: { state: AppState }) {
  const navigate = useNavigate()
  const [lat, setLat] = useState(String(state.home.lat))
  const [lon, setLon] = useState(String(state.home.lon))
  const { run, isBusy } = useAsync()
  const busy = isBusy()
  const [locating, setLocating] = useState(false)
  const canLocate = canGeolocate()
  const setHome = useSetHome()
  const locate = () => {
    setLocating(true)
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        setLat(pos.coords.latitude.toFixed(5)); setLon(pos.coords.longitude.toFixed(5)); setLocating(false)
        toast.success("Location filled in", { description: `Accurate to about ${Math.round(pos.coords.accuracy)} m. Save to keep it.` })
      },
      (err) => { setLocating(false); toast.error("No location", { description: err.code === err.PERMISSION_DENIED ? "Location access was denied." : err.message }) },
      { enableHighAccuracy: true, timeout: 15000, maximumAge: 60000 },
    )
  }
  const onPaste = (text: string) => {
    const c = parseCoords(text)
    if (!c) return false
    setLat(String(c[0])); setLon(String(c[1]))
    return true
  }
  const valid = Number.isFinite(+lat) && Number.isFinite(+lon) && Math.abs(+lat) <= 90 && Math.abs(+lon) <= 180 && lat !== "" && lon !== ""
  const save = (e: FormEvent) => {
    e.preventDefault()
    void run(() => setHome(+lat, +lon, state.home.label), { error: "Not saved", success: "Home saved" })
  }
  return (
    <Card>
      <CardHeader><CardTitle>Map home</CardTitle><CardDescription>
        Centres the map and measures distances. Stored only on the radio and never transmitted.
      </CardDescription></CardHeader>
      <CardContent className="grid gap-4">
        <form onSubmit={save}>
          <FieldGroup className="grid gap-3 sm:grid-cols-[1fr_1fr_auto] sm:items-end">
            <Field><FieldLabel htmlFor="lat">Latitude</FieldLabel><Input id="lat" inputMode="decimal" value={lat} onChange={(e) => setLat(e.target.value)}
              onPaste={(e) => { if (onPaste(e.clipboardData.getData("text"))) e.preventDefault() }} /></Field>
            <Field><FieldLabel htmlFor="lon">Longitude</FieldLabel><Input id="lon" inputMode="decimal" value={lon} onChange={(e) => setLon(e.target.value)}
              onPaste={(e) => { if (onPaste(e.clipboardData.getData("text"))) e.preventDefault() }} /></Field>
            <Button type="submit" disabled={!valid || busy}>{busy ? <Spinner /> : null}Save</Button>
          </FieldGroup>
        </form>
        <div className="flex flex-wrap gap-2">
          {canLocate ? <Button variant="outline" size="sm" onClick={locate} disabled={locating}>{locating ? <Spinner /> : <LocateFixedIcon />}Use this device's location</Button> : null}
          <Button variant="outline" size="sm" onClick={() => navigate("/map?pick=home")}><MapPinIcon />Pick on the map</Button>
        </div>
        <p className="text-xs text-muted-foreground">
          You can also paste coordinates, or a Google or Apple Maps link, into either field.
          {canLocate ? "" : " This device's location isn't offered here: browsers only share it with secure (HTTPS) pages, and the radio serves plain HTTP on your network."}
        </p>
        <PublicMapStatus />
      </CardContent>
    </Card>
  )
}

/** The public map is downloaded by the radio itself (browsers can't: CORS, 55 MB). */
function PublicMapStatus() {
  const { data } = usePublicNodes()
  const running = !!data?.status?.running, waiting = !!data && !data.fetched && !data.status?.error
  const qc = useQueryClient()
  useEffect(() => {   // follow the download while it runs (about 10 minutes, every 12 hours) or is about to start
    if (!running && !waiting) return
    const t = setInterval(() => void qc.invalidateQueries({ queryKey: keys.publicNodes }), 5000)
    return () => clearInterval(t)
  }, [running, waiting, qc])
  if (!data) return null
  const st = data.status
  const mb = (n?: number) => ((n ?? 0) / 1e6).toFixed(1)
  const text = st?.running ? `Downloading the public map from map.meshcore.io: ${mb(st.received)} of ${st.size ? mb(st.size) : "?"} MB, ${st.seen ?? 0} nodes read.`
    : data.fetched ? `Public map: ${data.nodes.length} nodes within 90 km, downloaded ${ago(data.fetched)}.${st?.error ? ` Last refresh failed: ${st.error}.` : ""}`
      : st?.error ? `Public map not downloaded yet: ${st.error}. The radio tries again every 30 min.`
        : "The radio downloads the public map from map.meshcore.io once it's on WiFi and knows the time."
  return <p className="text-sm text-muted-foreground">{text} Saving a new home downloads it again for that area.</p>
}

/** The PIN phones type when pairing with the radio over Bluetooth (MeshCore app, PommeCore). */
function Bluetooth({ state }: { state: AppState }) {
  const { data: wifi, refetch } = useDeviceWifi(state.connected, false)
  const [pin, setPin] = useState("")
  const { run, isBusy } = useAsync()
  const busy = isBusy()
  const valid = /^[1-9][0-9]{5}$/.test(pin)
  const save = (e: FormEvent) => {
    e.preventDefault()
    void run(async () => { await api.setBlePin(pin); setPin(""); void refetch() }, {
      error: "Not saved",
      success: { title: "PIN saved", description: "Phones use it after the radio restarts. Already-paired phones need to forget the radio and pair again.",
        action: { label: "Restart now", onClick: () => void restartRadio() } },
    })
  }
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><BluetoothIcon className="size-4" />Bluetooth</CardTitle>
        <CardDescription>
          The MeshCore app and PommeCore on iPhone connect over Bluetooth and ask for this PIN when pairing.
          They work alongside this page.{wifi && !wifi.ble_pin_set ? " The radio still uses the firmware's default PIN 123456: anyone nearby could pair with it, so set your own." : ""}
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={save}>
          <FieldGroup className="grid gap-3 sm:grid-cols-[1fr_auto] sm:items-end">
            <Field>
              <FieldLabel htmlFor="blepin">New PIN</FieldLabel>
              <Input id="blepin" inputMode="numeric" autoComplete="off" maxLength={6} placeholder="6 digits" value={pin}
                onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))} aria-invalid={pin.length > 0 && !valid} />
              <FieldDescription>Six digits, not starting with 0.{wifi?.ble_pin_set ? " A custom PIN is set." : ""}</FieldDescription>
            </Field>
            <Button type="submit" className="self-start sm:mt-6" disabled={!valid || busy}>{busy ? <Spinner /> : null}Save</Button>
          </FieldGroup>
        </form>
      </CardContent>
    </Card>
  )
}

// Not a hook: also used from a toast's action button, after the component that showed it is gone.
async function restartRadio() {
  try { await api.rebootRadio(); toast.success("Radio restarting", { description: "This page reconnects in about 15 seconds." }) }
  catch (err) { toast.error("Couldn't restart it", { description: (err as Error).message }) }
}

// Networks in Poland. Same frequency and bandwidth, different spreading factor: a radio hears only
// the one it's set to (a LoRa radio listens on one setting at a time).
const NETWORKS = [
  { name: "MeshCore Południe", radio: { freq: 869.618, bw: 62.5, sf: 6, cr: 8 },
    about: "Southern Poland: Silesia, Częstochowa and the Jura. Fast (SF6), with dense repeaters. The network this radio was set up for.",
    link: "https://meshcoresouth.pl/" },
  { name: "MeshCore Polska", radio: { freq: 869.618, bw: 62.5, sf: 8, cr: 8 },
    about: "The national standard (EU/UK Narrow), used across most of Poland. Slower (SF8), longer range per hop.",
    link: "https://meshcorepolska.org/" },
] as const
type RadioParams = { freq: number; bw: number; sf: number; cr: number }
const sameRadio = (a: RadioParams, b: RadioParams) => Math.abs(a.freq - b.freq) < 0.0005 && a.bw === b.bw && a.sf === b.sf && a.cr === b.cr
const radioLabel = (r: RadioParams) => `${r.freq} MHz · ${r.bw} kHz · SF${r.sf} · CR${r.cr}`

function Network({ state }: { state: AppState }) {
  const qc = useQueryClient()
  const cur = state.self.radio
  const [target, setTarget] = useState<{ name: string; radio: RadioParams } | null>(null)
  const [custom, setCustom] = useState({ freq: String(cur.freq), bw: String(cur.bw), sf: String(cur.sf), cr: String(cur.cr) })
  const { run, isBusy } = useAsync()
  const busy = isBusy()
  const known = NETWORKS.find((n) => sameRadio(n.radio, cur))
  const c = { freq: Number(custom.freq), bw: Number(custom.bw), sf: Number(custom.sf), cr: Number(custom.cr) }
  const customValid = c.freq - c.bw / 2000 >= 863 && c.freq + c.bw / 2000 <= 870 && [62.5, 125, 250].includes(c.bw) &&
    Number.isInteger(c.sf) && c.sf >= 5 && c.sf <= 12 && Number.isInteger(c.cr) && c.cr >= 5 && c.cr <= 8

  const apply = (t: NonNullable<typeof target>) => run(async () => {
    await api.setRadio(t.radio)
    setTimeout(() => void qc.invalidateQueries(), 1500)   // every view: each network has its own channels, repeaters and map
    setTarget(null)
  }, { error: "Not switched", success: { title: `Switched to ${t.name}`, description: "You now hear and reach the nodes on these settings. Switch back here any time." } })

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><WaypointsIcon className="size-4" />Network</CardTitle>
        <CardDescription>
          Nearby MeshCore networks use different radio settings, and a radio hears only one at a time. You're on{" "}
          <b>{known?.name ?? "custom settings"}</b> ({radioLabel(cur)}). Each network keeps its own channel history, repeaters and
          map; switch back and they're there again. Direct messages and contacts are shared: they're with the same people either way.
        </CardDescription>
      </CardHeader>
      <CardContent className="grid gap-3">
        <ItemGroup className="rounded-xl border">
          {NETWORKS.map((n, i) => {
            const active = sameRadio(n.radio, cur)
            return (
              <Item key={n.name} size="sm" className={cn(i > 0 && "border-t")}>
                <ItemContent>
                  <ItemTitle>{n.name}{active ? <Badge>current</Badge> : null}</ItemTitle>
                  <ItemDescription className="line-clamp-none">
                    {radioLabel(n.radio)}. {n.about}{" "}
                    <a href={n.link} target="_blank" rel="noreferrer" className="underline underline-offset-2">Website</a>
                  </ItemDescription>
                </ItemContent>
                <ItemActions>
                  <Button size="sm" variant={active ? "ghost" : "outline"} disabled={active || !state.connected}
                    onClick={() => setTarget({ name: n.name, radio: n.radio })}>{active ? "In use" : "Switch"}</Button>
                </ItemActions>
              </Item>
            )
          })}
        </ItemGroup>
        <details className="group rounded-xl border p-3 text-sm">
          <summary className="cursor-pointer font-medium">Custom settings</summary>
          <form className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-[1fr_1fr_1fr_1fr_auto] sm:items-end"
            onSubmit={(e) => { e.preventDefault(); setTarget({ name: "custom settings", radio: c }) }}>
            <Field><FieldLabel htmlFor="nf">MHz</FieldLabel><Input id="nf" inputMode="decimal" value={custom.freq} onChange={(e) => setCustom({ ...custom, freq: e.target.value })} /></Field>
            <Field><FieldLabel htmlFor="nb">kHz</FieldLabel><Input id="nb" inputMode="decimal" value={custom.bw} onChange={(e) => setCustom({ ...custom, bw: e.target.value })} /></Field>
            <Field><FieldLabel htmlFor="ns">SF</FieldLabel><Input id="ns" inputMode="numeric" value={custom.sf} onChange={(e) => setCustom({ ...custom, sf: e.target.value })} /></Field>
            <Field><FieldLabel htmlFor="nc">CR</FieldLabel><Input id="nc" inputMode="numeric" value={custom.cr} onChange={(e) => setCustom({ ...custom, cr: e.target.value })} /></Field>
            <Button type="submit" variant="outline" className="col-span-2 sm:col-span-1" disabled={!customValid || sameRadio(c, cur) || !state.connected}>Switch</Button>
            <p className="col-span-full text-xs text-muted-foreground">Inside 863–870 MHz; bandwidth 62.5, 125 or 250 kHz; SF 5–12; CR 5–8. Polish networks use 869.618 MHz (869.4–869.65 MHz: up to 500 mW, 10% of the time).</p>
          </form>
        </details>
      </CardContent>
      <AlertDialog open={!!target} onOpenChange={(o) => !o && setTarget(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Switch to {target?.name}?</AlertDialogTitle>
            <AlertDialogDescription>
              {target ? radioLabel(target.radio) : ""}. From then on your radio only hears and reaches nodes on these settings, so people
              on {known?.name ?? "the current network"} can't reach you until you switch back. It takes effect at once. Channels,
              repeaters and the map show that network's own history; direct messages and contacts stay as they are. Others only
              learn you're there after you send an advert on the new network.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction disabled={busy} onClick={(e) => { e.preventDefault(); if (target) void apply(target) }}>{busy ? <Spinner /> : null}Switch</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Card>
  )
}

function Radio({ state }: { state: AppState }) {
  const s = state.self, r = s.radio
  const rows: [string, string][] = [
    ["Status", state.connected ? `connected on ${state.port}` : `not connected (${state.port})`],
    ["Frequency", `${r.freq} MHz`], ["Bandwidth", `${r.bw} kHz`], ["Spreading factor", `SF${r.sf}`], ["Coding rate", `4/${r.cr}`],
    ["TX power", `${s.tx_power} dBm`], ["Path hashes", s.path_hash_mode != null ? `${s.path_hash_mode + 1}-byte` : "—"],
    ["Firmware", s.fw ? `${s.fw} (${s.model})` : "—"], ["Public key", s.pubkey],
  ]
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><RadioIcon className="size-4" />Radio</CardTitle>
        <CardDescription>
          What the radio is set to now. Switch networks above.
        </CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4">
        <dl className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-1.5 text-sm">
          {rows.map(([k, v]) => (<div key={k} className="contents"><dt className="text-muted-foreground">{k}</dt><dd className="break-all">{v}</dd></div>))}
        </dl>
        <div className="flex flex-wrap gap-2">
          <FirmwareUpdate />
          <AlertDialog>
            <AlertDialogTrigger asChild><Button variant="outline" className="justify-self-start"><RotateCcwIcon />Restart radio</Button></AlertDialogTrigger>
            <AlertDialogContent>
              <AlertDialogHeader>
                <AlertDialogTitle>Restart the radio?</AlertDialogTitle>
                <AlertDialogDescription>It's off the mesh for about 15 seconds. Messages, contacts and settings are kept; anything sent to you meanwhile may be missed.</AlertDialogDescription>
              </AlertDialogHeader>
              <AlertDialogFooter>
                <AlertDialogCancel>Cancel</AlertDialogCancel>
                <AlertDialogAction onClick={() => void restartRadio()}>Restart</AlertDialogAction>
              </AlertDialogFooter>
            </AlertDialogContent>
          </AlertDialog>
        </div>
      </CardContent>
    </Card>
  )
}

function Appearance() {
  const { theme, setTheme } = useTheme()
  return (
    <Card>
      <CardHeader><CardTitle>Appearance</CardTitle></CardHeader>
      <CardContent>
        <ToggleGroup type="single" value={theme} onValueChange={(v) => v && setTheme(v as Theme)} variant="outline" aria-label="Theme">
          <ToggleGroupItem value="system"><MonitorIcon />System</ToggleGroupItem>
          <ToggleGroupItem value="light"><SunIcon />Light</ToggleGroupItem>
          <ToggleGroupItem value="dark"><MoonIcon />Dark</ToggleGroupItem>
        </ToggleGroup>
      </CardContent>
    </Card>
  )
}

/** Browsers on iOS never offer to install a web app, so say how. Hidden once it runs from the home screen. */
function InstallTip() {
  if (isStandalone()) return null
  const ios = isIOS()
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><SmartphoneIcon className="size-4" />Use it like an app</CardTitle>
        <CardDescription>
          {ios
            ? <>In Safari, tap <b>Share</b>, then <b>Add to Home Screen</b>. MeshChat then opens full screen from its own icon, without the browser bars.</>
            : <>In Chrome or Edge, choose <b>Install MeshChat</b> from the menu (or the install icon in the address bar). On iPhone, use Safari's <b>Share → Add to Home Screen</b>.</>}
          {" "}It needs to be on the same WiFi as the radio.
        </CardDescription>
      </CardHeader>
    </Card>
  )
}
