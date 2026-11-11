// Channels the radio hears but can't read, and how many you're in or listening to. Shown in the
// join dialog (sidebar +), where a name typed and listened to is checked against their packets.
import { Item, ItemContent, ItemDescription, ItemGroup, ItemMedia, ItemTitle } from "@/components/ui/item"
import { ago, plural } from "@/lib/mesh"
import { useAppState, useListening as useListeningData } from "@/lib/queries"
import type { Listening } from "@/lib/types"
import { cn } from "@/lib/utils"
import { LockIcon } from "lucide-react"

export function UnreadableList({ data }: { data: Listening }) {
  const rows = [...data.unreadable].sort((a, b) => b.count - a.count)
  if (!rows.length) return <p className="text-sm text-muted-foreground">None: every channel packet since the radio started was readable.</p>
  return (
    <ItemGroup className="rounded-xl border">
      {rows.map((u, i) => (
        <Item key={u.hash} size="sm" className={cn(i > 0 && "border-t")}>
          <ItemMedia variant="icon"><LockIcon /></ItemMedia>
          <ItemContent>
            <ItemTitle>Channel <code className="rounded bg-muted px-1 font-mono text-xs">{u.hash}</code></ItemTitle>
            <ItemDescription>{plural(u.count, "packet", "packets")} · last {ago(u.last)}</ItemDescription>
          </ItemContent>
        </Item>
      ))}
    </ItemGroup>
  )
}

/** In the join dialog: how many channels you're in or listening to, and the channels the radio
 *  hears but can't read (unknown hashtag names, or private channels): a name typed above and
 *  listened to is checked against their stored packets at once. */
export function ChannelOverview() {
  const { data: state } = useAppState()
  const { data } = useListeningData()
  if (!state || !data) return null
  const joined = state.channels.length
  return (
    <div className="grid gap-2 border-t pt-3 text-sm">
      <p className="text-muted-foreground">
        Joined <span className="text-foreground tabular-nums">{joined}</span> {joined === 1 ? "channel" : "channels"} · listening to{" "}
        <span className="text-foreground tabular-nums">{data.listening.length}</span> of {data.max} without using a slot
      </p>
      <details className="group">
        <summary className="cursor-pointer font-medium">
          Heard but can't read <span className="font-normal text-muted-foreground">· {data.unreadable.length} {data.unreadable.length === 1 ? "channel" : "channels"}</span>
        </summary>
        <p className="my-2 text-muted-foreground">
          Private channels, or hashtag channels whose name the radio doesn't know. Packets carry only a 1-byte code, so one code can
          stand for several channels. Know a name? Type it above and choose Listen only: if it matches, its recent messages appear at once.
        </p>
        <UnreadableList data={data} />
      </details>
    </div>
  )
}
