// Contacts by QR code, both ways. "Scan": read a MeshCore QR code from a photo or screenshot (or a
// pasted meshcore:// link) and add the contact, or join the channel it describes. "My contact":
// this radio's own QR code, for others to scan, since their radio needs your key to read your DMs.
import { NodeAvatar } from "@/components/mesh-bits"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Spinner } from "@/components/ui/spinner"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { api } from "@/lib/api"
import { copyText } from "@/lib/clipboard"
import { CONTACT_TYPE_NAME, contactLink, parseMeshLink, shortKey, type MeshLink } from "@/lib/meshcore-links"
import { keys, useAppState } from "@/lib/queries"
import { qrPath, readQr } from "@/lib/qr"
import { convPath, dmConv } from "@/lib/routes"
import type { AppState } from "@/lib/types"
import { useJoinChannel } from "@/lib/use-join-channel"
import { useQueryClient } from "@tanstack/react-query"
import { CameraIcon, CheckIcon, CopyIcon, HashIcon, ImageIcon, MessageSquareIcon, UserPlusIcon } from "lucide-react"
import { useEffect, useRef, useState, type ChangeEvent } from "react"
import { useNavigate } from "react-router"
import { toast } from "sonner"

export type ContactTab = "scan" | "share"

export function AddContactDialog({ open, onOpenChange, tab, onTabChange }: {
  open: boolean; onOpenChange: (o: boolean) => void; tab: ContactTab; onTabChange: (t: ContactTab) => void
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Contacts by QR code</DialogTitle>
          <DialogDescription>Add someone from their MeshCore QR code, or show yours so they can add you.</DialogDescription>
        </DialogHeader>
        <Tabs value={tab} onValueChange={(v) => onTabChange(v as ContactTab)}>
          <TabsList className="w-full">
            <TabsTrigger value="scan">Scan a code</TabsTrigger>
            <TabsTrigger value="share">My contact</TabsTrigger>
          </TabsList>
          <TabsContent value="scan" className="pt-3">{open && tab === "scan" ? <Scan onDone={() => onOpenChange(false)} /> : null}</TabsContent>
          <TabsContent value="share" className="pt-3">{open && tab === "share" ? <Share /> : null}</TabsContent>
        </Tabs>
      </DialogContent>
    </Dialog>
  )
}

