import { Page } from "@/components/page"
import { useActions } from "@/components/app-provider"
import { Composer, type ComposerHandle, type TagCandidate } from "@/components/composer"
import { MessageText, NodeAvatar, SignalBars, TagChip } from "@/components/mesh-bits"
import { Hint } from "@/components/hint"
import { MessageDetails } from "@/components/message-details"
import { PersonMenu } from "@/components/person-menu"
import { QuietRepeaterBar } from "@/components/quiet-repeater"
import { hasRoute, RouteSheet, routeSummary, useResetPath } from "@/components/route-sheet"
import { RoomSheet } from "@/components/rooms"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter,
  AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu"
import { Empty, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty"
import { Skeleton } from "@/components/ui/skeleton"
import { api } from "@/lib/api"
import { useLastRead } from "@/lib/local"
import { chanConv, convPath } from "@/lib/routes"
import { useAsync } from "@/lib/use-async"
import { useDeleteMessages } from "@/lib/use-delete-messages"
import { useListening } from "@/lib/use-listening"
import { ago, clock, convTitle, dayLabel, isChannel, isListened, plural } from "@/lib/mesh"
import { keys, useAppState, useMessages, useNodes, usePeople } from "@/lib/queries"
import { roomRecord, ROLE_TEXT } from "@/lib/rooms"
import type { AppState, Contact, Message, Room } from "@/lib/types"
import { cn } from "@/lib/utils"
import { useQueryClient } from "@tanstack/react-query"
import {
  AlertCircleIcon, ArrowDownIcon, CheckCheckIcon, CheckIcon, ClockIcon, CopyIcon, EarIcon, EllipsisIcon, HashIcon, InfoIcon, LogInIcon, LogOutIcon, MapPinIcon, RouteOffIcon, MegaphoneIcon, MessagesSquareIcon, RotateCwIcon, RouteIcon, Trash2Icon, UsersRoundIcon, XCircleIcon,
} from "lucide-react"
import { Fragment, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import { Navigate, useNavigate, useParams } from "react-router"
import { toast } from "sonner"

const GROUP_GAP = 5 * 60   // same sender within 5 min = one group
// A busy channel holds hundreds of messages, and drawing them all on every switch blocked the app for
// half a second (two ~250 ms tasks for 300 messages). So the newest are drawn first, and older ones are
// added as the reader scrolls up, keeping their place.
const FIRST = 50, MORE = 100

export function ChatPage() {
  const conv = decodeURIComponent(useParams().conv ?? "")
  const { data: state } = useAppState()
  if (state && !isChannel(conv) && !isListened(conv) && !conv.startsWith("dm:")) return <Navigate to="/c/chan:0" replace />
  return <Chat key={conv} conv={conv} state={state} />
}

function Chat({ conv, state }: { conv: string; state: AppState | undefined }) {
  const qc = useQueryClient()
  const { data: messages, isLoading } = useMessages(conv)
  const { data: people } = usePeople()
  const { advertise, showOnMap, joinRoom } = useActions()
  const [lastRead, setLastRead] = useLastRead()
  const composer = useRef<ComposerHandle>(null)
  const scroller = useRef<HTMLDivElement>(null)
  const atBottom = useRef(true)
  const [unseen, setUnseen] = useState(0)
  const [details, setDetails] = useState<Message | null>(null)   // the message whose Details sheet is open
  const [sheet, setSheet] = useState<"route" | "room" | null>(null)   // the contact's Route or the room's details

  const listened = isListened(conv)   // a hashtag channel the radio reads without having joined it
  const nodes = useNodes()            // to name the repeaters on a contact's saved route
  const channel = isChannel(conv) || listened
  const contactKey = channel ? null : conv.slice(3)
  const contact = contactKey ? state?.contacts[contactKey] : undefined
  const room = contact?.type === "room"
  const roomRec = room && contactKey ? roomRecord(state, contactKey) : null
  const joined = !!roomRec && !roomRec.left
  // posts arriving means the room has us as a member (perhaps joined from another app)
  const member = joined || (!roomRec?.left && !!messages?.some((m) => m.direction === "in"))
  const title = convTitle(state, conv)
  const me = state?.self.name ?? ""
  const limit = (state?.limits.max_text_bytes ?? 150) - (channel ? new TextEncoder().encode(me).length + 2 : 0)
  const lastId = messages?.at(-1)?.id ?? 0

  // ---- scrolling: stick to the bottom unless the reader scrolled up
  const scrollToBottom = (smooth = false) => {
    const el = scroller.current
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: smooth ? "smooth" : "auto" })
  }
  const markRead = useCallback(() => {
    if (lastId && !document.hidden && (lastRead[conv] ?? 0) < lastId) setLastRead((r) => ({ ...r, [conv]: lastId }))
  }, [conv, lastId, lastRead, setLastRead])
  // ---- how many of the newest messages are drawn (see FIRST): enough to include the first unread one
  const [shown, setShown] = useState(FIRST)
  const anchor = useRef<number | null>(null)   // distance from the bottom to keep while older ones are added
  const sized = useRef(false)
  useLayoutEffect(() => {
    if (sized.current || !messages) return
    sized.current = true
    const lr = lastRead[conv] ?? 0
    const i = messages.findIndex((m) => m.id > lr && m.direction === "in")
    if (i >= 0 && messages.length - i + 5 > FIRST) setShown(Math.min(messages.length - i + 5, FIRST + 2 * MORE))
  }, [messages, lastRead, conv])   // sized once, when the messages first arrive (the ref guards later runs)
  const showMore = useCallback(() => {
    const el = scroller.current
    if (!el || !messages || shown >= messages.length) return
    anchor.current = el.scrollHeight - el.scrollTop
    setShown((n) => n + MORE)
  }, [messages, shown])
  useLayoutEffect(() => {
    const el = scroller.current
    if (el && anchor.current != null) { el.scrollTop = el.scrollHeight - anchor.current; anchor.current = null }
  }, [shown])

  const prevCount = useRef(0)
  useLayoutEffect(() => {
    const n = messages?.length ?? 0
    const added = n - prevCount.current
    const mine = messages?.at(-1)?.direction === "out"
    if (prevCount.current === 0 || atBottom.current || (added > 0 && mine)) { scrollToBottom(prevCount.current !== 0); setUnseen(0) }
    else if (added > 0) setUnseen((u) => u + added)
    prevCount.current = n
  }, [messages])
  useEffect(() => { if (atBottom.current) markRead() }, [markRead])
  useEffect(() => {
    const onVis = () => atBottom.current && markRead()
    document.addEventListener("visibilitychange", onVis)
    return () => document.removeEventListener("visibilitychange", onVis)
  }, [markRead])
  const onScroll = () => {
    const el = scroller.current!
    atBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80
    if (atBottom.current) { setUnseen(0); markRead() }
    if (el.scrollTop < el.clientHeight) showMore()   // within a screen of the top: add older ones before they're needed
  }

  // ---- tag candidates: people in this channel first, then other posters, then contacts
  const candidates = useMemo<TagCandidate[]>(() => {
    const out = new Map<string, string>()
    const ppl = [...(people?.values() ?? [])].sort((a, b) =>
      Number(b.convs.includes(conv)) - Number(a.convs.includes(conv)) || b.last_ts - a.last_ts)
    for (const p of ppl) out.set(p.name, `${p.convs.includes(conv) ? "here" : "posted"} ${ago(p.last_ts)}`)
    for (const c of Object.values(state?.contacts ?? {})) if (c.type === "companion" && !out.has(c.name)) out.set(c.name, "contact")
    out.delete(me)
    return [...out].map(([name, hint]) => ({ name, hint }))
  }, [people, state?.contacts, conv, me])

  const send = async (text: string) => {
    try {
      const m = await api.send(conv, text)
      qc.setQueryData<Message[]>(keys.messages(conv), (old) => (old && !old.some((x) => x.id === m.id) ? [...old, m] : old))
      return true
    } catch (e) {
      toast.error("Not sent", { description: (e as Error).message })
      return false
    }
  }

  // ---- header
  const activeHere = useMemo(() => [...(people?.values() ?? [])].filter((p) => p.convs.includes(conv)).length, [people, conv])
  const { join: joinChannel, stop: stopListening } = useListening()
  const { run, busy: joining } = useAsync()
  const stop = () => run(() => stopListening(title, true), { error: "Couldn't stop", success: `Stopped listening to ${title}` }, "stop")
  const join = () => run(() => joinChannel(title), {
    error: "Couldn't join",
    success: { title: `Joined ${title}`, description: "New messages arrive there. What you heard while listening stays here." },
  })
  const description = listened
    ? "Listening without joining: you can read it, not send"
    : channel
    ? conv === "chan:0" ? "Open channel: anyone on these radio settings can read it" : `Channel · ${plural(activeHere, "person", "people")} active this week`
    : contact ? (
      <button type="button" onClick={() => setSheet(room ? "room" : "route")} title={room ? "Room details" : "Route details"}
        className="block max-w-full truncate rounded text-left hover:text-foreground hover:underline underline-offset-2 focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">
        {room ? `Room · ${roomStanding(roomRec, member)} · ${routeSummary(contact, state, nodes)}`
          : `${contact.type} · ${routeSummary(contact, state, nodes)} · advert ${ago(contact.last_advert)}`}
      </button>
    ) : "Not in your contacts"
  // a room learns your key from the login, so posting there needs no advert
  const needAdvert = !!state && !channel && !room && !state.advertised?.flood
  const disabledReason = !state?.connected ? "Radio not connected" : !channel && !contact ? "Not a contact, so it can't be messaged"
    : room && roomRec?.left ? "You left this room. Join it again to post."
    : room && !member ? "Join the room to post here."
    : room && roomRec?.role && !ROLE_TEXT[roomRec.role].post ? `${ROLE_TEXT[roomRec.role].can}` : null

  return (
    <Page title={<span className="flex items-center gap-1.5">{channel ? <HashIcon className="size-4 text-muted-foreground" /> : room ? <UsersRoundIcon className="size-4 text-muted-foreground" /> : <NodeAvatar name={title} className="size-5" />}{channel ? title.replace(/^#/, "") : title}</span>}
        description={description} actions={<>
          {listened ? (
            <>
              <Button size="sm" variant="ghost" onClick={() => void stop()} disabled={!!joining}>Stop listening</Button>
              <Button size="sm" onClick={() => void join()} disabled={!!joining || !state?.connected}>Join</Button>
            </>
          ) : null}
          {room && member && !joined ? <Button size="sm" variant="outline" onClick={() => joinRoom(contactKey!)} disabled={!state?.connected}><LogInIcon />Log in</Button> : null}
          {room ? <Button size="icon-sm" variant="ghost" onClick={() => setSheet("room")} aria-label="Room details"><InfoIcon /></Button> : null}
          {!channel && contact && contact.lat != null ? (
            <Button size="sm" variant="outline" onClick={() => showOnMap({ kind: "point", lat: contact.lat!, lon: contact.lon!, label: contact.name })}>
              <MapPinIcon />Map
            </Button>
          ) : null}
          {!channel ? <ConversationMenu conv={conv} title={title} count={messages?.length ?? 0} contact={contact}
            onRoute={() => setSheet("route")} room={room ? { joined, onDetails: () => setSheet("room"), onJoin: () => joinRoom(contactKey!) } : undefined} /> : null}
          {isChannel(conv) && conv !== chanConv(0) ? <ChannelMenu idx={Number(conv.slice(5))} title={title} /> : null}
        </>}>

      {needAdvert ? (
        <Alert className="m-3 mb-0 w-auto">
          <MegaphoneIcon />
          <AlertTitle>{title} can't read your messages yet</AlertTitle>
          <AlertDescription className="grid justify-items-start gap-2">
            <span>DMs are encrypted to their key and identified by yours. Their radio learns your key from your advert, and you haven't sent one.</span>
            <Button size="sm" onClick={advertise}><MegaphoneIcon />Send flood advert</Button>
          </AlertDescription>
        </Alert>
      ) : null}

      {room && !member ? (
        <Alert className="m-3 mb-0 w-auto">
          <UsersRoundIcon />
          <AlertTitle>{roomRec?.left ? `You left ${title}` : `Join ${title} to get its posts`}</AlertTitle>
          <AlertDescription className="grid justify-items-start gap-2">
            <span>{roomRec?.left ? "New posts from it are ignored. Join again to get them, including the ones you missed."
              : "Your radio logs in, and the room sends you its recent posts and every new one."}</span>
            <Button size="sm" onClick={() => joinRoom(contactKey!)} disabled={!state?.connected}><LogInIcon />{roomRec?.left ? "Join again" : "Join"}</Button>
          </AlertDescription>
        </Alert>
      ) : null}

      <div className="relative min-h-0 flex-1">
        <div ref={scroller} onScroll={onScroll} className="h-full overflow-x-hidden overflow-y-auto px-3 py-4 sm:px-6" aria-live="polite" aria-label={`Messages in ${title}`}>
          {isLoading ? <DelayedSkeleton /> : !messages?.length ? (
            <Empty className="h-full">
              <EmptyHeader>
                <EmptyMedia variant="icon"><MessagesSquareIcon /></EmptyMedia>
                <EmptyTitle>No messages yet</EmptyTitle>
                <EmptyDescription>
                  {channel ? "Messages on this channel appear here as your radio hears them. MeshChat keeps the history."
                    : room ? (member ? "No posts yet. After you join, the room sends its recent posts within a minute or so, one at a time." : `Join ${title} to see its posts.`)
                    : `Say hi to ${title}. You'll see “delivered” when their radio confirms it.`}
                </EmptyDescription>
              </EmptyHeader>
            </Empty>
          ) : (
            <>
            {shown < messages.length ? (
              <div className="flex justify-center pb-2">
                <Button size="sm" variant="ghost" className="text-muted-foreground" onClick={showMore}>
                  Show earlier messages ({messages.length - shown} more)
                </Button>
              </div>
            ) : null}
            <MessageList messages={shown < messages.length ? messages.slice(-shown) : messages} me={me} channel={channel} room={room} onMention={(n) => composer.current?.mention(n)}
              onRoute={(m) => showOnMap({ kind: "route", message: m })} onDetails={setDetails} unreadAfter={lastRead[conv] ?? 0} />
            </>
          )}
        </div>
        {unseen > 0 ? (
          <Button size="sm" className="absolute bottom-3 left-1/2 -translate-x-1/2 rounded-full shadow-lg"
            onClick={() => { scrollToBottom(true); setUnseen(0) }}>
            <ArrowDownIcon />{plural(unseen, "new message", "new messages")}
          </Button>
        ) : null}
      </div>

      {listened ? (
        <div className="flex flex-wrap items-center gap-x-3 gap-y-2 border-t bg-background p-3 text-sm text-muted-foreground">
          <EarIcon className="size-4 shrink-0" />
          <span className="min-w-0 flex-1">You're listening to {title}. Join it to send messages there; it then uses one of the radio's channel slots.</span>
          <Button size="sm" onClick={() => void join()} disabled={!!joining || !state?.connected}>Join {title}</Button>
        </div>
      ) : (
        <>
          <QuietRepeaterBar />
          <Composer ref={composer} limit={limit} candidates={candidates} disabledReason={disabledReason} onSend={send}
            placeholder={channel ? `Message ${title}` : room ? `Post to ${title}` : `Message ${title} privately`} />
        </>
      )}
      <MessageDetails message={details} onClose={() => setDetails(null)} />
      <RouteSheet contact={contact} open={sheet === "route"} onOpenChange={(o) => setSheet(o ? "route" : null)} />
      {room ? <RoomSheet contact={contact} open={sheet === "room"} onOpenChange={(o) => setSheet(o ? "room" : null)}
        onRoute={() => setSheet("route")} onJoin={() => joinRoom(contactKey!)} /> : null}
    </Page>
  )
}

function MessageList({ messages, me, channel, room, onMention, onRoute, onDetails, unreadAfter }: {
  messages: Message[]; me: string; channel: boolean; room: boolean; unreadAfter: number
  onMention: (name: string) => void; onRoute: (m: Message) => void; onDetails: (m: Message) => void
}) {
  const { data: state } = useAppState()
  const firstUnread = useRef(messages.find((m) => m.id > unreadAfter && m.direction === "in")?.id).current
  const renderTag = (name: string, onPrimary: boolean) =>
    name === me ? <TagChip name={name} me onPrimary={onPrimary} />
      : <PersonMenu name={name} onMention={onMention}><TagChip name={name} onPrimary={onPrimary} /></PersonMenu>

  // One section per day, so a day's label sticks to the top only while that day is on screen
  // (in one flat list every label stayed stuck, and the older, wider ones peeked out behind).
  // Days follow arrival, like the list itself: by the senders' clocks, some of which run behind,
  // the labels flipped Yesterday/Today/Yesterday around midnight. Each message still shows its time.
  const days: { day: string; items: { m: Message; t: number }[] }[] = []
  for (const m of messages) {
    // room posts carry the room's time of posting (they can reach you days later, when you log in)
    const t = m.sender_ts && (room || m.ts - m.sender_ts < 86400) ? m.sender_ts : m.ts
    const day = dayLabel(m.ts)
    if (days.at(-1)?.day !== day) days.push({ day, items: [] })
    days.at(-1)!.items.push({ m, t })
  }
  return (
    <div className="flex flex-col">
      {days.map(({ day, items }) => (
        <section key={`${day}:${items[0].m.id}`} aria-label={day}>
          <h2 className="sticky top-0 z-10 my-3 flex justify-center"><span className="rounded-full border bg-background px-3 py-0.5 text-xs font-normal text-muted-foreground shadow-xs">{day}</span></h2>
          <ol className="flex flex-col">
            {items.map(({ m, t }, i) => {
              const prev = items[i - 1]?.m
              const grouped = prev && prev.direction === m.direction && prev.sender === m.sender && t - (prev.sender_ts ?? prev.ts) < GROUP_GAP
              const mentioned = m.direction === "in" && !!me && m.text.includes(`@[${me}]`)
              const contact = !channel && m.direction === "in" ? state?.contacts[m.conv.slice(3)] : undefined
              return (
                <Fragment key={m.id}>
                  {m.id === firstUnread ? <li className="my-2 flex items-center gap-2 text-xs font-medium text-primary"><span className="h-px flex-1 bg-primary/40" />New<span className="h-px flex-1 bg-primary/40" /></li> : null}
                  <li className={cn("group flex gap-2.5", grouped ? "mt-0.5" : "mt-3", m.direction === "out" && "flex-row-reverse")}>
                    {m.direction === "in" ? (
                      <div className="w-8 shrink-0">{!grouped ? <NodeAvatar name={m.sender || contact?.name || "?"} /> : null}</div>
                    ) : null}
                    {/* each bubble as wide as its text (a flex column would otherwise stretch it to the meta
                        line below), capped so long lines stay readable */}
                    <div className={cn("flex min-w-0 max-w-[min(48rem,80%)] flex-col", m.direction === "out" ? "items-end" : "items-start")}>
                      {!grouped && m.direction === "in" && m.sender ? (
                        channel ? (
                          <PersonMenu name={m.sender} onMention={onMention}>
                            <button className="mb-0.5 self-start rounded text-xs font-semibold text-foreground/90 hover:underline focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">{m.sender}</button>
                          </PersonMenu>
                        ) : <span className="mb-0.5 text-xs font-semibold text-foreground/90">
                          {room && m.author && m.sender === m.author ? <>Unknown member <code className="font-mono font-normal text-muted-foreground">{m.author}</code></> : m.sender}
                        </span>
                      ) : null}
                      {/* wrap-anywhere, not break-words: a shrink-to-fit bubble sizes itself to its longest word,
                          so a long link would push it (and the page) past the screen edge */}
                      <div className={cn("max-w-full rounded-2xl px-3 py-1.5 text-sm leading-relaxed wrap-anywhere whitespace-pre-wrap",
                        m.direction === "out" ? "rounded-br-md bg-primary text-primary-foreground" : "rounded-bl-md bg-muted",
                        mentioned && "ring-2 ring-primary/60")}>
                        <MessageText text={m.text} renderTag={(name) => renderTag(name, m.direction === "out")} />
                      </div>
                      <MessageMeta m={m} t={t} room={room} onRoute={onRoute} onDetails={onDetails} />
                    </div>
                  </li>
                </Fragment>
              )
            })}
          </ol>
        </section>
      ))}
    </div>
  )
}

function MessageMeta({ m, t, room, onRoute, onDetails }: { m: Message; t: number; room: boolean; onRoute: (m: Message) => void; onDetails: (m: Message) => void }) {
  const queued = m.direction === "in" && m.sender_ts != null && m.ts - m.sender_ts > 120
  return (
    <div className={cn("mt-0.5 flex items-center gap-2 px-1 text-[11px] text-muted-foreground", m.direction === "out" && "flex-row-reverse")}>
      {/* a time from another day than its arrival (an old room post, a late DM) carries its date */}
      <time dateTime={new Date(t * 1000).toISOString()} title={new Date(t * 1000).toLocaleString()}>
        {new Date(t * 1000).toDateString() === new Date(m.ts * 1000).toDateString() ? clock(t)
          : `${new Date(t * 1000).toLocaleDateString([], { day: "numeric", month: "short", ...(new Date(t * 1000).getFullYear() !== new Date().getFullYear() ? { year: "numeric" } : {}) })}, ${clock(t)}`}
      </time>
      {queued ? (
        <Hint content={room ? `Posted then; the room sent it to you ${new Date(m.ts * 1000).toLocaleString()}`
          : `Stored in your radio while MeshChat was closed, received ${new Date(m.ts * 1000).toLocaleString()}`}>
          <button type="button" className="rounded focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">· {room ? `synced ${ago(m.ts)}` : "delivered late"}</button>
        </Hint>
      ) : null}
      {m.direction === "in" && m.hops != null && m.hops >= 0 ? <span>{m.hops === 0 ? "direct" : plural(m.hops, "hop", "hops")}</span> : null}
      {m.direction === "in" && m.snr != null ? <span className="inline-flex items-center gap-1"><SignalBars snr={m.snr} />{m.snr} dB</span> : null}
      {m.direction === "out" ? <OutStatus m={m} room={room} /> : null}
      {m.path ? (
        <Hint content="Show the repeaters this message passed through" tapToShow={false}>
          {/* -m-3 p-3: a 36 px target for a finger without moving the layout */}
          <button onClick={() => onRoute(m)} aria-label="Show route on the map"
            className="-m-3 inline-flex items-center gap-0.5 rounded p-3 opacity-70 hover:opacity-100 focus-visible:opacity-100 focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">
            <RouteIcon className="size-3" /><span className="sr-only sm:not-sr-only">route</span>
          </button>
        </Hint>
      ) : null}
      <MessageMenu m={m} onDetails={onDetails} />
    </div>
  )
}

/** Per-message actions. Shown on hover (and focus) with a mouse; always there on touch screens. */
function MessageMenu({ m, onDetails }: { m: Message; onDetails: (m: Message) => void }) {
  const { deleteMessage } = useDeleteMessages()
  const { run } = useAsync()
  const canCopy = typeof navigator !== "undefined" && !!navigator.clipboard && window.isSecureContext   // not on the radio's plain-HTTP page
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button type="button" aria-label="Message actions"
          className="-m-2.5 rounded p-2.5 opacity-70 hover:opacity-100 focus-visible:opacity-100 focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none data-[state=open]:opacity-100 [@media(hover:hover)]:opacity-0 [@media(hover:hover)]:group-hover:opacity-70">
          <EllipsisIcon className="size-3.5" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align={m.direction === "out" ? "end" : "start"}>
        <DropdownMenuItem onSelect={() => onDetails(m)}><InfoIcon />Details</DropdownMenuItem>
        {canCopy ? <DropdownMenuItem onSelect={() => void navigator.clipboard.writeText(m.text)}><CopyIcon />Copy text</DropdownMenuItem> : null}
        <DropdownMenuItem variant="destructive" onSelect={() => void run(() => deleteMessage(m), { error: "Not deleted", success: "Message deleted" })}>
          <Trash2Icon />Delete for me
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}

/** A room, in a few words: what you are there. */
function roomStanding(r: Room | null, member: boolean) {
  if (r?.left) return "you left"
  if (r) return r.role ? ROLE_TEXT[r.role].label.toLowerCase() : "joined"
  return member ? "member" : "not joined"
}

/** DMs and rooms: route details, reset path, room actions, delete the conversation from MeshChat's
 *  history (the other side keeps theirs). */
function ConversationMenu({ conv, title, count, contact, onRoute, room }: {
  conv: string; title: string; count: number; contact?: Contact; onRoute: () => void
  room?: { joined: boolean; onDetails: () => void; onJoin: () => void }
}) {
  const { deleteConversation } = useDeleteMessages()
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { run, isBusy } = useAsync()
  const routed = hasRoute(contact)
  const { reset, busy: resetting } = useResetPath()
  const [confirm, setConfirm] = useState(false)
  const [confirmLeave, setConfirmLeave] = useState(false)
  const leave = () => run(async () => {
    await api.leaveRoom(contact!.pubkey)
    await qc.invalidateQueries({ queryKey: keys.state })
    setConfirmLeave(false)
  }, { error: "Couldn't leave", success: { title: `Left ${title}`, description: "Its posts stay here; new ones are ignored." } }, "leave")
  const remove = () => run(async () => { const n = await deleteConversation(conv); setConfirm(false); navigate(convPath(chanConv(0))); return n }, {
    error: "Not deleted", success: (n) => `Deleted ${n} ${n === 1 ? "message" : "messages"} with ${title}`,
  })
  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild><Button size="icon-sm" variant="ghost" aria-label="Conversation actions"><EllipsisIcon /></Button></DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          {room ? <>
            <DropdownMenuItem onSelect={room.onDetails}><InfoIcon />Room details</DropdownMenuItem>
            <DropdownMenuItem onSelect={room.onJoin}><LogInIcon />{room.joined ? "Log in again" : "Join room"}</DropdownMenuItem>
          </> : null}
          {contact ? <>
            <DropdownMenuItem onSelect={onRoute}><RouteIcon />Route details</DropdownMenuItem>
            <DropdownMenuItem disabled={!routed || resetting} onSelect={() => void reset(contact)}>
              <RouteOffIcon />{routed ? "Reset path" : "No saved route to reset"}
            </DropdownMenuItem>
          </> : null}
          {room?.joined ? <DropdownMenuItem onSelect={() => setConfirmLeave(true)}><LogOutIcon />Leave room</DropdownMenuItem> : null}
          <DropdownMenuItem variant="destructive" disabled={!count} onSelect={() => setConfirm(true)}><Trash2Icon />Delete conversation</DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      <AlertDialog open={confirm} onOpenChange={setConfirm}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Delete {room ? "the posts from" : "the conversation with"} {title}?</AlertDialogTitle>
            <AlertDialogDescription>
              {count} {count === 1 ? "message is" : "messages are"} removed from MeshChat's history for good. {title} keeps their copy,
              and new messages from them start a fresh conversation. The contact stays.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction variant="destructive" disabled={isBusy()} onClick={(e) => { e.preventDefault(); void remove() }}>Delete</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
      <AlertDialog open={confirmLeave} onOpenChange={setConfirmLeave}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Leave {title}?</AlertDialogTitle>
            <AlertDialogDescription>
              MeshChat stops showing its new posts; the ones you have stay. MeshCore has no “leave” message, so the room keeps sending
              new posts to your radio (and your radio keeps confirming them) until the room forgets you. You can join again any time.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction variant="destructive" disabled={isBusy("leave")} onClick={(e) => { e.preventDefault(); void leave() }}>Leave</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}

/** A joined channel's actions (Public can't be left: it's the radio's slot 0). */
function ChannelMenu({ idx, title }: { idx: number; title: string }) {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const { run, isBusy } = useAsync()
  const [confirm, setConfirm] = useState(false)
  const leave = () => run(async () => {
    qc.setQueryData(keys.state, await api.leaveChannel(idx))
    setConfirm(false)
    navigate(convPath(chanConv(0)))
  }, { error: "Couldn't leave", success: `Left ${title}` })
  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild><Button size="icon-sm" variant="ghost" aria-label="Channel actions"><EllipsisIcon /></Button></DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          <DropdownMenuItem variant="destructive" onSelect={() => setConfirm(true)}><LogOutIcon />Leave channel</DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      <AlertDialog open={confirm} onOpenChange={setConfirm}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Leave {title}?</AlertDialogTitle>
            <AlertDialogDescription>Your radio stops receiving it and frees its slot. Its history stays in MeshChat, and you can join again any time.</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction variant="destructive" disabled={isBusy()} onClick={(e) => { e.preventDefault(); void leave() }}>Leave</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}

const STATUS: Record<string, { icon: typeof CheckIcon; label: (m: Message) => string; tip: string; cls?: string }> = {
  sending: { icon: ClockIcon, label: () => "sending", tip: "Handing it to your radio" },
  sent: { icon: CheckIcon, label: (m) => ((m.attempts ?? 1) > 1 ? `sent · try ${m.attempts}` : "sent"),
    tip: "Transmitted. Waiting to hear a repeater pass it on; if none does, it's re-sent automatically." },
  repeated: { icon: CheckCheckIcon, label: (m) => `repeated ×${m.repeats}${(m.attempts ?? 1) > 1 ? ` · try ${m.attempts}` : ""}`, tip: "A repeater re-transmitted it, so it's on the mesh", cls: "text-emerald-600 dark:text-emerald-400" },
  "not heard": { icon: AlertCircleIcon, label: (m) => `not heard · ${m.attempts ?? 1} tries`,
    tip: "No repeater passed it on, even after retries. The nearest repeater probably can't hear you right now.", cls: "text-amber-600 dark:text-amber-400" },
  delivered: { icon: CheckCheckIcon, label: () => "delivered", tip: "Their radio confirmed it", cls: "text-emerald-600 dark:text-emerald-400" },
  "no ack": { icon: AlertCircleIcon, label: () => "no receipt", tip: "No confirmation came back. It may or may not have arrived.", cls: "text-amber-600 dark:text-amber-400" },
  failed: { icon: XCircleIcon, label: () => "failed", tip: "Your radio couldn't send it", cls: "text-destructive" },
}
function OutStatus({ m, room }: { m: Message; room?: boolean }) {
  const base = STATUS[m.status] ?? STATUS.sent
  const s = room && m.status === "delivered" ? { ...base, label: () => "posted", tip: "The room stored it and passes it to its members" }
    : m.status === "delivered" && m.ack_try ? { ...base, tip: `${base.tip}: ${m.ack_try > 1 ? `on try ${m.ack_try}` : "first try"}${m.tries_flood?.[m.ack_try - 1] ? ", by flood" : ""}${m.rtt_ms ? `, receipt after ${m.rtt_ms < 1000 ? `${m.rtt_ms} ms` : `${(m.rtt_ms / 1000).toFixed(1)} s`}` : ""}` }
    : base
  const Icon = s.icon
  const { run, busy } = useAsync()
  const again = () => run(() => api.resend(m.id), { error: "Not sent" })
  return (
    <>
      <Hint content={s.tip}>
        <button type="button" className={cn("inline-flex items-center gap-1 rounded focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none", s.cls)}>
          <Icon className="size-3" />{s.label(m)}
        </button>
      </Hint>
      {m.status === "not heard" ? (
        <button onClick={() => void again()} disabled={!!busy}
          className="inline-flex items-center gap-1 rounded font-medium text-foreground hover:underline disabled:opacity-50 focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none">
          <RotateCwIcon className={cn("size-3", !!busy && "animate-spin")} />Send again
        </button>
      ) : null}
    </>
  )
}

/** The placeholder, only if loading takes a while: most switches finish within a few hundred ms,
 *  and a placeholder flashing up for a moment looked like a glitch. */
function DelayedSkeleton() {
  const [show, setShow] = useState(false)
  useEffect(() => { const t = setTimeout(() => setShow(true), 400); return () => clearTimeout(t) }, [])
  return show ? <MessagesSkeleton /> : <div className="h-full" aria-busy="true" />
}

function MessagesSkeleton() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true">
      {[60, 80, 45, 70].map((w, i) => (
        <div key={i} className={cn("flex gap-2.5", i % 3 === 2 && "flex-row-reverse")}>
          {i % 3 !== 2 ? <Skeleton className="size-8 rounded-full" /> : null}
          <Skeleton className="h-10 rounded-2xl" style={{ width: `${w}%` }} />
        </div>
      ))}
    </div>
  )
}
