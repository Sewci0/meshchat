// Small per-browser preferences (last read message per conversation, chosen ranges, layers).
// localStorage can throw (private mode, blocked storage): every access is guarded.
import { useCallback, useSyncExternalStore } from "react"

const listeners = new Map<string, Set<() => void>>()
const cache = new Map<string, unknown>()

function read<T>(key: string, fallback: T): T {
  if (cache.has(key)) return cache.get(key) as T
  let v = fallback
  try {
    const raw = localStorage.getItem(`meshchat:${key}`)
    if (raw != null) v = JSON.parse(raw) as T
  } catch { /* storage unavailable */ }
  cache.set(key, v)
  return v
}

function write<T>(key: string, value: T) {
  cache.set(key, value)
  try { localStorage.setItem(`meshchat:${key}`, JSON.stringify(value)) } catch { /* ignore */ }
  listeners.get(key)?.forEach((l) => l())
}

export function useLocal<T>(key: string, fallback: T): [T, (v: T | ((prev: T) => T)) => void] {
  const value = useSyncExternalStore(
    (l) => { if (!listeners.has(key)) listeners.set(key, new Set()); listeners.get(key)!.add(l); return () => listeners.get(key)!.delete(l) },
    () => read(key, fallback),
  )
  const set = useCallback((v: T | ((prev: T) => T)) => {
    write(key, typeof v === "function" ? (v as (p: T) => T)(read(key, fallback)) : v)
  }, [key, fallback])
  return [value, set]
}

const EMPTY: Record<string, number> = {}
/** id of the last message seen per conversation */
export const useLastRead = () => useLocal<Record<string, number>>("lastRead", EMPTY)
