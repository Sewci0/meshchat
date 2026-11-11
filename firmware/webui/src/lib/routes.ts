// Conversation ids and their URLs, in one place. Ids are "chan:<idx>", "dm:<pubkey>" and
// "watch:#name" (a channel the radio only listens to). The last contains '#', which must be
// encoded in a path or the browser treats the rest as a fragment, so always build links here.
export const chanConv = (idx: number) => `chan:${idx}`
export const dmConv = (pubkey: string) => `dm:${pubkey}`
export const watchConv = (name: string) => `watch:${name}`

/** The chat URL for a conversation id. */
export const convPath = (conv: string) => `/c/${encodeURIComponent(conv)}`
/** The conversation id from a chat URL, or null on other pages. */
export const convFromPath = (pathname: string) => (pathname.startsWith("/c/") ? decodeURIComponent(pathname.slice(3)) : null)
