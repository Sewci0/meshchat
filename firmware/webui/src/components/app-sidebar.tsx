import { useActions } from "@/components/app-provider"
import { NodeAvatar } from "@/components/mesh-bits"
import { Button } from "@/components/ui/button"
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuRadioGroup,
  DropdownMenuRadioItem, DropdownMenuSeparator, DropdownMenuSub, DropdownMenuSubContent, DropdownMenuSubTrigger, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { Kbd } from "@/components/ui/kbd"
import {
  Sidebar, SidebarContent, SidebarFooter, SidebarGroup, SidebarGroupAction, SidebarGroupContent, SidebarGroupLabel,
  SidebarHeader, SidebarMenu, SidebarMenuBadge, SidebarMenuButton, SidebarMenuItem, SidebarRail, useSidebar,
} from "@/components/ui/sidebar"
import { useSocketStatus } from "@/lib/live"
import { useLastRead } from "@/lib/local"
import { ago, convTitle } from "@/lib/mesh"
import { prefetchMessages, useAppState, useListening } from "@/lib/queries"
import { useQueryClient } from "@tanstack/react-query"
import { useTheme, type Theme } from "@/lib/theme"
import { cn } from "@/lib/utils"
import { chanConv, convFromPath, convPath, watchConv } from "@/lib/routes"
import { useSidebarSwipe } from "@/lib/use-sidebar-swipe"
import { isRoomConv, roomList, ROLE_TEXT } from "@/lib/rooms"
import {
  ChevronsUpDownIcon, EarIcon, EyeOffIcon, HashIcon, MapIcon, MegaphoneIcon, MessageSquarePlusIcon, NetworkIcon, PlusIcon, QrCodeIcon,
  RadioTowerIcon, ScanLineIcon, ScrollTextIcon, SearchIcon, SettingsIcon, SunMoonIcon, UsersRoundIcon,
} from "lucide-react"
import { Link, useLocation } from "react-router"

