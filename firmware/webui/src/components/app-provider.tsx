// App-wide actions any screen can trigger: flood advert (with confirmation), join channel,
// join room, new DM, the ⌘K palette, and "show this on the map" intents.
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"
import {
  Command, CommandDialog, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandSeparator, CommandShortcut,
} from "@/components/ui/command"
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Spinner } from "@/components/ui/spinner"
import { AddContactDialog, type ContactTab } from "@/components/add-contact"
import { ChannelOverview } from "@/components/listening"
import { NodeAvatar } from "@/components/mesh-bits"
import { JoinRoomDialog } from "@/components/rooms"
import { api } from "@/lib/api"
import { ago, convTitle } from "@/lib/mesh"
import { keys, useAppState } from "@/lib/queries"
import { useTheme } from "@/lib/theme"
import type { Message, RepeaterDetail } from "@/lib/types"
import { chanConv, convPath, dmConv } from "@/lib/routes"
import { useJoinChannel } from "@/lib/use-join-channel"
import { hashtagName, useListening, validHashtag } from "@/lib/use-listening"
import { useQueryClient } from "@tanstack/react-query"
import {
  EarIcon, HashIcon, MapIcon, MegaphoneIcon, MessageSquarePlusIcon, MoonIcon, NetworkIcon, QrCodeIcon, RadioTowerIcon, ScanLineIcon, ScrollTextIcon, SettingsIcon,
  SunIcon, UsersIcon, UsersRoundIcon,
} from "lucide-react"
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type FormEvent, type ReactNode } from "react"
import { useNavigate } from "react-router"
import { toast } from "sonner"

export type MapIntent =
  | { kind: "route"; message: Message; /** the chip's text, instead of "sender: hops → you" */ label?: string }
  | { kind: "person"; name: string }
  | { kind: "repeater"; detail: RepeaterDetail }
  | { kind: "point"; lat: number; lon: number; label: string }

interface Actions {
  advertise: () => void
  joinChannel: () => void
  /** a room server: pick one, or log in to this one */
  joinRoom: (key?: string) => void
  newMessage: () => void
  /** contacts by QR code: scan someone's, or show yours */
  contactQr: (tab?: ContactTab) => void
  openCommand: () => void
  showOnMap: (intent: MapIntent) => void
  mapIntent: MapIntent | null
  clearMapIntent: () => void
}

const Ctx = createContext<Actions | null>(null)
export function useActions() {
  const a = useContext(Ctx)
  if (!a) throw new Error("useActions outside AppProvider")
  return a
}

export function AppProvider({ children }: { children: ReactNode }) {
  const navigate = useNavigate()
  const [advertOpen, setAdvertOpen] = useState(false)
  const [joinOpen, setJoinOpen] = useState(false)
  const [dmOpen, setDmOpen] = useState(false)
  const [cmdOpen, setCmdOpen] = useState(false)
  const [qrOpen, setQrOpen] = useState(false)
  const [qrTab, setQrTab] = useState<ContactTab>("scan")
  const [room, setRoom] = useState<{ open: boolean; key: string | null }>({ open: false, key: null })
  const [mapIntent, setMapIntent] = useState<MapIntent | null>(null)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() === "k" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); setCmdOpen((o) => !o) }
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [])

  const showOnMap = useCallback((intent: MapIntent) => { setMapIntent(intent); navigate("/map") }, [navigate])
  const value = useMemo<Actions>(() => ({
    advertise: () => setAdvertOpen(true),
    joinChannel: () => setJoinOpen(true),
    joinRoom: (key?: string) => setRoom({ open: true, key: key ?? null }),
    newMessage: () => setDmOpen(true),
    contactQr: (tab: ContactTab = "scan") => { setQrTab(tab); setQrOpen(true) },
    openCommand: () => setCmdOpen(true),
    showOnMap,
    mapIntent,
    clearMapIntent: () => setMapIntent(null),
  }), [showOnMap, mapIntent])

  return (
    <Ctx.Provider value={value}>
      {children}
      <FloodAdvertDialog open={advertOpen} onOpenChange={setAdvertOpen} />
      <JoinChannelDialog open={joinOpen} onOpenChange={setJoinOpen} />
      <NewMessageDialog open={dmOpen} onOpenChange={setDmOpen} />
      <JoinRoomDialog open={room.open} initialKey={room.key} onOpenChange={(open) => setRoom((r) => ({ ...r, open }))} />
      <AddContactDialog open={qrOpen} onOpenChange={setQrOpen} tab={qrTab} onTabChange={setQrTab} />
      <CommandPalette open={cmdOpen} onOpenChange={setCmdOpen} actions={value} />
    </Ctx.Provider>
  )
}

