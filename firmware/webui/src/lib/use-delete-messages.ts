// Deleting from MeshChat's history on the radio: one message, or a whole conversation. Caches are
// updated at once; the radio also tells other open pages.
import { useQueryClient } from "@tanstack/react-query"
import { api } from "./api"
import { keys } from "./queries"
import type { Message } from "./types"

export function useDeleteMessages() {
  const qc = useQueryClient()
  const refresh = () => { void qc.invalidateQueries({ queryKey: keys.state }); void qc.invalidateQueries({ queryKey: keys.people }) }
  return {
    deleteMessage: async (m: Message) => {
      await api.deleteMessage(m.id)
      qc.setQueryData<Message[]>(keys.messages(m.conv), (old) => old?.filter((x) => x.id !== m.id))
      refresh()
    },
    deleteConversation: async (conv: string) => {
      const res = await api.deleteConversation(conv)
      qc.setQueryData<Message[]>(keys.messages(conv), [])
      refresh()
      return res.deleted
    },
  }
}
