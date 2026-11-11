// Room servers: the Join a room dialog and a room's details sheet. How rooms work is in lib/rooms.ts.
import { NodeAvatar, SignalBars, Stat } from "@/components/mesh-bits"
import { hasRoute, routeSummary } from "@/components/route-sheet"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter,
  AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList, CommandShortcut } from "@/components/ui/command"
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Sheet, SheetContent, SheetDescription, SheetHeader, SheetTitle } from "@/components/ui/sheet"
import { Spinner } from "@/components/ui/spinner"
import { api } from "@/lib/api"
import { ago, clock, duration, km, plural } from "@/lib/mesh"
import { keys, useAppState, useLive, useMessages, useNodes } from "@/lib/queries"
import { clockSkew, joinRoom, roomRecord, ROLE_TEXT } from "@/lib/rooms"
import { convPath, dmConv } from "@/lib/routes"
import type { Contact, RepeaterLive, RoomRole } from "@/lib/types"
import { useAsync } from "@/lib/use-async"
import { useQueryClient } from "@tanstack/react-query"
import { ArrowLeftIcon, LogInIcon, LogOutIcon, RouteIcon, UsersRoundIcon } from "lucide-react"
import { useEffect, useMemo, useState, type FormEvent, type ReactNode } from "react"
import { useNavigate } from "react-router"
import { toast } from "sonner"

// ---------------------------------------------------------------- join
export function JoinRoomDialog({ open, onOpenChange, initialKey }: { open: boolean; onOpenChange: (o: boolean) => void; initialKey: string | null }) {
  const navigate = useNavigate()
  const [key, setKey] = useState<string | null>(initialKey)
  useEffect(() => { if (open) setKey(initialKey) }, [open, initialKey])
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="gap-0 p-0 sm:max-w-md">
        {key ? <JoinForm roomKey={key} onBack={initialKey ? null : () => setKey(null)} onDone={() => onOpenChange(false)} />
          : <RoomPicker onPick={setKey} onBrowse={() => { onOpenChange(false); navigate("/rooms") }} />}
      </DialogContent>
    </Dialog>
  )
}

function RoomPicker({ onPick, onBrowse }: { onPick: (key: string) => void; onBrowse: () => void }) {
  const { data: state } = useAppState()
  const rooms = useMemo(() => Object.values(state?.contacts ?? {}).filter((c) => c.type === "room")
    .sort((a, b) => Number(!!roomRecord(state, b.pubkey) && !roomRecord(state, b.pubkey)!.left) - Number(!!roomRecord(state, a.pubkey) && !roomRecord(state, a.pubkey)!.left)
      || (b.last_advert ?? 0) - (a.last_advert ?? 0)), [state])
  const home = state?.home
  return (
    <>
      <DialogHeader className="p-4 pb-2">
        <DialogTitle>Join a room</DialogTitle>
        <DialogDescription>
          A room server keeps the posts people send it and passes them to everyone who joined. Pick one your radio knows (its advert reached you),
          or <button type="button" className="underline underline-offset-2 hover:text-foreground" onClick={onBrowse}>browse all rooms</button> with
          distances, signal and routes.
        </DialogDescription>
      </DialogHeader>
      <Command className="border-t">
        <CommandInput placeholder="Search rooms…" />
        <CommandList className="max-h-80">
          <CommandEmpty>No room by that name. Rooms appear here after their advert reaches your radio.</CommandEmpty>
          <CommandGroup heading={plural(rooms.length, "room in your contacts", "rooms in your contacts")}>
            {rooms.map((c) => {
              const r = roomRecord(state, c.pubkey)
              const dist = home && c.lat != null && c.lon != null ? km(home, { lat: c.lat, lon: c.lon }) : null
              return (
                <CommandItem key={c.pubkey} value={`${c.name} ${c.pubkey.slice(0, 8)}`} onSelect={() => onPick(c.pubkey)}>
                  <NodeAvatar name={c.name} className="size-6" />
                  <span className="min-w-0 flex-1 truncate">{c.name}</span>
                  {r && !r.left ? <Badge variant="secondary" className="font-normal">joined</Badge> : null}
                  <CommandShortcut className="shrink-0 pl-2 tracking-normal tabular-nums">
                    {dist != null ? `${dist.toFixed(0)} km · ` : ""}advert {ago(c.last_advert)}
                  </CommandShortcut>
                </CommandItem>
              )
            })}
          </CommandGroup>
        </CommandList>
      </Command>
    </>
  )
}