// ---------------------------------------------------------------- scan
function Scan({ onDone }: { onDone: () => void }) {
  const camera = useRef<HTMLInputElement>(null)
  const picker = useRef<HTMLInputElement>(null)
  const [reading, setReading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [link, setLink] = useState<MeshLink | null>(null)
  const [pasted, setPasted] = useState("")

  const fromText = (text: string) => {
    const l = parseMeshLink(text)
    setLink(l)
    setError(l ? null : "That isn't a MeshCore contact or channel code.")
  }
  const onFile = async (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    e.target.value = ""   // the same picture again should still fire
    if (!file) return
    setReading(true); setError(null); setLink(null)
    try {
      const text = await readQr(file)
      if (text) fromText(text)
      else setError("No QR code found in that picture. Try again with the code filling more of the frame, in focus.")
    } catch {
      setError("Couldn't open that picture.")
    } finally { setReading(false) }
  }

  return (
    <div className="grid gap-4">
      <input ref={camera} type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => void onFile(e)} />
      <input ref={picker} type="file" accept="image/*" className="hidden" onChange={(e) => void onFile(e)} />
      <div className="grid grid-cols-2 gap-2">
        <Button variant="outline" className="h-auto flex-col gap-1.5 py-4" disabled={reading} onClick={() => camera.current?.click()}>
          <CameraIcon className="size-5" />Take a photo
        </Button>
        <Button variant="outline" className="h-auto flex-col gap-1.5 py-4" disabled={reading} onClick={() => picker.current?.click()}>
          <ImageIcon className="size-5" />Choose a picture
        </Button>
      </div>
      <p className="-mt-2 text-xs text-muted-foreground">A screenshot of a code works too, e.g. one someone sent you.</p>
      <Field>
        <FieldLabel htmlFor="mc-link">Or paste a link</FieldLabel>
        <div className="flex gap-2">
          <Input id="mc-link" value={pasted} placeholder="meshcore://contact/add?…" autoComplete="off" autoCapitalize="off" spellCheck={false}
            onChange={(e) => setPasted(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter" && pasted.trim()) fromText(pasted) }} />
          <Button variant="secondary" disabled={!pasted.trim()} onClick={() => fromText(pasted)}>Read</Button>
        </div>
      </Field>
      {reading ? <p className="flex items-center gap-2 text-sm text-muted-foreground"><Spinner />Looking for a QR code…</p> : null}
      {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
      {link?.kind === "contact" ? <ContactResult link={link} onDone={onDone} /> : null}
      {link?.kind === "channel" ? <ChannelResult link={link} onDone={onDone} /> : null}
    </div>
  )
}

/** Keep refetching the state until the new contact shows (the radio takes a few seconds to list it). */
async function waitForContact(qc: ReturnType<typeof useQueryClient>, key: string) {
  for (let i = 0; i < 8; i++) {
    await qc.refetchQueries({ queryKey: keys.state })
    if (qc.getQueryData<AppState>(keys.state)?.contacts[key]) return true
    await new Promise((r) => setTimeout(r, 1500))
  }
  return false
}

function ContactResult({ link, onDone }: { link: Extract<MeshLink, { kind: "contact" }>; onDone: () => void }) {
  const { data: state } = useAppState()
  const qc = useQueryClient()
  const navigate = useNavigate()
  const [busy, setBusy] = useState(false)
  const known = state?.contacts[link.publicKey]
  const mine = state?.self.pubkey === link.publicKey
  const message = () => { onDone(); navigate(convPath(dmConv(link.publicKey))) }

  const add = async () => {
    setBusy(true)
    try {
      await api.addContact({ public_key: link.publicKey, name: link.name, type: link.type })
      const shown = await waitForContact(qc, link.publicKey)
      toast.success(`${link.name} added to your contacts`, shown ? undefined : { description: "It may take a moment to show in the list." })
    } catch (e) {
      toast.error("Contact not added", { description: (e as Error).message })
    } finally { setBusy(false) }
  }

  return (
    <div className="flex items-center gap-3 rounded-lg border p-3">
      <NodeAvatar name={link.name} />
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium">{link.name}</p>
        <p className="truncate text-xs text-muted-foreground">{CONTACT_TYPE_NAME[link.type]} · {shortKey(link.publicKey)}</p>
      </div>
      {mine ? <span className="text-xs text-muted-foreground">That's you</span>
        : known ? (
          link.type === 1
            ? <Button size="sm" onClick={message}><MessageSquareIcon />Message</Button>
            : <span className="flex items-center gap-1 text-xs text-muted-foreground"><CheckIcon className="size-3.5" />In contacts</span>
        ) : (
          <Button size="sm" disabled={busy || !state?.connected} onClick={() => void add()}>{busy ? <Spinner /> : <UserPlusIcon />}Add</Button>
        )}
    </div>
  )
}

function ChannelResult({ link, onDone }: { link: Extract<MeshLink, { kind: "channel" }>; onDone: () => void }) {
  const { data: state } = useAppState()
  const join = useJoinChannel()
  const [busy, setBusy] = useState(false)
  const joined = state?.channels.some((c) => c.name === link.name)
  const go = async () => {
    setBusy(true)
    try {
      await join(link.name, link.secret)
      toast.success(`Joined ${link.name}`)
      onDone()
    } catch (e) {
      toast.error("Channel not joined", { description: (e as Error).message })
    } finally { setBusy(false) }
  }
  return (
    <div className="flex items-center gap-3 rounded-lg border p-3">
      <span className="grid size-8 place-items-center rounded-full bg-muted"><HashIcon className="size-4" /></span>
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium">{link.name}</p>
        <p className="text-xs text-muted-foreground">channel{link.name.startsWith("#") ? "" : " · private"}</p>
      </div>
      {joined ? <span className="flex items-center gap-1 text-xs text-muted-foreground"><CheckIcon className="size-3.5" />Joined</span>
        : <Button size="sm" disabled={busy || !state?.connected} onClick={() => void go()}>{busy ? <Spinner /> : <HashIcon />}Join</Button>}
    </div>
  )
}

// ---------------------------------------------------------------- share
function Share() {
  const { data: state } = useAppState()
  const field = useRef<HTMLInputElement>(null)
  const [qr, setQr] = useState<{ size: number; d: string } | null>(null)
  const self = state?.self
  const url = self ? contactLink(self.name, self.pubkey, 1) : ""

  useEffect(() => {
    let live = true
    if (url) void qrPath(url).then((q) => { if (live) setQr(q) })
    return () => { live = false }
  }, [url])

  const copy = async () => {
    if (await copyText(url)) toast.success("Link copied")
    else { field.current?.select(); toast("Selected: copy it from the menu") }
  }

  if (!self) return <p className="text-sm text-muted-foreground">Waiting for the radio…</p>
  return (
    <div className="grid justify-items-center gap-3">
      <div className="flex items-center gap-2">
        <NodeAvatar name={self.name} />
        <div>
          <p className="text-sm font-medium">{self.name}</p>
          <p className="text-xs text-muted-foreground">{shortKey(self.pubkey)}</p>
        </div>
      </div>
      {/* dark on white in either theme: that's what scanners expect */}
      <div className="rounded-xl bg-white p-3 text-black shadow-xs">
        {qr ? (
          <svg viewBox={`-4 -4 ${qr.size + 8} ${qr.size + 8}`} className="size-56" role="img" aria-label={`QR code to add ${self.name} as a contact`} shapeRendering="crispEdges">
            <path d={qr.d} fill="currentColor" />
          </svg>
        ) : <div className="grid size-56 place-items-center"><Spinner /></div>}
      </div>
      <p className="text-center text-sm text-muted-foreground text-balance">
        Their radio needs your contact to read your direct messages. In the MeshCore app: Menu → Add Contact → Scan QR Code. In MeshChat: Add contact → Scan a code.
      </p>
      <Field className="w-full">
        <FieldLabel htmlFor="my-link" className="sr-only">Your contact link</FieldLabel>
        <div className="flex gap-2">
          <Input id="my-link" ref={field} readOnly value={url} onFocus={(e) => e.currentTarget.select()} className="font-mono text-xs" />
          <Button variant="secondary" onClick={() => void copy()}><CopyIcon />Copy</Button>
        </div>
        <FieldDescription>Or send them this link: it holds the same thing as the code.</FieldDescription>
      </Field>
    </div>
  )
}
