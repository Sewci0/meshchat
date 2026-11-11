// Update the radio's firmware over WiFi. Pick a .bin; it's checked here first (an ESP32-S3 app
// image, not a full flash image; a MeshChat build or not), then uploaded with progress. The radio
// writes it into its spare firmware slot while it keeps running, checks it, switches to it and
// restarts; this waits for it to come back and reloads.
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Spinner } from "@/components/ui/spinner"
import { cn } from "@/lib/utils"
import { useQuery } from "@tanstack/react-query"
import { AlertTriangleIcon, CheckCircle2Icon, CpuIcon, UploadIcon } from "lucide-react"
import { useRef, useState, type ChangeEvent } from "react"

interface FirmwareInfo { build: string; running: string; next: string; slot_size: number; uploading: boolean; received: number }

const MARKER = "MESHCHAT-BUILD:"
const ESP32S3 = 9

/** What a .bin file is: an app image for this chip? which MeshChat build? */
export function inspectFirmware(bytes: Uint8Array, slot: number): { error?: string; build?: string } {
  if (bytes.length > slot) return { error: `It's ${(bytes.length / 1048576).toFixed(2)} MB, more than the radio's firmware slot (${(slot / 1048576).toFixed(2)} MB).` }
  if (bytes[0] !== 0xe9) return { error: "That isn't an ESP32 firmware image. Pick the firmware .bin (PlatformIO's firmware.bin)." }
  if (bytes.length > 0x8002 && bytes[0x8000] === 0xaa && bytes[0x8001] === 0x50)
    return { error: "That's a full flash image (bootloader, partitions and app) for USB flashing. Pick the app-only firmware .bin." }
  const chip = bytes[12] | (bytes[13] << 8)
  if (chip !== ESP32S3) return { error: `It's built for a different chip (ID ${chip}); this radio is an ESP32-S3.` }
  // the build marker: plain ASCII somewhere in the image
  const m = new TextEncoder().encode(MARKER)
  outer: for (let i = 0; i < bytes.length - m.length; i++) {
    for (let k = 0; k < m.length; k++) if (bytes[i + k] !== m[k]) continue outer
    let end = i + m.length
    while (end < bytes.length && bytes[end] !== 0 && end - i < 120) end++
    return { build: new TextDecoder().decode(bytes.slice(i + m.length, end)) }
  }
  return {}
}

type Phase = "pick" | "uploading" | "restarting" | "done" | "failed"

export function FirmwareUpdate() {
  const [open, setOpen] = useState(false)
  return (
    <>
      <Button variant="outline" className="justify-self-start" onClick={() => setOpen(true)}><CpuIcon />Update firmware…</Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="sm:max-w-md">{open ? <Updater onClose={() => setOpen(false)} /> : null}</DialogContent>
      </Dialog>
    </>
  )
}