function JoinForm({ roomKey, onBack, onDone }: { roomKey: string; onBack: (() => void) | null; onDone: () => void }) {
  const { data: state } = useAppState()
  const nodes = useNodes()
  const qc = useQueryClient()
  const navigate = useNavigate()
  const [password, setPassword] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const c = state?.contacts[roomKey]
  const rec = roomRecord(state, roomKey)
  if (!c) return <p className="p-4 text-sm text-muted-foreground">That room isn't in your contacts any more.</p>

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    setBusy(true); setError(null)
    const pwd = password
    setPassword("")   // not kept: the radio sends it once, in the login
    try {
      const res = await joinRoom(qc, roomKey, pwd)
      if (!res.ok) { setError(res.error ?? "No answer from the room."); return }
      const role = res.login?.role
      toast.success(`Joined ${c.name}`, { description: role ? ROLE_TEXT[role].can : "Its posts are on their way." })
      onDone()
      navigate(convPath(dmConv(roomKey)))
    } catch (err) { setError((err as Error).message) } finally { setBusy(false) }
  }
  return (
    <form onSubmit={submit} className="grid gap-4 p-4">
      <DialogHeader>
        <DialogTitle className="flex items-center gap-2">
          {onBack ? <Button type="button" size="icon-sm" variant="ghost" className="-ml-2" onClick={onBack} aria-label="Back to the list"><ArrowLeftIcon /></Button> : null}
          {rec && !rec.left ? "Log in to" : "Join"} {c.name}
        </DialogTitle>
        <DialogDescription>
          Your radio logs in and tells the room the newest post it has; the room then sends you the newer ones, one at a time, and each
          new post as it arrives. {hasRoute(c) ? `It goes by your saved ${routeSummary(c, state, nodes).replace(/^route /, "route, ")}.`
            : "There's no saved route to it yet, so the login floods, and the room's answer brings one back."}
        </DialogDescription>
      </DialogHeader>
      <Field>
        <FieldLabel htmlFor="room-pw">Password <span className="font-normal text-muted-foreground">(if the room has one)</span></FieldLabel>
        <Input id="room-pw" type="password" value={password} onChange={(e) => setPassword(e.target.value)} maxLength={15}
          autoComplete="off" spellCheck={false} autoFocus placeholder="Leave empty to join as a guest" />
        <FieldDescription>
          Without one you join as a guest, if the room allows guests (some only let guests read). A wrong password gets no answer at all.
          MeshChat doesn't keep it.
        </FieldDescription>
        {error ? <FieldDescription className="text-destructive">{error}</FieldDescription> : null}
      </Field>
      {busy ? <p className="flex items-center gap-2 text-sm text-muted-foreground" role="status"><Spinner />Logging in… answers take 5–30 seconds.</p> : null}
      <DialogFooter>
        <Button type="button" variant="outline" onClick={onDone} disabled={busy}>Cancel</Button>
        <Button type="submit" disabled={busy || !state?.connected}>{busy ? <Spinner /> : <LogInIcon />}{rec && !rec.left ? "Log in" : "Join"}</Button>
      </DialogFooter>
    </form>
  )
}

// ---------------------------------------------------------------- details
export function RoomSheet({ contact, open, onOpenChange, onRoute, onJoin }: {
  contact: Contact | undefined; open: boolean; onOpenChange: (o: boolean) => void; onRoute: () => void; onJoin: () => void
}) {
  return (
    <Sheet open={open && !!contact} onOpenChange={onOpenChange}>
      <SheetContent side="right" className="gap-0 p-0 pt-safe pb-safe data-[side=right]:w-full data-[side=right]:sm:max-w-xl [&>[data-slot=sheet-close]]:top-[calc(env(safe-area-inset-top)+0.75rem)]">
        <SheetHeader className="border-b pr-12">
          <SheetTitle className="flex items-center gap-2"><UsersRoundIcon className="size-4 text-muted-foreground" />{contact?.name}</SheetTitle>
          <SheetDescription>Room server: your membership, its posts and how it's doing.</SheetDescription>
        </SheetHeader>
        {contact ? <RoomDetails c={contact} onRoute={() => { onOpenChange(false); onRoute() }} onJoin={() => { onOpenChange(false); onJoin() }} onLeft={() => onOpenChange(false)} /> : null}
      </SheetContent>
    </Sheet>
  )
}

