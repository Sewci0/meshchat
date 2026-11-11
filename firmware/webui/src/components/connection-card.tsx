// Settings → "Connection & WiFi": the radio's own WiFi (status, hostname, saved networks), which
// is also how this page reaches it. Passwords are typed by the user, sent once to the radio, and
// never shown or stored by MeshChat.
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter,
  AlertDialogHeader, AlertDialogTitle, AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Item, ItemActions, ItemContent, ItemDescription, ItemGroup, ItemMedia, ItemTitle } from "@/components/ui/item"
import { Spinner } from "@/components/ui/spinner"
import { SignalBars } from "@/components/mesh-bits"
import { api } from "@/lib/api"
import type { SnrLevel } from "@/lib/mesh"
import { keys, useDeviceWifi } from "@/lib/queries"
import type { AppState, DeviceWifi } from "@/lib/types"
import { useAsync } from "@/lib/use-async"
import { cn } from "@/lib/utils"
import { useQueryClient } from "@tanstack/react-query"
import { ArrowUpIcon, LoaderIcon, PlusIcon, RadioTowerIcon, WifiIcon, WifiOffIcon, XIcon } from "lucide-react"
import { useEffect, useState, type FormEvent } from "react"

const HOST_RE = /^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$/
/** WiFi strength on the signal bars' four steps (RSSI in dBm) */
const wifiLevel = (rssi: number): SnrLevel => (rssi > -60 ? 4 : rssi > -67 ? 3 : rssi > -75 ? 2 : 1)
const WIFI_WORDS = ["", "weak", "usable", "good", "excellent"]

export function ConnectionCard({ state }: { state: AppState }) {
  const qc = useQueryClient()
  const { data: wifi, isLoading, refetch } = useDeviceWifi(state.connected)

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><WifiIcon className="size-4" />Connection & WiFi</CardTitle>
        <CardDescription>
          Put the radio somewhere high with good reception and power it from any USB charger. You're
          using the app the radio serves itself, over your WiFi.
        </CardDescription>
      </CardHeader>
      <CardContent className="grid gap-6">
        {isLoading ? <div className="flex items-center gap-2 text-sm text-muted-foreground"><Spinner />Asking the radio…</div>
          : wifi && !wifi.supported ? (
            <Alert><WifiOffIcon /><AlertTitle>This radio's firmware has no WiFi</AlertTitle>
              <AlertDescription>Flash the MeshChat USB+WiFi build (see README) to use it over the network.</AlertDescription></Alert>
          ) : wifi ? (
            <>
              <WifiStatus wifi={wifi} onSetup={async () => { await api.openWifiSetup(); setTimeout(() => void refetch(), 2500) }} />
              <HostnameForm wifi={wifi} onSaved={(w) => qc.setQueryData(keys.wifi, w)} />
              <SavedNetworks wifi={wifi} />
              <AddNetworkForm wifi={wifi} />
            </>
          ) : null}
      </CardContent>
    </Card>
  )
}