export function AppSidebar() {
  const { data: state } = useAppState()
  const qc = useQueryClient()
  const socket = useSocketStatus()
  const { advertise, joinChannel, joinRoom, newMessage, contactQr, openCommand } = useActions()
  const { theme, setTheme } = useTheme()
  const { pathname } = useLocation()
  const { openMobile, setOpenMobile, isMobile } = useSidebar()
  useSidebarSwipe({ open: openMobile, setOpen: setOpenMobile, enabled: isMobile })
  const { data: listening } = useListening()
  const [lastRead] = useLastRead()
  const close = () => isMobile && setOpenMobile(false)

  const online = socket === "open" && !!state?.connected
  const status = socket !== "open" ? "Radio unreachable" : state?.connected ? null : "Radio not connected"
  const r = state?.self.radio
  const unread = (conv: string) => (state?.conversations[conv]?.last_id ?? 0) > (lastRead[conv] ?? 0)
  const rooms = roomList(state)
  const dms = Object.values(state?.conversations ?? {}).filter((c) => c.conv.startsWith("dm:") && !isRoomConv(state, c.conv)).sort((a, b) => b.last_ts - a.last_ts)
  const openConv = convFromPath(pathname)
  const openDm = openConv?.startsWith("dm:") && !isRoomConv(state, openConv) ? openConv : null
  if (openDm && !dms.some((d) => d.conv === openDm)) dms.unshift({ conv: openDm, last_id: 0, n: 0, last_ts: 0 })
  // an open room that isn't listed (not joined, no posts): show it while it's open
  if (openConv && isRoomConv(state, openConv) && !rooms.some((x) => x.conv === openConv)) {
    const k = openConv.slice(3)
    rooms.unshift({ key: k, name: convTitle(state, openConv), conv: openConv, room: null, last_ts: 0, posts: 0 })
  }
  const visible = !!state?.advertised?.flood

  // channels the radio reads without joining: the ones with messages first
  const listened = [...(listening?.listening ?? [])].sort((a, b) => b.last - a.last || a.name.localeCompare(b.name))
  const nav = [
    { to: "/map", label: "Map", icon: MapIcon },
    { to: "/repeaters", label: "Repeaters", icon: RadioTowerIcon },
    { to: "/rooms", label: "Rooms", icon: UsersRoundIcon },
    { to: "/nodes", label: "Nodes", icon: NetworkIcon },
    { to: "/packets", label: "Packets", icon: ScrollTextIcon },
  ]

  return (
    <Sidebar collapsible="offcanvas">
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <SidebarMenuButton size="lg" className="data-[state=open]:bg-sidebar-accent">
                  <span className="relative">
                    <NodeAvatar name={state?.self.name ?? "?"} />
                    <span aria-hidden className={cn("absolute -right-0.5 -bottom-0.5 size-2.5 rounded-full ring-2 ring-sidebar",
                      online ? "bg-emerald-500" : "bg-red-500")} />
                  </span>
                  <span className="grid min-w-0 flex-1 text-left leading-tight">
                    <span className="truncate font-semibold">{state?.self.name ?? "MeshChat"}</span>
                    <span className="truncate text-xs text-muted-foreground">
                      {status ?? (r ? `${r.freq} MHz · SF${r.sf} · ${r.bw} kHz` : "Connecting…")}
                    </span>
                  </span>
                  <ChevronsUpDownIcon className="ml-auto size-4 opacity-60" />
                </SidebarMenuButton>
              </DropdownMenuTrigger>
              <DropdownMenuContent className="w-64" align="start" side="bottom">
                <DropdownMenuLabel className="font-normal">
                  <div className="font-medium">{state?.self.name}</div>
                  <div className="text-xs text-muted-foreground">
                    {state?.self.model} · {state?.self.fw} · {state?.connected ? "connected" : "disconnected"}
                  </div>
                </DropdownMenuLabel>
                <DropdownMenuSeparator />
                <DropdownMenuItem onSelect={advertise}><MegaphoneIcon />Send flood advert…</DropdownMenuItem>
                <DropdownMenuItem asChild><Link to="/settings" onClick={close}><SettingsIcon />Settings</Link></DropdownMenuItem>
                <DropdownMenuSub>
                  <DropdownMenuSubTrigger><SunMoonIcon />Theme</DropdownMenuSubTrigger>
                  <DropdownMenuSubContent>
                    <DropdownMenuRadioGroup value={theme} onValueChange={(v) => setTheme(v as Theme)}>
                      <DropdownMenuRadioItem value="system">System</DropdownMenuRadioItem>
                      <DropdownMenuRadioItem value="light">Light</DropdownMenuRadioItem>
                      <DropdownMenuRadioItem value="dark">Dark</DropdownMenuRadioItem>
                    </DropdownMenuRadioGroup>
                  </DropdownMenuSubContent>
                </DropdownMenuSub>
              </DropdownMenuContent>
            </DropdownMenu>
          </SidebarMenuItem>
          <SidebarMenuItem>
            <SidebarMenuButton onClick={openCommand} className="text-muted-foreground">
              <SearchIcon />
              <span>Search</span>
              <Kbd className="ml-auto">⌘K</Kbd>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>

      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupLabel>Channels</SidebarGroupLabel>
          <SidebarGroupAction title="Join a channel" onClick={joinChannel}><PlusIcon /><span className="sr-only">Join a channel</span></SidebarGroupAction>
          <SidebarGroupContent>
            <SidebarMenu>
              {state?.channels.map((c) => {
                const conv = chanConv(c.idx)
                return (
                  <SidebarMenuItem key={c.idx}>
                    <SidebarMenuButton asChild isActive={openConv === conv}>
                      <Link to={convPath(conv)} onClick={close} onPointerDown={() => void prefetchMessages(qc, conv)}>
                        <HashIcon />
                        <span className={cn("truncate", unread(conv) && "font-semibold")}>{c.name.replace(/^#/, "")}</span>
                      </Link>
                    </SidebarMenuButton>
                    {unread(conv) ? <SidebarMenuBadge><span className="size-2 rounded-full bg-primary" /><span className="sr-only">unread</span></SidebarMenuBadge> : null}
                  </SidebarMenuItem>
                )
              })}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>

        {listened.length ? (
          <SidebarGroup>
            <SidebarGroupLabel>Listening</SidebarGroupLabel>
            <SidebarGroupAction title="Listen to another channel" onClick={joinChannel}>
              <PlusIcon /><span className="sr-only">Listen to another channel</span>
            </SidebarGroupAction>
            <SidebarGroupContent>
              <SidebarMenu>
                {listened.map((w) => {
                  const conv = watchConv(w.name)
                  return (
                    <SidebarMenuItem key={w.name}>
                      <SidebarMenuButton asChild isActive={openConv === conv} className={cn(!w.count && "text-muted-foreground")}>
                        <Link to={convPath(conv)} onClick={close} onPointerDown={() => void prefetchMessages(qc, conv)} title={w.count ? `${w.count} messages since the radio started` : "Nothing heard yet"}>
                          <EarIcon />
                          <span className={cn("truncate", unread(conv) && "font-semibold")}>{w.name.replace(/^#/, "")}</span>
                        </Link>
                      </SidebarMenuButton>
                      {unread(conv) ? <SidebarMenuBadge><span className="size-2 rounded-full bg-primary" /><span className="sr-only">unread</span></SidebarMenuBadge> : null}
                    </SidebarMenuItem>
                  )
                })}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        ) : null}

        {rooms.length || Object.values(state?.contacts ?? {}).some((c) => c.type === "room") ? (
          <SidebarGroup>
            <SidebarGroupLabel>Rooms</SidebarGroupLabel>
            <SidebarGroupAction title="Join a room" onClick={() => joinRoom()}><PlusIcon /><span className="sr-only">Join a room</span></SidebarGroupAction>
            <SidebarGroupContent>
              <SidebarMenu>
                {rooms.map((x) => (
                  <SidebarMenuItem key={x.conv}>
                    <SidebarMenuButton asChild isActive={openConv === x.conv} className={cn(!x.room && !x.posts && "text-muted-foreground")}>
                      <Link to={convPath(x.conv)} onClick={close} onPointerDown={() => void prefetchMessages(qc, x.conv)}
                        title={x.room?.role ? `${ROLE_TEXT[x.room.role].label} · ${x.posts} posts` : `${x.posts} posts`}>
                        <UsersRoundIcon />
                        <span className={cn("truncate", unread(x.conv) && "font-semibold")}>{x.name}</span>
                      </Link>
                    </SidebarMenuButton>
                    {unread(x.conv) ? <SidebarMenuBadge><span className="size-2 rounded-full bg-primary" /><span className="sr-only">unread</span></SidebarMenuBadge> : null}
                  </SidebarMenuItem>
                ))}
                {!rooms.length ? (
                  <p className="px-2 py-1 text-xs text-muted-foreground">
                    Room servers keep posts for everyone who joins. <button className="underline underline-offset-2" onClick={() => joinRoom()}>Join one</button>.
                  </p>
                ) : null}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        ) : null}

        <SidebarGroup>
          <SidebarGroupLabel>Direct messages</SidebarGroupLabel>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <SidebarGroupAction title="New message or contact"><PlusIcon /><span className="sr-only">New message or contact</span></SidebarGroupAction>
            </DropdownMenuTrigger>
            <DropdownMenuContent side="right" align="start" className="w-60">
              <DropdownMenuItem onSelect={newMessage}><MessageSquarePlusIcon />New direct message</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => contactQr("scan")}><ScanLineIcon />Add contact from QR code</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => contactQr("share")}><QrCodeIcon />Show my QR code</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
          <SidebarGroupContent>
            <SidebarMenu>
              {dms.map(({ conv }) => {
                const name = convTitle(state, conv)
                return (
                  <SidebarMenuItem key={conv}>
                    <SidebarMenuButton asChild isActive={openConv === conv}>
                      <Link to={convPath(conv)} onClick={close} onPointerDown={() => void prefetchMessages(qc, conv)}>
                        <NodeAvatar name={name} className="size-5" />
                        <span className={cn("truncate", unread(conv) && "font-semibold")}>{name}</span>
                      </Link>
                    </SidebarMenuButton>
                    {unread(conv) ? <SidebarMenuBadge><span className="size-2 rounded-full bg-primary" /><span className="sr-only">unread</span></SidebarMenuBadge> : null}
                  </SidebarMenuItem>
                )
              })}
              {!dms.length ? (
                <p className="px-2 py-1 text-xs text-muted-foreground">
                  Start one with <button className="underline underline-offset-2" onClick={newMessage}>new message</button>, or click a name in a channel.
                </p>
              ) : null}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>

        <SidebarGroup>
          <SidebarGroupLabel>Explore</SidebarGroupLabel>
          <SidebarGroupContent>
            <SidebarMenu>
              {nav.map(({ to, label, icon: Icon }) => (
                <SidebarMenuItem key={to}>
                  <SidebarMenuButton asChild isActive={pathname.startsWith(to)}>
                    <Link to={to} onClick={close}><Icon /><span>{label}</span></Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>

      <SidebarFooter>
        {!visible ? (
          <div className="rounded-lg border bg-background p-3 text-xs">
            <div className="flex items-center gap-1.5 font-medium"><EyeOffIcon className="size-3.5" />Nobody can DM you yet</div>
            <p className="mt-1 text-muted-foreground">Send one flood advert so others' radios learn your key.</p>
            <Button size="sm" className="mt-2 w-full" onClick={advertise}><MegaphoneIcon />Send advert</Button>
          </div>
        ) : (
          <p className="px-2 text-xs text-muted-foreground">
            Visible as <span className="font-medium text-foreground">{state?.advertised?.name}</span> · advert {ago(state?.advertised?.ts)} · location hidden
          </p>
        )}
      </SidebarFooter>
      <SidebarRail />
    </Sidebar>
  )
}