function Section({ title, aside, children }: { title: string; aside?: ReactNode; children: ReactNode }) {
  return (
    <section className="grid gap-2">
      <div className="flex items-baseline justify-between gap-2">
        <h3 className="text-sm font-medium">{title}</h3>
        {aside ? <div className="text-xs text-muted-foreground">{aside}</div> : null}
      </div>
      {children}
    </section>
  )
}

function RoomDetails({ c, onRoute, onJoin, onLeft }: { c: Contact; onRoute: () => void; onJoin: () => void; onLeft: () => void }) {
  const { data: state } = useAppState()
  const nodes = useNodes()
  const { data: live } = useLive()
  const { data: messages } = useMessages(dmConv(c.pubkey))
  const rec = roomRecord(state, c.pubkey)
  const joined = !!rec && !rec.left
  const l: RepeaterLive | undefined = live?.[c.pubkey]
  const posts = useMemo(() => (messages ?? []).filter((m) => m.direction === "in"), [messages])
  const mine = useMemo(() => (messages ?? []).filter((m) => m.direction === "out"), [messages])
  const authors = useMemo(() => {
    const by = new Map<string, { name: string; n: number; last: number }>()
    for (const m of posts) {
      const k = m.author ?? m.sender ?? "?"
      const a = by.get(k) ?? { name: m.sender ?? k, n: 0, last: 0 }
      a.n++; a.last = Math.max(a.last, m.sender_ts ?? m.ts)
      by.set(k, a)
    }
    return [...by.values()].sort((a, b) => b.n - a.n)
  }, [posts])
  const newest = c.sync_since || Math.max(0, ...posts.map((m) => m.sender_ts ?? 0)) || null
  const role = rec?.role ?? l?.login?.role ?? null

  return (
    <div className="min-h-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain">
      <div className="grid gap-6 p-4">
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
          <Stat value={joined ? (role ? ROLE_TEXT[role].label : "joined") : rec?.left ? "left" : "—"} label="you"
            hint={joined ? (role ? ROLE_TEXT[role].can : "the room didn't say what you can do") : rec?.left ? `left ${ago(rec.left_at)}` : posts.length ? "a member from another app" : "not joined"} />
          <Stat value={rec?.login_at ? ago(rec.login_at) : "—"} label="last login" hint={rec?.joined ? `joined ${new Date(rec.joined * 1000).toLocaleDateString()}` : "not from MeshChat"} />
          <Stat value={posts.length} label="posts here" hint={mine.length ? `and ${plural(mine.length, "post", "posts")} of yours` : "none of yours yet"} />
          <Stat value={authors.length} label="authors" hint={authors[0] ? `most: ${authors[0].name}` : "—"} />
          <Stat value={newest ? ago(newest) : "—"} label="newest post you have" hint={newest ? `${clock(newest)}: the room sends what's newer` : "the room sends its recent posts"} />
          <Stat value={hasRoute(c) ? (c.out_path_len === 0 ? "direct" : plural(c.out_path_len!, "hop", "hops")) : "flood"} label="route" hint={l?.ts ? `last answer ${ago(l.ts)}` : "no answer yet"} />
        </div>

        <Membership c={c} joined={joined} role={role} onJoin={onJoin} onLeft={onLeft} />

        <Section title="Room status" aside={l?.ts ? `as of ${ago(l.ts)}` : undefined}>
          {l?.status ? <Status l={l} /> : (
            <p className="text-sm text-muted-foreground">
              {l?.error ?? "No status yet. Logging in asks the room for it too."}
            </p>
          )}
        </Section>

        {authors.length ? (
          <Section title="Who posts here" aside="from the posts you have">
            <ol className="divide-y rounded-lg border text-sm">
              {authors.slice(0, 12).map((a) => (
                <li key={a.name} className="flex items-center gap-2 px-3 py-1.5">
                  <NodeAvatar name={a.name} className="size-5" />
                  <span className="min-w-0 flex-1 truncate">{a.name}</span>
                  <span className="text-xs text-muted-foreground tabular-nums">{plural(a.n, "post", "posts")} · last {ago(a.last)}</span>
                </li>
              ))}
            </ol>
          </Section>
        ) : null}

        <Section title="Route" aside={<Button size="xs" variant="ghost" onClick={onRoute}><RouteIcon />Details</Button>}>
          <p className="text-sm">{routeSummary(c, state, nodes).replace(/^./, (x) => x.toUpperCase())}.</p>
          <p className="text-xs text-muted-foreground">
            Your posts go to the room like DMs, and its receipt means it stored them. The room pushes posts to you on its own route to
            you, waiting for your radio's receipt before sending the next; after three missed receipts it stops until you log in again.
          </p>
        </Section>
      </div>
    </div>
  )
}

