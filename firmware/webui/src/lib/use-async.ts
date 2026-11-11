// Run an async action from a button or form: tracks "busy" so the control can disable itself,
// and reports failures as a toast instead of every component repeating try/catch/finally.
import { useCallback, useRef, useState } from "react"
import { toast } from "sonner"

export interface AsyncOptions<T> {
  /** toast title when it fails; the error message becomes the description */
  error?: string
  /** toast after success: a title, a title with a description, or a function of the result (return nothing for no toast) */
  success?: Toast | ((result: T) => Toast | void)
}
type Toast = string | { title: string; description?: string; action?: { label: string; onClick: () => void } }

export function useAsync() {
  const [busy, setBusy] = useState<string | null>(null)
  const running = useRef(false)
  /** `key` lets one component track several actions (e.g. one per row). Returns undefined on failure. */
  const run = useCallback(async <T,>(fn: () => Promise<T>, opts: AsyncOptions<T> = {}, key = "default"): Promise<T | undefined> => {
    if (running.current) return undefined
    running.current = true
    setBusy(key)
    try {
      const result = await fn()
      const s = typeof opts.success === "function" ? opts.success(result) : opts.success
      if (typeof s === "string") toast.success(s)
      else if (s) toast.success(s.title, { description: s.description, action: s.action })
      return result
    } catch (err) {
      toast.error(opts.error ?? "That didn't work", { description: (err as Error).message })
      return undefined
    } finally {
      running.current = false
      setBusy(null)
    }
  }, [])
  return { run, busy, isBusy: (key = "default") => busy === key }
}