function Updater({ onClose }: { onClose: () => void }) {
  const { data: info } = useQuery({ queryKey: ["device-firmware"], queryFn: async () => (await fetch("/api/device/firmware")).json() as Promise<FirmwareInfo> })
  const picker = useRef<HTMLInputElement>(null)
  const [file, setFile] = useState<{ f: File; build?: string; error?: string } | null>(null)
  const [understood, setUnderstood] = useState(false)
  const [phase, setPhase] = useState<Phase>("pick")
  const [progress, setProgress] = useState(0)
  const [error, setError] = useState<string | null>(null)

  const choose = async (e: ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0]
    e.target.value = ""
    if (!f || !info) return
    setUnderstood(false); setError(null)
    setFile({ f, ...inspectFirmware(new Uint8Array(await f.arrayBuffer()), info.slot_size) })
  }

  // wait for the radio to restart into the new firmware, then reload the app (which it serves)
  const waitForRadio = async () => {
    await new Promise((r) => setTimeout(r, 4000))
    for (let i = 0; i < 45; i++) {
      try {
        const h = await fetch("/api/device/health", { cache: "no-store" })
        if (h.ok && (await h.json()).uptime_s < 120) { setPhase("done"); setTimeout(() => location.reload(), 1500); return }
      } catch { /* still restarting */ }
      await new Promise((r) => setTimeout(r, 2000))
    }
    setError("It hasn't come back after 90 seconds. Reload in a minute; if it still doesn't answer, unplug and replug it.")
    setPhase("failed")
  }

  const install = () => {
    if (!file) return
    setPhase("uploading"); setProgress(0); setError(null)
    const xhr = new XMLHttpRequest()   // fetch can't report upload progress
    xhr.open("POST", "/api/device/firmware")
    xhr.upload.onprogress = (e) => { if (e.lengthComputable) setProgress(e.loaded / e.total) }
    xhr.onload = () => {
      if (xhr.status === 200) { setPhase("restarting"); void waitForRadio() }
      else { setError(xhr.responseText || `failed (${xhr.status})`); setPhase("failed") }
    }
    xhr.onerror = () => { setError("The upload was cut off. The radio keeps its current firmware; try again."); setPhase("failed") }
    const body = new FormData()
    body.append("firmware", file.f, file.f.name)
    xhr.send(body)
  }

  const same = !!file?.build && file.build === info?.build
  const canInstall = !!file && !file.error && (!!file.build || understood) && phase === "pick"

  return (
    <>
      <DialogHeader>
        <DialogTitle>Update firmware</DialogTitle>
        <DialogDescription>
          The radio writes the new firmware into its spare slot while it keeps working, checks it, and only then switches over and
          restarts (about 20 seconds off the air). If the upload breaks off or the file is damaged, it keeps the firmware it has.
        </DialogDescription>
      </DialogHeader>

      <dl className="grid grid-cols-[6.5rem_1fr] gap-x-3 gap-y-1 rounded-lg border p-3 text-sm">
        <dt className="text-muted-foreground">Running</dt><dd className="wrap-anywhere">{info ? info.build : "…"}</dd>
        <dt className="text-muted-foreground">Slots</dt><dd>{info ? `${info.running} now, update goes to ${info.next} (${(info.slot_size / 1048576).toFixed(1)} MB)` : "…"}</dd>
      </dl>

      <input ref={picker} type="file" accept=".bin,application/octet-stream" className="hidden" onChange={(e) => void choose(e)} />
      {phase === "pick" ? (
        <Button variant="outline" onClick={() => picker.current?.click()} disabled={!info}><UploadIcon />{file ? "Choose another file" : "Choose firmware file (.bin)"}</Button>
      ) : null}

      {file ? (
        <div className={cn("grid gap-1 rounded-lg border p-3 text-sm", file.error && "border-destructive/50")}>
          <p className="wrap-anywhere"><span className="font-medium">{file.f.name}</span> <span className="text-muted-foreground">· {(file.f.size / 1048576).toFixed(2)} MB</span></p>
          {file.error ? <p className="text-destructive">{file.error}</p>
            : file.build ? <p className="text-muted-foreground">MeshChat {file.build}{same ? " (the one already running)" : ""}</p>
              : (
                <div className="grid gap-2">
                  <p className="flex gap-1.5 text-amber-700 dark:text-amber-400"><AlertTriangleIcon className="mt-0.5 size-4 shrink-0" />
                    Not a MeshChat build: probably plain MeshCore firmware. Installing it removes this web app, and getting it back needs USB.</p>
                  <label className="flex items-center gap-2"><input type="checkbox" checked={understood} onChange={(e) => setUnderstood(e.target.checked)} />Install it anyway</label>
                </div>
              )}
        </div>
      ) : null}

      {phase === "uploading" ? (
        <div className="grid gap-1.5" role="status">
          <div className="h-2 overflow-hidden rounded-full bg-muted"><div className="h-full rounded-full bg-primary transition-[width]" style={{ width: `${Math.round(progress * 100)}%` }} /></div>
          <p className="text-sm text-muted-foreground tabular-nums">{progress < 1 ? `Uploading… ${Math.round(progress * 100)}%` : "Checking the image…"}</p>
        </div>
      ) : null}
      {phase === "restarting" ? <p className="flex items-center gap-2 text-sm" role="status"><Spinner />Installed. The radio is restarting into it…</p> : null}
      {phase === "done" ? <p className="flex items-center gap-2 text-sm text-emerald-700 dark:text-emerald-400" role="status"><CheckCircle2Icon className="size-4" />Updated. Reloading…</p> : null}
      {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}

      <DialogFooter>
        <Button variant="outline" onClick={onClose} disabled={phase === "uploading"}>{phase === "failed" || phase === "pick" ? "Cancel" : "Close"}</Button>
        {phase === "pick" || phase === "failed" ? <Button onClick={install} disabled={!canInstall && phase !== "failed"}><UploadIcon />{phase === "failed" ? "Try again" : "Install"}</Button> : null}
      </DialogFooter>
    </>
  )
}
