// What the device and browser can do. Phones differ from desktops in ways the UI must respect:
// no hover (tooltips never open), a finger instead of a pointer, and no geolocation on the
// radio's plain-HTTP pages.
import { useSyncExternalStore } from "react"

const query = (q: string) => (typeof window !== "undefined" ? window.matchMedia(q) : null)
const coarse = query("(pointer: coarse)")
const hover = query("(hover: hover)")

function useMedia(m: MediaQueryList | null) {
  return useSyncExternalStore(
    (l) => { m?.addEventListener("change", l); return () => m?.removeEventListener("change", l) },
    () => m?.matches ?? false,
  )
}

/** A finger rather than a mouse: bigger targets, select on tap only. */
export const isCoarsePointer = () => coarse?.matches ?? false
export const useCoarsePointer = () => useMedia(coarse)
/** Can the user hover? If not, hints must open on tap. */
export const useCanHover = () => useMedia(hover)

/** Running from the home screen (iOS/Android "app"), not in a browser tab. */
export const isStandalone = () =>
  typeof window !== "undefined" &&
  (window.matchMedia("(display-mode: standalone)").matches || (navigator as Navigator & { standalone?: boolean }).standalone === true)

export const isIOS = () =>
  typeof navigator !== "undefined" &&
  (/iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1))

/** Browsers only share location with secure pages (HTTPS or localhost); the radio serves plain HTTP. */
export const canGeolocate = () => typeof window !== "undefined" && window.isSecureContext && "geolocation" in navigator
