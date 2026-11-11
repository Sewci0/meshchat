import { AppProvider } from "@/components/app-provider"
import { AppSidebar } from "@/components/app-sidebar"
import { ErrorBoundary } from "@/components/error-boundary"
import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar"
import { Toaster } from "@/components/ui/sonner"
import { Spinner } from "@/components/ui/spinner"
import { TooltipProvider } from "@/components/ui/tooltip"
import { useLiveUpdates } from "@/lib/live"
import { useLocal } from "@/lib/local"
import { api } from "@/lib/api"
import { useAppState } from "@/lib/queries"
import { convFromPath, convPath } from "@/lib/routes"
import { ChatPage } from "@/pages/chat"
import { NodesPage } from "@/pages/nodes"
import { RoomsPage } from "@/pages/rooms"
import { PacketsPage } from "@/pages/packets"
import { RepeatersPage } from "@/pages/repeaters"
import { SettingsPage } from "@/pages/settings"
import { lazy, Suspense, useEffect } from "react"
import { Navigate, Route, Routes, useLocation } from "react-router"

// Leaflet is the heaviest dependency; load it only when the map is opened.
const MapPage = lazy(() => import("@/pages/map").then((m) => ({ default: m.MapPage })))

function Home() {
  const [last] = useLocal("lastConv", "chan:0")
  return <Navigate to={convPath(last)} replace />
}

function RememberConversation() {
  const { pathname } = useLocation()
  const [, setLast] = useLocal("lastConv", "chan:0")
  useEffect(() => { const conv = convFromPath(pathname); if (conv) setLast(conv) }, [pathname, setLast])
  return null
}

/** Once the radio answers, offer it this browser's clock (it keeps it only if its own is behind). */
function SyncRadioClock() {
  const loaded = !!useAppState().data
  useEffect(() => { if (loaded) void api.syncTime().catch(() => {}) }, [loaded])
  return null
}

export function App() {
  useLiveUpdates()
  const { pathname } = useLocation()
  return (
    <TooltipProvider delayDuration={300}>
      <AppProvider>
        {/* The top edge on iPhone (iOS 26+): see #ios-top-band in index.html. It has to exist from the
            first frame, so it lives in the HTML, not here. */}
        <SidebarProvider>
          <AppSidebar />
          {/* safe areas: status bar above (0 with the default status bar style), home indicator below,
              notch at the sides in landscape (all 0 on desktop).
              overflow-clip, not -hidden: a hidden box can still be scrolled by focus/scrollIntoView
              (iOS does it when the keyboard opens), which shifts the whole app up */}
          <SidebarInset className="h-svh min-w-0 overflow-clip pt-safe pb-safe px-safe">
            <RememberConversation />
            <SyncRadioClock />
            <ErrorBoundary resetKey={pathname}>
            <Suspense fallback={<div className="grid h-full place-items-center"><Spinner className="size-6" /></div>}>
              <Routes>
                <Route path="/" element={<Home />} />
                <Route path="/c/:conv" element={<ChatPage />} />
                <Route path="/map" element={<MapPage />} />
                <Route path="/repeaters" element={<RepeatersPage />} />
                <Route path="/repeaters/:key" element={<RepeatersPage />} />
                <Route path="/nodes" element={<NodesPage />} />
                <Route path="/rooms" element={<RoomsPage />} />
                <Route path="/packets" element={<PacketsPage />} />
                <Route path="/settings" element={<SettingsPage />} />
                <Route path="*" element={<Navigate to="/" replace />} />
              </Routes>
            </Suspense>
            </ErrorBoundary>
          </SidebarInset>
        </SidebarProvider>
        <Toaster position="bottom-right" mobileOffset={{ bottom: "calc(env(safe-area-inset-bottom) + 16px)" }} />
      </AppProvider>
    </TooltipProvider>
  )
}
