// The shell every page shares: a header, then a body that fills the rest and scrolls on its own
// (the app frame itself never scrolls; see app.tsx).
import { PageHeader } from "@/components/page-header"
import { cn } from "@/lib/utils"
import type { ReactNode } from "react"

export function Page({ title, description, actions, children, className }: {
  title: ReactNode; description?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string
}) {
  return (
    <div className={cn("flex h-full min-h-0 flex-col", className)}>
      <PageHeader title={title} description={description}>{actions}</PageHeader>
      {children}
    </div>
  )
}

const WIDTH = { "3xl": "max-w-3xl", "4xl": "max-w-4xl", full: "" } as const

/** A scrolling column of cards or sections, centred and padded. */
export function PageBody({ width = "3xl", className, children }: { width?: keyof typeof WIDTH; className?: string; children: ReactNode }) {
  return (
    <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain">
      <div className={cn("mx-auto grid gap-4 p-4 sm:p-6", WIDTH[width], className)}>{children}</div>
    </div>
  )
}
