// Joining a channel, from the join dialog, a listened channel's chat or the Channels page:
// save it on the radio, update the cached state, stop listening to it, open it.
import { useQueryClient } from "@tanstack/react-query"
import { useNavigate } from "react-router"
import { api } from "./api"
import { keys } from "./queries"
import { chanConv, convPath } from "./routes"
import type { AppState } from "./types"

export function useJoinChannel() {
  const qc = useQueryClient()
  const navigate = useNavigate()
  /** Throws with the radio's message if it refuses. Hashtag channels need no secret. */
  return async (name: string, secret: string | null = null) => {
    const st = await api.joinChannel(name, secret)
    qc.setQueryData<AppState>(keys.state, st)
    void qc.invalidateQueries({ queryKey: keys.listening })
    const ch = st.channels.find((c) => c.name === name)
    if (ch) navigate(convPath(chanConv(ch.idx)))
    return st
  }
}
