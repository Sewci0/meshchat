// An explanation attached to an element. On a desktop it's a tooltip. Phones can't hover: there an
// informational element (a badge, a status) opens it on tap; a button that does something keeps
// doing that (tapToShow={false}) and relies on its own label.
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"
import { useCanHover } from "@/lib/device"
import { cn } from "@/lib/utils"
import type { ReactElement, ReactNode } from "react"

export function Hint({ content, children, className, tapToShow = true }: {
  content: ReactNode; children: ReactElement; className?: string; tapToShow?: boolean
}) {
  const canHover = useCanHover()
  if (canHover) return (
    <Tooltip>
      <TooltipTrigger asChild>{children}</TooltipTrigger>
      <TooltipContent className={cn("max-w-64", className)}>{content}</TooltipContent>
    </Tooltip>
  )
  if (!tapToShow) return children
  return (
    <Popover>
      <PopoverTrigger asChild>{children}</PopoverTrigger>
      <PopoverContent className={cn("w-auto max-w-64 text-xs", className)} side="top">{content}</PopoverContent>
    </Popover>
  )
}
