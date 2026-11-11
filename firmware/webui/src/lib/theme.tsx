// Light / dark / system theme via the `.dark` class shadcn's CSS expects.
// (next-themes injects an inline <script>, which our Content-Security-Policy blocks.)
import { createContext, useContext, useEffect, useMemo, useSyncExternalStore, type ReactNode } from "react"
import { useLocal } from "./local"

export type Theme = "light" | "dark" | "system"
const media = typeof window !== "undefined" ? window.matchMedia("(prefers-color-scheme: dark)") : null
const useSystemDark = () =>
  useSyncExternalStore((l) => { media?.addEventListener("change", l); return () => media?.removeEventListener("change", l) },
    () => media?.matches ?? false)

const Ctx = createContext<{ theme: Theme; resolved: "light" | "dark"; setTheme: (t: Theme) => void }>({
  theme: "system", resolved: "light", setTheme: () => {},
})

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useLocal<Theme>("theme", "system")
  const systemDark = useSystemDark()
  const resolved = theme === "system" ? (systemDark ? "dark" : "light") : theme
  useEffect(() => {
    const root = document.documentElement
    root.classList.toggle("dark", resolved === "dark")
    root.style.colorScheme = resolved
    // status bar of the home-screen app and the browser's toolbar: match --background
    for (const m of document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]')) {
      m.content = resolved === "dark" ? "#0a0a0a" : "#ffffff"
      if (theme !== "system") m.removeAttribute("media")
    }
  }, [resolved, theme])
  const value = useMemo(() => ({ theme, resolved, setTheme }), [theme, resolved, setTheme])
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export const useTheme = () => useContext(Ctx)
