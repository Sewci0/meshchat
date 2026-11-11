// Phones: swipe right to open the sidebar, swipe left to close it. In the home-screen app an opening
// swipe may start anywhere, the very left edge included (it has no Back gesture). In a Safari tab the
// edge is Safari's Back gesture, which runs before the page sees it, so there a swipe must start a
// little way in. Never where horizontal swipes already mean something (the map, text fields,
// sideways-scrolling tables, anything marked data-no-swipe). Only clearly horizontal swipes count, so
// vertical scrolling is never taken over.
import { useEffect } from "react"

const DISTANCE = 64      // px of horizontal travel that commits the swipe
const SYSTEM_EDGE = 20   // px: Safari's back-gesture zone; in a browser tab a swipe starting there is Safari's

/** Running from the home screen (or installed), not in a browser tab. */
function standalone() {
  return window.matchMedia("(display-mode: standalone)").matches || (navigator as Navigator & { standalone?: boolean }).standalone === true
}

function claimedElsewhere(target: EventTarget | null) {
  if (!(target instanceof Element)) return false
  if (target.closest(".leaflet-container, input, textarea, select, [contenteditable=true], [data-slot=input-group], [data-no-swipe]")) return true
  for (let el: Element | null = target; el && el !== document.body; el = el.parentElement) {
    if (el.scrollWidth > el.clientWidth + 1 && /(auto|scroll)/.test(getComputedStyle(el).overflowX)) return true
  }
  return false
}

export function useSidebarSwipe({ open, setOpen, enabled }: { open: boolean; setOpen: (open: boolean) => void; enabled: boolean }) {
  useEffect(() => {
    if (!enabled) return
    let x0 = 0, y0 = 0, intent: "open" | "close" | null = null
    const start = (e: TouchEvent) => {
      if (e.touches.length !== 1) { intent = null; return }
      x0 = e.touches[0].clientX; y0 = e.touches[0].clientY
      const edge = standalone() ? 0 : SYSTEM_EDGE
      intent = open ? "close" : x0 >= edge && !claimedElsewhere(e.target) ? "open" : null
    }
    const move = (e: TouchEvent) => {
      if (!intent) return
      const dx = e.touches[0].clientX - x0, dy = e.touches[0].clientY - y0
      if (Math.abs(dy) > Math.abs(dx) * 0.7 && Math.abs(dy) > 10) { intent = null; return }   // it's a scroll
      if (intent === "open" && dx > DISTANCE) { setOpen(true); intent = null }
      else if (intent === "close" && dx < -DISTANCE) { setOpen(false); intent = null }
    }
    const end = () => { intent = null }
    document.addEventListener("touchstart", start, { passive: true })
    document.addEventListener("touchmove", move, { passive: true })
    document.addEventListener("touchend", end, { passive: true })
    document.addEventListener("touchcancel", end, { passive: true })
    return () => {
      document.removeEventListener("touchstart", start)
      document.removeEventListener("touchmove", move)
      document.removeEventListener("touchend", end)
      document.removeEventListener("touchcancel", end)
    }
  }, [open, setOpen, enabled])
}
