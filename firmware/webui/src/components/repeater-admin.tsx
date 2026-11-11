import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Spinner } from "@/components/ui/spinner"
import { COMMANDS, SETTINGS, settingValue, type AdminCommand, type Setting } from "@/lib/admin-commands"
import { api } from "@/lib/api"
import { ago } from "@/lib/mesh"
import { keys, useAppState, waitForLive } from "@/lib/queries"
import type { CliLine, RepeaterDetail, RepeaterLive } from "@/lib/types"
import { cn } from "@/lib/utils"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { AlertTriangleIcon, CheckIcon, ChevronRightIcon, ClockIcon, KeyRoundIcon, SendIcon, ShieldIcon, XIcon } from "lucide-react"
import { useEffect, useMemo, useRef, useState } from "react"
import { toast } from "sonner"

const QUICK = ["reboot", "advert", "advert.zerohop", "clock sync", "clock", "ver", "power", "neighbors", "discover.neighbors", "clear stats"]
  .map((c) => COMMANDS.find((x) => x.command === c)!)

/** The catalogue entry a typed command is (to ask first for the risky ones): exact, or by the words
 *  before its first `<value>`. */
function findCommand(text: string) {
  return COMMANDS.find((c) => {
    const at = c.command.indexOf(" <")
    return at < 0 ? c.command === text : text.startsWith(c.command.slice(0, at) + " ")
  })
}

/** Pairs each answer with the oldest command still waiting for one (a node answers in order). */
function pair(lines: CliLine[]) {
  const waiting: CliLine[] = [], answers = new Map<number, CliLine>()
  for (const l of lines) {
    if (l.dir === "command") { if (l.status !== "failed") waiting.push(l) }
    else { const c = waiting.shift(); if (c) answers.set(c.id, l) }
  }
  return answers
}

/** A repeater's (or room server's) admin commands: log in with its admin password, then run any of
 *  its command-line commands. Each one is a short transmission and its answer takes 5–30 s. */
