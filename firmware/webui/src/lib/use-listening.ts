// Channels the radio reads without joining: start, stop, or turn one into a joined channel.
// Used by the join dialog (sidebar +) and a listened channel's chat.
import { useQueryClient } from "@tanstack/react-query"
import { useNavigate } from "react-router"
import { api } from "./api"
import { keys } from "./queries"
import { chanConv, convPath, watchConv } from "./routes"
import { useJoinChannel } from "./use-join-channel"

/** "#name" from what the user typed ("polska", " #polska "). */
export const hashtagName = (input: string) => { const t = input.trim(); return t ? (t.startsWith("#") ? t : `#${t}`) : "" }
/** what the radio accepts: # plus up to 30 visible characters, at most 31 bytes */
export const validHashtag = (name: string) => /^#[^\s"\\/]{1,30}$/.test(name) && new TextEncoder().encode(name).length <= 31

export function useListening() {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const join = useJoinChannel()
  const refresh = () => qc.invalidateQueries({ queryKey: keys.listening })
  return {
    /** start listening and open it; resolves with how many stored packets it could already read */
    listen: async (name: string) => {
      const res = await api.listen(name)
      await refresh()
      navigate(convPath(watchConv(name)))
      return res.matched ?? 0
    },
    /** stop listening; `leave` opens Public if you were looking at it */
    stop: async (name: string, leave = false) => {
      await api.unlisten(name)
      await refresh()
      if (leave) navigate(convPath(chanConv(0)))
    },
    join,
  }
}
