// Message box with @-tag autocomplete. The list is a plain ARIA combobox so focus stays in
// the input (a Radix popover would steal it while typing). A text area that wraps long text and
// grows with it (up to about six lines, then it scrolls), so nothing ever scrolls sideways.
// Enter sends; Shift+Enter starts a new line.
import { InputGroup, InputGroupAddon, InputGroupButton, InputGroupTextarea } from "@/components/ui/input-group"
import { Spinner } from "@/components/ui/spinner"
import { NodeAvatar } from "@/components/mesh-bits"
import { byteLength, fold } from "@/lib/mesh"
import { cn } from "@/lib/utils"
import { SendHorizontalIcon } from "lucide-react"
import { useImperativeHandle, useLayoutEffect, useRef, useState, type KeyboardEvent, type Ref } from "react"

export interface ComposerHandle { mention: (name: string) => void; focus: () => void }
export interface TagCandidate { name: string; hint: string }

export function Composer({ ref, placeholder, limit, disabledReason, candidates, onSend }: {
  ref?: Ref<ComposerHandle>
  placeholder: string
  limit: number
  disabledReason?: string | null
  candidates: TagCandidate[]
  onSend: (text: string) => Promise<boolean>
}) {
  const input = useRef<HTMLTextAreaElement>(null)
  const [text, setText] = useState("")
  // fit the box to its text (also after a tag is inserted or a message sent); CSS caps the height
  useLayoutEffect(() => {
    const el = input.current
    if (!el) return
    el.style.height = "auto"
    el.style.height = `${el.scrollHeight}px`
  }, [text])
  const [busy, setBusy] = useState(false)
  const [ac, setAc] = useState<{ start: number; items: TagCandidate[]; sel: number } | null>(null)

  useImperativeHandle(ref, () => ({
    focus: () => input.current?.focus(),
    mention: (name) => {
      setText((t) => (`@[${name}] ${t.replace(/^\s+/, "")}`))
      requestAnimationFrame(() => { const el = input.current; if (el) { el.focus(); el.setSelectionRange(el.value.length, el.value.length) } })
    },
  }), [])

  const bytes = byteLength(text.trim())
  const over = bytes > limit
  const disabled = !!disabledReason

  const refresh = (value: string, caret: number) => {
    const before = value.slice(0, caret)
    const m = before.match(/(?:^|\s)@\[?([^\s@[\]]{0,30})$/)
    if (!m) return setAc(null)
    const q = fold(m[1])
    const items = candidates.filter((c) => !q || fold(c.name).includes(q)).slice(0, 8)
    if (!items.length) return setAc(null)
    setAc((prev) => ({ start: before.length - m[0].trimStart().length, items, sel: Math.min(prev?.sel ?? 0, items.length - 1) }))
  }

  const pick = (i: number) => {
    const el = input.current
    if (!el || !ac) return
    const tag = `@[${ac.items[i].name}] `
    const next = text.slice(0, ac.start) + tag + text.slice(el.selectionStart ?? text.length).replace(/^\s+/, "")
    setText(next)
    setAc(null)
    const pos = ac.start + tag.length
    requestAnimationFrame(() => { el.focus(); el.setSelectionRange(pos, pos) })
  }

  const submit = async () => {
    const t = text.trim()
    if (!t || over || disabled || busy) return
    setBusy(true)
    const ok = await onSend(t)
    setBusy(false)
    if (ok) setText("")
    input.current?.focus()
  }

  const onKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (ac) {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        const d = e.key === "ArrowDown" ? 1 : -1
        setAc({ ...ac, sel: (ac.sel + d + ac.items.length) % ac.items.length })
        return
      }
      if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); pick(ac.sel); return }
      if (e.key === "Escape") { e.preventDefault(); setAc(null); return }
    }
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void submit() }
  }

  return (
    <div className="relative border-t bg-background p-3">
      {ac ? (
        <ul id="tag-list" role="listbox" aria-label="Tag someone"
          className="absolute bottom-full left-3 z-20 mb-1 max-h-72 w-[min(22rem,calc(100%-1.5rem))] overflow-y-auto rounded-xl border bg-popover p-1 text-popover-foreground shadow-lg">
          {ac.items.map((c, i) => (
            <li key={c.name} id={`tag-opt-${i}`} role="option" aria-selected={i === ac.sel}
              onMouseDown={(e) => { e.preventDefault(); pick(i) }} onMouseEnter={() => setAc({ ...ac, sel: i })}
              className={cn("flex cursor-pointer items-center gap-2 rounded-lg px-2 py-1.5 text-sm", i === ac.sel && "bg-accent text-accent-foreground")}>
              <NodeAvatar name={c.name} className="size-6" />
              <span className="truncate">{c.name}</span>
              <span className="ml-auto shrink-0 text-xs text-muted-foreground">{c.hint}</span>
            </li>
          ))}
        </ul>
      ) : null}
      <InputGroup className="min-h-11 items-end">
        <InputGroupTextarea ref={input} value={text} disabled={disabled} rows={1} enterKeyHint="send"
          className="field-sizing-fixed max-h-40 min-h-0 overflow-y-auto py-2.5 wrap-anywhere"
          placeholder={disabledReason ?? placeholder} aria-label="Message"
          role="combobox" aria-autocomplete="list" aria-expanded={!!ac} aria-controls="tag-list"
          aria-activedescendant={ac ? `tag-opt-${ac.sel}` : undefined}
          onChange={(e) => { setText(e.target.value); refresh(e.target.value, e.target.selectionStart ?? e.target.value.length) }}
          onClick={(e) => refresh(e.currentTarget.value, e.currentTarget.selectionStart ?? 0)}
          onBlur={() => setTimeout(() => setAc(null), 120)}
          onKeyDown={onKeyDown} />
        <InputGroupAddon align="inline-end" className="pb-1.5">
          {bytes > limit * 0.7 ? (
            <span className={cn("text-xs tabular-nums", over ? "font-semibold text-destructive" : "text-muted-foreground")}
              aria-live="polite">{bytes}/{limit}</span>
          ) : null}
          <InputGroupButton size="icon-sm" variant="default" aria-label="Send" disabled={!text.trim() || over || disabled || busy}
            onClick={() => void submit()}>
            {busy ? <Spinner /> : <SendHorizontalIcon />}
          </InputGroupButton>
        </InputGroupAddon>
      </InputGroup>
      <p className="mt-1.5 hidden px-1 text-[11px] text-muted-foreground sm:block">
        Enter to send · type <kbd className="font-sans">@</kbd> to tag someone · messages are limited to {limit} bytes
      </p>
    </div>
  )
}
