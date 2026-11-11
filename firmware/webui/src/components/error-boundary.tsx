import { Button } from "@/components/ui/button"
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from "@/components/ui/empty"
import { TriangleAlertIcon } from "lucide-react"
import { Component, type ErrorInfo, type ReactNode } from "react"

/** Keeps one broken screen from blanking the whole app. Resets when `resetKey` changes (e.g. on navigation). */
export class ErrorBoundary extends Component<{ children: ReactNode; resetKey?: string }, { error: Error | null; key?: string }> {
  state: { error: Error | null; key?: string } = { error: null }

  static getDerivedStateFromError(error: Error) { return { error } }

  static getDerivedStateFromProps(props: { resetKey?: string }, state: { error: Error | null; key?: string }) {
    return props.resetKey !== state.key ? { error: null, key: props.resetKey } : null
  }

  componentDidCatch(error: Error, info: ErrorInfo) { console.error("MeshChat screen crashed:", error, info.componentStack) }

  render() {
    if (!this.state.error) return this.props.children
    return (
      <Empty className="h-full">
        <EmptyHeader>
          <EmptyMedia variant="icon"><TriangleAlertIcon /></EmptyMedia>
          <EmptyTitle>Something went wrong on this screen</EmptyTitle>
          <EmptyDescription>{this.state.error.message}</EmptyDescription>
        </EmptyHeader>
        <EmptyContent><Button onClick={() => location.reload()}>Reload MeshChat</Button></EmptyContent>
      </Empty>
    )
  }
}
