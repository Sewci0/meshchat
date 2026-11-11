import { Separator } from "@/components/ui/separator"
import { SidebarTrigger } from "@/components/ui/sidebar"
import type { ReactNode } from "react"

export function PageHeader({ title, description, children }: { title: ReactNode; description?: ReactNode; children?: ReactNode }) {
  return (
    <header className="flex min-h-14 shrink-0 items-center gap-2 border-b bg-background px-3 sm:px-4">
      <SidebarTrigger className="-ml-1" />
      <Separator orientation="vertical" className="mr-1 data-[orientation=vertical]:h-5" />
      <div className="min-w-0 flex-1 py-2">
        <h1 className="truncate text-sm font-semibold leading-tight">{title}</h1>
        {description ? <p className="truncate text-xs text-muted-foreground">{description}</p> : null}
      </div>
      {children ? <div className="flex shrink-0 items-center gap-2">{children}</div> : null}
    </header>
  )
}
