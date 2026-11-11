// Saving the map home (Settings, or tapping the map): store it, update the cached state.
import { useQueryClient } from "@tanstack/react-query"
import { api } from "./api"
import { keys } from "./queries"
import type { AppState } from "./types"

export function useSetHome() {
  const qc = useQueryClient()
  return async (lat: number, lon: number, label?: string) => {
    const home = await api.setHome(lat, lon, label)
    qc.setQueryData<AppState>(keys.state, (s) => (s ? { ...s, home } : s))
    return home
  }
}
