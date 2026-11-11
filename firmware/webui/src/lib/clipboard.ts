// Copying text. The Clipboard API needs https, which the radio's own page isn't, so fall back to
// copying from a selected, off-screen text field (works in Safari over http too).
export async function copyText(text: string): Promise<boolean> {
  try {
    if (window.isSecureContext && navigator.clipboard) {
      await navigator.clipboard.writeText(text)
      return true
    }
  } catch { /* fall through */ }
  const ta = document.createElement("textarea")
  ta.value = text
  ta.setAttribute("readonly", "")
  ta.style.cssText = "position:fixed;top:0;left:-9999px;opacity:0"
  document.body.appendChild(ta)
  ta.select()
  ta.setSelectionRange(0, text.length)
  let ok = false
  try { ok = document.execCommand("copy") } catch { ok = false }
  ta.remove()
  return ok
}
