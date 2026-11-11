// "Your repeater has gone quiet": a repeater you heard regularly has stopped, though the rest of the
// mesh keeps arriving (RepeaterQuiet, worked out in lib/repeaters.ts). Shown above the
// composer while it lasts, since your messages may not get through, and on that repeater's page.
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import { useLocal } from "@/lib/local"
import { ago, bearing, clock, km, snrQuality } from "@/lib/mesh"
import { useAppState, useQuietRepeater, useRadioSf } from "@/lib/queries"
import type { RepeaterQuiet } from "@/lib/types"
import { TriangleAlertIcon, XIcon } from "lucide-react"
import { Link } from "react-router"

const AMBER = "text-amber-700 dark:text-amber-400"

const LEVEL = ["", "below the decode limit, so it can't be relied on", "marginal: many packets will be lost", "fair", "good"]

/** The best repeater left, in words: how well it reaches you and which way it is. */
function NextBest({ next }: { next: NonNullable<RepeaterQuiet["next"]> }) {
  const sf = useRadioSf()
  const { data: state } = useAppState()
  const home = state?.home
  const where = home && next.lat != null && next.lon != null
    ? ` It's ${Math.round(km(home, { lat: next.lat, lon: next.lon }))} km ${bearing(home, { lat: next.lat, lon: next.lon })} of home: a higher spot, or a window facing that way, helps.`
    : ""
  return (
    <>Best repeater reaching you now: <Link to={`/repeaters/${next.key}`}>{next.name}</Link> at {next.snr} dB ({LEVEL[snrQuality(next.snr, sf)]}).{where}</>
  )
}

/** On a repeater's page, while it has gone quiet. */
export function QuietRepeaterAlert({ quiet, snr, yours }: { quiet: RepeaterQuiet; snr: number | null; yours: boolean }) {
  const sf = useRadioSf()
  const strong = snrQuality(snr, sf) >= 3   // at least 5 dB of headroom
  return (
    <Alert className="border-amber-500/40">
      <TriangleAlertIcon className={AMBER} />
      <AlertTitle>Silent since {clock(quiet.since)} ({ago(quiet.since)})</AlertTitle>
      <AlertDescription className="grid gap-1.5">
        <p>
          Nothing has come straight from it since then, though at its usual rate about {quiet.expected} of
          the {quiet.missed} packets you've heard since would have.{" "}
          {strong
            ? "It was coming in strongly until then, so it has most likely stopped: lost power, crashed, or had its settings changed."
            : "It was only just within reach, so conditions may simply have changed."}
          {yours ? " It's the repeater that passes on your messages, so they may not get through until it's back." : ""}
        </p>
        {quiet.next ? <p><NextBest next={quiet.next} /></p> : null}
      </AlertDescription>
    </Alert>
  )
}

/** Above the composer: your repeater has gone quiet. Dismissed until it goes quiet again. */
export function QuietRepeaterBar() {
  const q = useQuietRepeater()
  const [dismissed, setDismissed] = useLocal<string>("quietDismissed", "")
  const id = q ? `${q.key}:${q.quiet.since}` : ""
  if (!q || dismissed === id) return null
  return (
    <div role="status" className="flex items-start gap-2.5 border-t bg-background px-3 py-2 text-sm">
      <TriangleAlertIcon className={`mt-0.5 size-4 shrink-0 ${AMBER}`} aria-hidden />
      <p className="min-w-0 flex-1 text-muted-foreground">
        Your repeater <span className="font-medium text-foreground">{q.name}</span> has been silent since {clock(q.quiet.since)}:
        messages may not get through.{" "}
        <Link to={`/repeaters/${q.key}`} className="whitespace-nowrap text-foreground underline underline-offset-3">What to do</Link>
      </p>
      <Button variant="ghost" size="icon-sm" className="-my-1 shrink-0" aria-label="Dismiss" onClick={() => setDismissed(id)}><XIcon /></Button>
    </div>
  )
}