// ---------------------------------------------------------------- flood advert
function FloodAdvertDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const { data: state } = useAppState()
  const qc = useQueryClient()
  const [busy, setBusy] = useState(false)
  const send = async () => {
    setBusy(true)
    try {
      await api.advert(true)
      toast.success("Advert sent", { description: "As it spreads, people can see you and send you DMs." })
      onOpenChange(false)
      qc.invalidateQueries({ queryKey: keys.state })
    } catch (e) {
      toast.error("Advert not sent", { description: (e as Error).message })
    } finally { setBusy(false) }
  }
  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Announce “{state?.self.name}” to the mesh?</AlertDialogTitle>
          <AlertDialogDescription>
            A flood advert shares your name and public key, but not your location. Every repeater in the region
            re-transmits it, so others can find you and read your DMs. Send it after setup or a rename, not routinely.
            {state?.advertised ? ` Your last one was ${ago(state.advertised.ts)}.` : " You haven't sent one yet."}
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={busy}>Cancel</AlertDialogCancel>
          <AlertDialogAction disabled={busy || !state?.connected} onClick={(e) => { e.preventDefault(); void send() }}>
            {busy ? <Spinner /> : <MegaphoneIcon />} Send flood advert
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}

// ---------------------------------------------------------------- join channel
function JoinChannelDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const joinChannel = useJoinChannel()
  const { listen } = useListening()
  const [listening, setListening] = useState(false)
  const [name, setName] = useState("")
  const [secret, setSecret] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  useEffect(() => { if (open) { setName(""); setSecret(""); setError(null) } }, [open])

  const tag = hashtagName(name)
  const canListen = !secret && validHashtag(tag)
  const listenOnly = async () => {
    setListening(true); setError(null)
    try {
      const matched = await listen(tag)
      toast.success(`Listening to ${tag}`, { description: matched ? `${matched} recent ${matched === 1 ? "message" : "messages"} found already.` : "Its messages appear as your radio hears them." })
      onOpenChange(false)
    } catch (err) { setError((err as Error).message) } finally { setListening(false) }
  }
  const submit = async (e: FormEvent) => {
    e.preventDefault()
    let n = name.trim()
    if (!secret && !n.startsWith("#")) n = `#${n}`
    if (secret && !/^[0-9a-fA-F]{32}$/.test(secret)) { setError("A secret is 32 hexadecimal characters."); return }
    setBusy(true); setError(null)
    try {
      await joinChannel(n, secret || null)   // errors stay in the dialog, next to the fields
      toast.success(`Joined ${n}`)
      onOpenChange(false)
    } catch (err) { setError((err as Error).message) } finally { setBusy(false) }
  }
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <form onSubmit={submit} className="grid gap-4">
          <DialogHeader>
            <DialogTitle>Join or listen to a channel</DialogTitle>
            <DialogDescription>
              Hashtag channels like <code>#test</code> are open: anyone who knows the name can read them.
              Private channels need the secret from whoever created them.
            </DialogDescription>
          </DialogHeader>
          <FieldGroup>
            <Field>
              <FieldLabel htmlFor="ch-name">Name</FieldLabel>
              <Input id="ch-name" value={name} onChange={(e) => setName(e.target.value)} placeholder="#polska" maxLength={31} required autoFocus />
            </Field>
            <Field>
              <FieldLabel htmlFor="ch-secret">Secret <span className="font-normal text-muted-foreground">(private channels only)</span></FieldLabel>
              <Input id="ch-secret" value={secret} onChange={(e) => setSecret(e.target.value.trim())} placeholder="32 hex characters"
                autoComplete="off" spellCheck={false} className="font-mono" />
              {error ? <FieldDescription className="text-destructive">{error}</FieldDescription> : null}
            </Field>
          </FieldGroup>
          {canListen ? (
            <p className="text-sm text-muted-foreground">
              <b className="font-medium text-foreground">Listen only</b> reads it without joining: no channel slot used, and you can't send there until you join.
            </p>
          ) : null}
          <ChannelOverview />
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>Cancel</Button>
            {canListen ? (
              <Button type="button" variant="outline" disabled={busy || listening} onClick={() => void listenOnly()}>
                {listening ? <Spinner /> : <EarIcon />}Listen only
              </Button>
            ) : null}
            <Button type="submit" disabled={busy || listening || !name.trim()}>{busy ? <Spinner /> : <HashIcon />} Join</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}

