import { useActions } from "@/components/app-provider"
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { ago, contactByName, locatePerson } from "@/lib/mesh"
import { useAppState, useNodes, usePeople } from "@/lib/queries"
import { convPath, dmConv } from "@/lib/routes"
import { AtSignIcon, MapPinIcon, MessageCircleIcon } from "lucide-react"
import type { ReactNode } from "react"
import { useNavigate } from "react-router"

/** Everything you can do with a person you only know by name (channel sender, @tag). */
export function PersonMenu({ name, onMention, children }: { name: string; onMention?: (name: string) => void; children: ReactNode }) {
  const { data: state } = useAppState()
  const { data: people } = usePeople()
  const nodes = useNodes()
  const { showOnMap } = useActions()
  const navigate = useNavigate()
  const contact = contactByName(state, name)
  const person = people?.get(name) ?? { name, n: 0, convs: [], last_ts: 0, last_conv: "", path: null, hops: null }
  const loc = locatePerson(person, state, nodes)

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>{children}</DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-64">
        <DropdownMenuLabel className="font-normal">
          <div className="truncate font-medium">{name}</div>
          <div className="text-xs text-muted-foreground">
            {person.n ? `${person.n} message${person.n > 1 ? "s" : ""} · last ${ago(person.last_ts)}` : "No recent channel messages"}
          </div>
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuItem disabled={!contact} onSelect={() => contact && navigate(convPath(dmConv(contact.pubkey)))}>
          <MessageCircleIcon />
          <div className="grid">
            <span>Message privately</span>
            {!contact ? <span className="text-xs text-muted-foreground">Their advert hasn't reached you yet</span> : null}
          </div>
        </DropdownMenuItem>
        <DropdownMenuItem disabled={!loc} onSelect={() => showOnMap({ kind: "person", name })}>
          <MapPinIcon />
          <div className="grid">
            <span>Show on map</span>
            <span className="text-xs text-muted-foreground">{loc ? (loc.exact ? "GPS position" : "approximate, near a repeater") : "No position or route known"}</span>
          </div>
        </DropdownMenuItem>
        {onMention ? (
          <DropdownMenuItem onSelect={() => onMention(name)}><AtSignIcon />Mention in reply</DropdownMenuItem>
        ) : null}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