export function RepeaterAdmin({ d }: { d: RepeaterDetail }) {
  const qc = useQueryClient()
  const { data: state } = useAppState()
  const live = d.live
  const admin = !!live?.login?.admin
  const { data: log } = useQuery({ queryKey: keys.cli(d.key), queryFn: () => api.cli(d.key), staleTime: Infinity })
  const lines = useMemo(() => log?.lines ?? [], [log])
  const answers = useMemo(() => pair(lines), [lines])
  const [pending, setPending] = useState<{ command: string; title: string; confirm: string } | null>(null)

  const values = useMemo(() => {   // the latest answer to each setting's get (or a set it accepted)
    const v: Record<string, string> = {}
    for (const l of lines) {
      const a = answers.get(l.id)
      if (l.dir !== "command" || !a) continue
      const get = /^get (\S+)$/.exec(l.text), set = /^set (\S+) (.*)$/.exec(l.text)
      if (get) v[get[1]] = settingValue(a.text)
      else if (set && /^OK/i.test(a.text) && !set[2].includes("•")) v[set[1]] = set[2]
    }
    return v
  }, [lines, answers])

  const run = async (command: string) => {
    try { await api.runCommand(d.key, command) } catch (e) { toast.error("Not sent", { description: (e as Error).message }) }
  }
  const ask = (c: { command: string; label: string; confirm?: string }, command = c.command) => {
    if (c.confirm) setPending({ command, title: `${c.label}: ${d.name}?`, confirm: c.confirm })
    else void run(command)
  }
  const connected = !!state?.connected

  return (
    <div className="grid gap-5">
      <AdminLogin d={d} live={live} admin={admin} onLoggedIn={() => void qc.invalidateQueries({ queryKey: keys.cli(d.key) })} />

      {admin ? (
        <>
          <section className="grid gap-2">
            <h3 className="text-sm font-medium">Actions</h3>
            <div className="flex flex-wrap gap-2">
              {QUICK.map((c) => (
                <Button key={c.command} variant={c.confirm ? "outline" : "secondary"} size="sm" disabled={!connected} onClick={() => ask(c)} title={c.about}>
                  {c.confirm ? <AlertTriangleIcon className="text-amber-600" /> : null}{c.label}
                </Button>
              ))}
            </div>
          </section>

          <Settings values={values} disabled={!connected} onGet={(s) => void run(`get ${s.name}`)}
            onSet={(s, value) => ask({ command: `set ${s.name} ${value}`, label: `Set ${s.label.toLowerCase()}`, confirm: s.confirm })} />

          <Console lines={lines} answers={answers} disabled={!connected} onRun={(command) => {
            const known = findCommand(command)
            if (known?.confirm) ask(known, command); else void run(command)
          }} />
        </>
      ) : null}

      <AlertDialog open={!!pending} onOpenChange={(o) => { if (!o) setPending(null) }}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{pending?.title}</AlertDialogTitle>
            <AlertDialogDescription>{pending?.confirm}</AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancel</AlertDialogCancel>
            <AlertDialogAction onClick={() => { if (pending) void run(pending.command); setPending(null) }}>Send</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}

function AdminLogin({ d, live, admin, onLoggedIn }: { d: RepeaterDetail; live?: RepeaterLive | null; admin: boolean; onLoggedIn: () => void }) {
  const qc = useQueryClient()
  const { data: state } = useAppState()
  const [password, setPassword] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const running = busy || !!live?.running

  const login = async () => {
    setBusy(true); setError(null)
    try {
      const before = qc.getQueryData<Record<string, RepeaterLive>>(keys.repeaterLive)?.[d.key]
      const pwd = password
      setPassword("")   // not kept
      await api.startRepeaterQuery(d.key, pwd)
      const res = await waitForLive(d.key, before, (all) => qc.setQueryData(keys.repeaterLive, all))
      if (!res.ok || !res.login) setError(res.error ?? "No answer")
      else if (!res.login.admin) setError(`That password logs in as ${res.login.role ?? "a guest"}, not admin.`)
      else { toast.success(`Logged in to ${d.name} as admin`); onLoggedIn() }
    } catch (e) { setError((e as Error).message) } finally { setBusy(false) }
  }

  return (
    <div className="flex flex-col gap-3 rounded-xl border p-4">
      <div className="flex items-start gap-3">
        <ShieldIcon className={cn("mt-0.5 size-5 shrink-0", admin ? "text-emerald-600" : "text-muted-foreground")} />
        <div className="min-w-0 flex-1 text-sm">
          <p className="font-medium">{admin ? `Logged in as admin ${live ? ago(live.ts) : ""}` : "Admin commands need the repeater's admin password"}</p>
          <p className="text-muted-foreground">
            {admin
              ? "Commands go to it one at a time and answers take 5–30 s. If a command gets no answer, the repeater may have forgotten the login: log in again."
              : "MeshChat sends the password to the repeater to log in (with its status and neighbours) and doesn't keep it. Commands are encrypted for the repeater."}
          </p>
        </div>
      </div>
      <form className="flex flex-wrap items-end gap-2" onSubmit={(e) => { e.preventDefault(); void login() }}>
        <Field className="w-full max-w-xs">
          <FieldLabel htmlFor="adminpw">Admin password</FieldLabel>
          <Input id="adminpw" type="password" autoComplete="off" maxLength={15} value={password} onChange={(e) => setPassword(e.target.value)} />
          <FieldDescription>Up to 15 characters.</FieldDescription>
        </Field>
        <Button type="submit" className="sm:mb-6" disabled={running || !password || !d.can_query || !state?.connected}>
          {running ? <><Spinner />Logging in…</> : <><KeyRoundIcon />{admin ? "Log in again" : "Log in as admin"}</>}
        </Button>
      </form>
      {!d.can_query ? <p className="text-sm text-amber-700 dark:text-amber-400">Not available yet: your radio needs this repeater's advert before it can address it.</p> : null}
      {error ? <Alert variant="destructive"><AlertTitle>Not logged in as admin</AlertTitle><AlertDescription>{error}</AlertDescription></Alert> : null}
    </div>
  )
}

function Settings({ values, disabled, onGet, onSet }: {
  values: Record<string, string>; disabled: boolean; onGet: (s: Setting) => void; onSet: (s: Setting, value: string) => void
}) {
  const [editing, setEditing] = useState<string | null>(null)
  const [draft, setDraft] = useState("")
  return (
    <section className="grid gap-2">
      <div className="flex items-baseline justify-between gap-2">
        <h3 className="text-sm font-medium">Settings</h3>
        <p className="text-xs text-muted-foreground">Read asks the repeater for the current value.</p>
      </div>
      <div className="divide-y rounded-xl border">
        {(["Node", "Radio", "Access"] as const).map((g) => (
          <div key={g} className="divide-y">
            <p className="bg-muted/40 px-3 py-1.5 text-xs font-medium text-muted-foreground">{g}</p>
            {SETTINGS.filter((s) => s.group === g).map((s) => (
              <div key={s.name} className="grid gap-2 px-3 py-2">
                <div className="flex items-center gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="text-sm">{s.label} <span className="font-mono text-xs text-muted-foreground">{s.name}{s.hint ? ` · ${s.hint}` : ""}</span></p>
                    <p className="truncate font-mono text-sm tabular-nums">{values[s.name] ?? <span className="text-muted-foreground">not read</span>}</p>
                  </div>
                  <div className="flex shrink-0 gap-1">
                    <Button size="sm" variant="ghost" disabled={disabled} onClick={() => onGet(s)}>Read</Button>
                    <Button size="sm" variant="outline" disabled={disabled || editing === s.name}
                      onClick={() => { setEditing(s.name); setDraft(s.name.includes("password") ? "" : values[s.name] ?? s.options?.[0] ?? "") }}>Change</Button>
                  </div>
                </div>
                {editing === s.name ? (
                  <form className="flex items-center gap-1.5" onSubmit={(e) => { e.preventDefault(); onSet(s, draft.trim()); setEditing(null) }}>
                    {s.options ? (
                      <select className="h-8 min-w-0 flex-1 rounded-md border bg-background px-2 text-sm sm:max-w-56 sm:flex-none" value={draft} onChange={(e) => setDraft(e.target.value)} aria-label={s.label}>
                        {s.options.map((o) => <option key={o} value={o}>{o}</option>)}
                      </select>
                    ) : (
                      <Input className="h-8 min-w-0 flex-1 sm:max-w-72" autoFocus value={draft} onChange={(e) => setDraft(e.target.value)} aria-label={s.label}
                        type={s.name.includes("password") ? "password" : "text"} />
                    )}
                    <Button size="sm" type="submit" disabled={disabled}><CheckIcon />Save</Button>
                    <Button size="icon-sm" variant="ghost" type="button" aria-label="Cancel" onClick={() => setEditing(null)}><XIcon /></Button>
                  </form>
                ) : null}
              </div>
            ))}
          </div>
        ))}
      </div>
    </section>
  )
}

function Console({ lines, answers, disabled, onRun }: {
  lines: CliLine[]; answers: Map<number, CliLine>; disabled: boolean; onRun: (command: string) => void
}) {
  const [text, setText] = useState("")
  const [filter, setFilter] = useState("")
  const [showAll, setShowAll] = useState(false)
  const input = useRef<HTMLInputElement>(null)
  const end = useRef<HTMLDivElement>(null)
  useEffect(() => { end.current?.scrollIntoView({ block: "nearest" }) }, [lines.length])

  const use = (c: AdminCommand) => {
    const at = c.command.indexOf("<")
    if (at < 0) { onRun(c.command); return }
    setText(c.command)
    requestAnimationFrame(() => { input.current?.focus(); input.current?.setSelectionRange(at, c.command.indexOf(">", at) + 1) })
  }
  const shown = COMMANDS.filter((c) => !filter || `${c.command} ${c.label} ${c.about}`.toLowerCase().includes(filter.toLowerCase()))
  const groups = [...new Set(shown.map((c) => c.group))]
  const waiting = (l: CliLine) => l.dir === "command" && l.status !== "failed" && !answers.has(l.id)

  return (
    <section className="grid gap-2">
      <h3 className="text-sm font-medium">Command line</h3>
      <div className="max-h-80 overflow-y-auto rounded-xl border bg-muted/30 p-3 font-mono text-xs" data-no-swipe>
        {lines.length ? lines.map((l) => (
          <div key={l.id} className={cn("flex gap-2 py-0.5", l.dir === "answer" && "pl-4 text-muted-foreground")}>
            {l.dir === "command"
              ? <ChevronRightIcon className="mt-px size-3.5 shrink-0" />
              : null}
            <span className="min-w-0 flex-1 break-words whitespace-pre-wrap">{l.text}</span>
            {l.dir === "command" ? (
              <span className="shrink-0 text-muted-foreground">
                {l.status === "failed" ? <span className="text-destructive">not sent</span>
                  : waiting(l) ? <span className="inline-flex items-center gap-1"><ClockIcon className="size-3" />{l.status === "sending" ? "sending" : "waiting"}</span>
                  : null}
              </span>
            ) : null}
          </div>
        )) : <p className="text-muted-foreground">Commands you send and the repeater's answers appear here.</p>}
        <div ref={end} />
      </div>
      <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); const t = text.trim(); if (t) { onRun(t); setText("") } }}>
        <Input ref={input} value={text} onChange={(e) => setText(e.target.value)} placeholder="A command, e.g. get radio" maxLength={150}
          className="font-mono" autoCapitalize="off" autoCorrect="off" spellCheck={false} aria-label="Command" />
        <Button type="submit" disabled={disabled || !text.trim()}><SendIcon />Send</Button>
      </form>

      <div className="rounded-xl border">
        <button type="button" className="flex w-full items-center justify-between px-3 py-2 text-left text-sm font-medium" aria-expanded={showAll} onClick={() => setShowAll((s) => !s)}>
          All commands <span className="text-xs font-normal text-muted-foreground">{COMMANDS.length} · tap one to send or fill in</span>
        </button>
        {showAll ? (
          <div className="border-t">
            <div className="p-2"><Input value={filter} onChange={(e) => setFilter(e.target.value)} placeholder="Search commands" aria-label="Search commands" /></div>
            {groups.map((g) => (
              <div key={g}>
                <p className="bg-muted/40 px-3 py-1.5 text-xs font-medium text-muted-foreground">{g}</p>
                {shown.filter((c) => c.group === g).map((c) => (
                  <button key={c.command} type="button" disabled={disabled} onClick={() => use(c)}
                    className="flex w-full items-start gap-3 border-t px-3 py-2 text-left hover:bg-muted/50 disabled:opacity-50">
                    <span className="min-w-0 flex-1">
                      <span className="block text-sm">{c.label}{c.confirm ? <AlertTriangleIcon className="ml-1 inline size-3.5 text-amber-600" aria-label="asks first" /> : null}</span>
                      <span className="block font-mono text-xs text-muted-foreground">{c.command}</span>
                      <span className="block text-xs text-muted-foreground">{c.about}</span>
                    </span>
                  </button>
                ))}
              </div>
            ))}
          </div>
        ) : null}
      </div>
    </section>
  )
}