// ---------------------------------------------------------------- new DM
function NewMessageDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const { data: state } = useAppState()
  const navigate = useNavigate()
  const people = useMemo(() => Object.values(state?.contacts ?? {}).filter((c) => c.type === "companion")
    .sort((a, b) => (b.last_advert ?? 0) - (a.last_advert ?? 0)), [state?.contacts])
  return (
    <CommandDialog open={open} onOpenChange={onOpenChange} title="New direct message"
      description="People whose advert your radio has heard">
      <Command>
      <CommandInput placeholder="Search people…" />
      <CommandList>
        <CommandEmpty>Nobody by that name yet. People appear after their advert reaches you.</CommandEmpty>
        <CommandGroup heading="People you can message">
          {people.map((c) => (
            <CommandItem key={c.pubkey} value={`${c.name} ${c.pubkey.slice(0, 8)}`}
              onSelect={() => { onOpenChange(false); navigate(convPath(dmConv(c.pubkey))) }}>
              <NodeAvatar name={c.name} className="size-6" />
              <span className="truncate">{c.name}</span>
              {/* CommandShortcut is shadcn's right-aligned slot (and hides the item's built-in check icon) */}
              <CommandShortcut className="shrink-0 pl-3 tracking-normal tabular-nums">advert {ago(c.last_advert)}</CommandShortcut>
            </CommandItem>
          ))}
        </CommandGroup>
      </CommandList>
      </Command>
    </CommandDialog>
  )
}