function Membership({ c, joined, role, onJoin, onLeft }: { c: Contact; joined: boolean; role: RoomRole | null; onJoin: () => void; onLeft: () => void }) {
  const qc = useQueryClient()
  const { run, isBusy } = useAsync()
  const [confirm, setConfirm] = useState(false)
  const leave = () => run(async () => {
    await api.leaveRoom(c.pubkey)
    await qc.invalidateQueries({ queryKey: keys.state })
    setConfirm(false); onLeft()
  }, { error: "Couldn't leave", success: { title: `Left ${c.name}`, description: "Its posts stay here; new ones are ignored." } })
  return (
    <Section title="Membership">
      <p className="text-sm text-muted-foreground">
        {joined ? (role ? ROLE_TEXT[role].can : "You're logged in.") : "Join to get its posts, and to post if the room lets you."}
        {joined && role && !ROLE_TEXT[role].post ? " Log in again with the room's password to post." : ""}
        {" "}Logging in again also brings any posts you missed.
      </p>
      <div className="flex flex-wrap gap-2">
        <Button variant="outline" onClick={onJoin}><LogInIcon />{joined ? "Log in again" : "Join"}</Button>
        {joined ? <Button variant="outline" onClick={() => setConfirm(true)}><LogOutIcon />Leave room</Button> : null}
      </div>
      <AlertDialog open={confirm} onOpenChange={setConfirm}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Leave {c.name}?</AlertDialogTitle>
            <AlertDialogDescription>
              MeshChat stops showing its new posts; the ones you have stay. MeshCore has no “leave” message, so the room keeps sending
              new posts to your radio (and your radio keeps confirming them) until the room forgets you. You can join again any time.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction variant="destructive" disabled={isBusy()} onClick={(e) => { e.preventDefault(); void leave() }}>Leave</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </Section>
  )
}

function Status({ l }: { l: RepeaterLive }) {
  const s = l.status!
  const skew = clockSkew(l)
  const rows: [string, ReactNode][] = [
    ["Up for", duration(s.uptime)],
    ["Posts", s.posted != null ? `${s.posted} stored since it started · ${plural(s.post_pushes ?? 0, "push", "pushes")} to members` : "not reported"],
    ["Battery", s.bat ? `${(s.bat / 1000).toFixed(2)} V` : "—"],
    ["Its last packet", <span className="inline-flex items-center gap-1">{s.last_snr != null ? <><SignalBars snr={s.last_snr} />{s.last_snr} dB</> : "—"}{s.last_rssi ? `, ${s.last_rssi} dBm` : ""}</span>],
    ["Noise floor", `${s.noise_floor} dBm`],
    ["Traffic", `${s.nb_recv.toLocaleString()} received · ${s.nb_sent.toLocaleString()} sent (${s.sent_direct.toLocaleString()} direct, ${s.sent_flood.toLocaleString()} flood)`],
    ["Airtime", `${duration(s.airtime)} transmitting`],
    ["Queue", `${s.tx_queue_len} waiting to send${s.full_evts ? ` · ${plural(s.full_evts, "error", "errors")}` : ""}`],
  ]
  if (skew != null) rows.push(["Its clock", Math.abs(skew) < 30 ? "in step with yours" : `${duration(Math.abs(skew))} ${skew > 0 ? "ahead" : "behind"}`])
  if (l.login?.fw_level != null) rows.push(["Firmware level", String(l.login.fw_level)])
  return (
    <dl className="grid grid-cols-[7.5rem_1fr] gap-x-3 gap-y-1.5 rounded-lg border p-3 text-sm">
      {rows.map(([k, v]) => <div key={k} className="contents"><dt className="text-muted-foreground">{k}</dt><dd className="min-w-0 wrap-anywhere">{v}</dd></div>)}
    </dl>
  )
}