function WifiStatus({ wifi, onSetup }: { wifi: DeviceWifi; onSetup: () => Promise<void> }) {
  const { run, isBusy } = useAsync()
  const busy = isBusy()
  const view = {
    connected: { icon: <WifiIcon />, title: `Connected to ${wifi.ssid}`, desc: <span className="inline-flex flex-wrap items-center gap-x-1.5">{wifi.hostname}.local · {wifi.ip}{wifi.rssi ? <> · <SignalBars level={wifiLevel(wifi.rssi)} label={`WiFi signal ${wifi.rssi} dBm, ${WIFI_WORDS[wifiLevel(wifi.rssi)]}`} />{wifi.rssi} dBm</> : null}</span> },
    connecting: { icon: <LoaderIcon className="animate-spin" />, title: `Joining ${wifi.ssid ?? "network"}…`, desc: "If it can't, the setup hotspot opens within a minute." },
    setup: { icon: <RadioTowerIcon />, title: "Setup hotspot is on", desc: <>On your phone, join <b>MeshCore-Setup-…</b> (password <code>meshcore</code>). The setup page opens by itself; if not, go to <code>http://192.168.4.1</code>.</> },
    off: { icon: <WifiOffIcon />, title: "WiFi is off", desc: "Open the setup hotspot or join a network below to turn it on." },
  }[wifi.mode as "connected"] ?? { icon: <WifiIcon />, title: wifi.mode ?? "unknown", desc: "" }
  return (
    <ItemGroup className="rounded-xl border">
      <Item size="sm" className="flex-wrap">
        <ItemMedia variant="icon">{view.icon}</ItemMedia>
        <ItemContent className="min-w-48">
          <ItemTitle>{view.title}{wifi.mode === "connected" ? <Badge variant="secondary">online</Badge> : null}</ItemTitle>
          <ItemDescription className="line-clamp-none">{view.desc}</ItemDescription>
        </ItemContent>
        {wifi.mode !== "setup" ? (
          <ItemActions>
            <Button size="sm" variant="outline" disabled={busy} onClick={() => void run(onSetup, { error: "Couldn't open it", success: "Setup hotspot opening" })}>
              {busy ? <Spinner /> : null}Open setup hotspot
            </Button>
          </ItemActions>
        ) : null}
      </Item>
      <Item size="sm" className="border-t">
        <ItemContent>
          <ItemDescription className="line-clamp-none">
            No screen nearby? Hold the radio's button while plugging it in to open the setup hotspot. It also opens by itself when the saved network can't be found.
          </ItemDescription>
        </ItemContent>
      </Item>
    </ItemGroup>
  )
}

function HostnameForm({ wifi, onSaved }: { wifi: DeviceWifi; onSaved: (w: DeviceWifi) => void }) {
  const [name, setName] = useState(wifi.hostname ?? "")
  const { run, isBusy } = useAsync()
  const busy = isBusy()
  useEffect(() => setName(wifi.hostname ?? ""), [wifi.hostname])
  const value = name.trim().toLowerCase()
  const valid = HOST_RE.test(value)
  const save = (e: FormEvent) => {
    e.preventDefault()
    void run(async () => onSaved(await api.setHostname(value)), { error: "Not saved", success: `Hostname is now ${value}.local` })
  }
  return (
    <form onSubmit={save}>
      <Field data-invalid={!valid && value !== "" ? true : undefined}>
        <FieldLabel htmlFor="hostname">Hostname</FieldLabel>
        <div className="flex gap-2">
          <div className="relative flex-1">
            <Input id="hostname" value={name} onChange={(e) => setName(e.target.value)} maxLength={32} spellCheck={false}
              autoCapitalize="none" aria-invalid={!valid && value !== ""} className="pr-14" />
            <span className="pointer-events-none absolute top-1/2 right-3 -translate-y-1/2 text-sm text-muted-foreground">.local</span>
          </div>
          <Button type="submit" disabled={!valid || busy || value === wifi.hostname}>{busy ? <Spinner /> : null}Save</Button>
        </div>
        <FieldDescription>{!valid && value !== "" ? "Lowercase letters, digits and dashes; can't start or end with a dash." : (wifi.default_hostname && wifi.default_hostname !== wifi.hostname
              ? `How devices find the radio on your network. It also always answers to ${wifi.default_hostname}.local, so bookmarks and the home-screen app keep working after a rename.`
              : "How devices find the radio on your network. Applies at once; it also keeps answering to its built-in name, so bookmarks and the home-screen app keep working.")}</FieldDescription>
      </Field>
    </form>
  )
}

// ---------------------------------------------------------------- saved networks
// The radio keeps up to 8 networks and joins the most preferred one it can find. Passwords are
// typed here, sent once, and never come back: the list only says whether one is set.
function SavedNetworks({ wifi }: { wifi: DeviceWifi }) {
  const qc = useQueryClient()
  const { run, isBusy } = useAsync()
  const nets = wifi.networks ?? []
  // the radio applies changes in its main loop; the WebSocket also nudges a refetch
  const refresh = () => setTimeout(() => void qc.invalidateQueries({ queryKey: keys.wifi }), 600)
  const prefer = (ssid: string) => run(async () => { await api.preferWifi(ssid); refresh() }, { error: "Not changed" }, ssid)
  const remove = (ssid: string) => run(async () => { await api.removeWifi(ssid); refresh() },
    { error: "Not removed", success: `Removed ${ssid}` }, ssid)
  return (
    <div className="grid gap-2">
      <div className="text-sm font-medium">Saved networks <span className="font-normal text-muted-foreground">· {nets.length} of {wifi.max_networks ?? 8}</span></div>
      <p className="text-sm text-muted-foreground">The radio joins the most preferred network it can find with a usable signal, otherwise the strongest one in range.</p>
      {nets.length ? (
        <ItemGroup className="rounded-xl border">
          {nets.map((n, i) => (
            <Item key={n.ssid} size="sm" className={cn(i > 0 && "border-t")}>
              <ItemMedia variant="icon"><WifiIcon /></ItemMedia>
              <ItemContent>
                <ItemTitle>{n.ssid}{n.connected ? <Badge>connected</Badge> : null}{i === 0 ? <Badge variant="secondary">preferred</Badge> : null}</ItemTitle>
                <ItemDescription>{n.password_set ? "password saved" : "open network"}</ItemDescription>
              </ItemContent>
              <ItemActions>
                {i > 0 ? (
                  <Button size="icon-sm" variant="ghost" aria-label={`Prefer ${n.ssid}`} title="Make it the preferred network" disabled={isBusy(n.ssid)} onClick={() => void prefer(n.ssid)}>
                    <ArrowUpIcon />
                  </Button>
                ) : null}
                <AlertDialog>
                  <AlertDialogTrigger asChild>
                    <Button size="icon-sm" variant="ghost" aria-label={`Remove ${n.ssid}`} disabled={isBusy(n.ssid)}><XIcon /></Button>
                  </AlertDialogTrigger>
                  <AlertDialogContent>
                    <AlertDialogHeader>
                      <AlertDialogTitle>Remove {n.ssid}?</AlertDialogTitle>
                      <AlertDialogDescription>
                        The radio forgets it and its password.
                        {n.connected ? " It stays on it until it restarts or the connection drops." : ""}
                        {nets.length === 1 ? " With no saved network left, it opens its setup hotspot after the next restart." : ""}
                      </AlertDialogDescription>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                      <AlertDialogCancel>Cancel</AlertDialogCancel>
                      <AlertDialogAction variant="destructive" onClick={() => void remove(n.ssid)}>Remove</AlertDialogAction>
                    </AlertDialogFooter>
                  </AlertDialogContent>
                </AlertDialog>
              </ItemActions>
            </Item>
          ))}
        </ItemGroup>
      ) : <p className="text-sm text-muted-foreground">No network saved: the radio runs its setup hotspot.</p>}
    </div>
  )
}

function AddNetworkForm({ wifi }: { wifi: DeviceWifi }) {
  const qc = useQueryClient()
  const { run, isBusy } = useAsync()
  const [ssid, setSsid] = useState("")
  const [password, setPassword] = useState("")
  const name = ssid.trim()
  const saved = wifi.networks?.find((n) => n.ssid === name)
  const full = !saved && (wifi.networks?.length ?? 0) >= (wifi.max_networks ?? 8)
  const pwOk = password === "" || (password.length >= 8 && password.length <= 63)
  const valid = !!name && new TextEncoder().encode(name).length <= 32 && pwOk && !full
  const add = (connect: boolean) => run(async () => {
    await api.addWifi(name, password, connect)   // sent once, then forgotten here
    setPassword(""); setSsid("")
    if (!connect) setTimeout(() => void qc.invalidateQueries({ queryKey: keys.wifi }), 600)
  }, {
    error: "Not saved",
    success: connect
      ? { title: "Saved. The radio is restarting", description: `It will join ${name} in about 10 s. MeshChat reconnects by itself.` }
      : saved ? `${name} updated` : `${name} saved. The radio uses it when it's in range.`,
  }, connect ? "connect" : "add")
  return (
    <form onSubmit={(e) => { e.preventDefault(); void add(false) }}>
      <FieldGroup className="gap-3">
        <div className="text-sm font-medium">Add a network</div>
        <div className="grid gap-3 sm:grid-cols-2">
          <Field>
            <FieldLabel htmlFor="ssid">Network name</FieldLabel>
            <Input id="ssid" value={ssid} onChange={(e) => setSsid(e.target.value)} maxLength={32} autoComplete="off" spellCheck={false} autoCapitalize="none" />
          </Field>
          <Field data-invalid={!pwOk ? true : undefined}>
            <FieldLabel htmlFor="wpass">Password</FieldLabel>
            <Input id="wpass" type="password" value={password} onChange={(e) => setPassword(e.target.value)} maxLength={63}
              autoComplete="new-password" placeholder={saved?.password_set ? "unchanged" : ""} aria-invalid={!pwOk} />
          </Field>
        </div>
        <FieldDescription>
          {full ? "Eight networks are saved. Remove one to add another."
            : !pwOk ? "WiFi passwords are 8 to 63 characters."
            : saved ? "Already saved: this updates it. Leave the password empty to keep the saved one."
            : "Leave the password empty for an open network. It's sent once to the radio and never shown again."}
        </FieldDescription>
        <div className="flex flex-wrap gap-2">
          <Button type="submit" variant="outline" disabled={!valid || !!isBusy("add") || !!isBusy("connect")}>{isBusy("add") ? <Spinner /> : <PlusIcon />}{saved ? "Update" : "Add"}</Button>
          <Button type="button" disabled={!valid || !!isBusy("add") || !!isBusy("connect")} onClick={() => void add(true)}>
            {isBusy("connect") ? <Spinner /> : <WifiIcon />}{saved ? "Update and switch now" : "Add and switch now"}
          </Button>
        </div>
      </FieldGroup>
    </form>
  )
}