// ---------------------------------------------------------------- ⌘K
function CommandPalette({ open, onOpenChange, actions }: { open: boolean; onOpenChange: (o: boolean) => void; actions: Actions }) {
  const { data: state } = useAppState()
  const { resolved, setTheme } = useTheme()
  const navigate = useNavigate()
  const go = (to: string) => { onOpenChange(false); navigate(to) }
  const run = (fn: () => void) => { onOpenChange(false); fn() }
  const dms = Object.keys(state?.conversations ?? {}).filter((c) => c.startsWith("dm:"))
  const isRoom = (conv: string) => state?.contacts[conv.slice(3)]?.type === "room"
  const contacts = Object.values(state?.contacts ?? {})
  const people = contacts.filter((c) => c.type === "companion").sort((a, b) => (b.last_advert ?? 0) - (a.last_advert ?? 0)).slice(0, 50)
  const repeaters = contacts.filter((c) => c.type === "repeater").sort((a, b) => a.name.localeCompare(b.name)).slice(0, 80)
  return (
    <CommandDialog open={open} onOpenChange={onOpenChange} title="Search MeshChat" description="Jump to a conversation, person, repeater or page">
      <Command>
      <CommandInput placeholder="Search channels, people, repeaters, pages…" />
      <CommandList>
        <CommandEmpty>No results.</CommandEmpty>
        <CommandGroup heading="Conversations">
          {state?.channels.map((c) => (
            <CommandItem key={c.idx} value={`channel ${c.name}`} onSelect={() => go(convPath(chanConv(c.idx)))}><HashIcon />{c.name}</CommandItem>
          ))}
          {dms.map((c) => (
            <CommandItem key={c} value={`${isRoom(c) ? "room" : "dm"} ${convTitle(state, c)}`} onSelect={() => go(convPath(c))}>
              {isRoom(c) ? <UsersRoundIcon /> : <NodeAvatar name={convTitle(state, c)} className="size-5" />}{convTitle(state, c)}
              {isRoom(c) ? <CommandShortcut>room</CommandShortcut> : null}
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandSeparator />
        <CommandGroup heading="Actions">
          <CommandItem value="new direct message" onSelect={() => run(actions.newMessage)}><MessageSquarePlusIcon />New direct message</CommandItem>
          <CommandItem value="join channel" onSelect={() => run(actions.joinChannel)}><HashIcon />Join a channel</CommandItem>
          <CommandItem value="join room server" onSelect={() => run(() => actions.joinRoom())}><UsersRoundIcon />Join a room</CommandItem>
          <CommandItem value="add contact scan qr code" onSelect={() => run(() => actions.contactQr("scan"))}><ScanLineIcon />Add a contact from a QR code</CommandItem>
          <CommandItem value="share my contact qr code" onSelect={() => run(() => actions.contactQr("share"))}><QrCodeIcon />Show my contact QR code</CommandItem>
          <CommandItem value="send flood advert announce" onSelect={() => run(actions.advertise)}><MegaphoneIcon />Send flood advert</CommandItem>
          <CommandItem value="toggle theme dark light" onSelect={() => run(() => setTheme(resolved === "dark" ? "light" : "dark"))}>
            {resolved === "dark" ? <SunIcon /> : <MoonIcon />}Switch to {resolved === "dark" ? "light" : "dark"} theme
          </CommandItem>
        </CommandGroup>
        <CommandSeparator />
        <CommandGroup heading="Pages">
          <CommandItem value="map" onSelect={() => go("/map")}><MapIcon />Map<CommandShortcut>people & nodes</CommandShortcut></CommandItem>
          <CommandItem value="repeaters" onSelect={() => go("/repeaters")}><RadioTowerIcon />Repeaters</CommandItem>
          <CommandItem value="rooms room servers browse" onSelect={() => go("/rooms")}><UsersRoundIcon />Rooms<CommandShortcut>browse room servers</CommandShortcut></CommandItem>
          <CommandItem value="nodes" onSelect={() => go("/nodes")}><NetworkIcon />Nodes</CommandItem>
          <CommandItem value="packets" onSelect={() => go("/packets")}><ScrollTextIcon />Packets</CommandItem>
          <CommandItem value="settings" onSelect={() => go("/settings")}><SettingsIcon />Settings</CommandItem>
        </CommandGroup>
        <CommandSeparator />
        <CommandGroup heading="People">
          {people.map((c) => (
            <CommandItem key={c.pubkey} value={`person ${c.name} ${c.pubkey.slice(0, 8)}`} onSelect={() => go(convPath(dmConv(c.pubkey)))}>
              <UsersIcon />{c.name}<CommandShortcut>message</CommandShortcut>
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandGroup heading="Repeaters">
          {repeaters.map((c) => (
            <CommandItem key={c.pubkey} value={`repeater ${c.name} ${c.pubkey.slice(0, 8)}`} onSelect={() => go(`/repeaters/${c.pubkey}`)}>
              <RadioTowerIcon />{c.name}
            </CommandItem>
          ))}
        </CommandGroup>
      </CommandList>
      </Command>
    </CommandDialog>
  )
}
