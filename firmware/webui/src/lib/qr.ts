// QR codes: reading one from a photo or screenshot, and drawing one. Both libraries load on first
// use, so they cost nothing until someone opens the dialog.
//
// Why photos and not a live camera view: the radio serves this app over plain http, and browsers
// (iOS Safari above all) only open the camera stream on https. A file input with capture works
// everywhere: it opens the camera for a photo, or lets you pick a screenshot of a code.

/** The text of the QR code in an image, or null if none was found. A big camera photo is scaled
 *  down first, then tried larger if that fails: a small code far away needs the pixels. */
export async function readQr(file: Blob): Promise<string | null> {
  const [{ default: jsQR }, bmp] = await Promise.all([import("jsqr"), createImageBitmap(file)])
  try {
    for (const max of [1000, 2000, 3000]) {
      const s = Math.min(1, max / Math.max(bmp.width, bmp.height))
      const w = Math.round(bmp.width * s), h = Math.round(bmp.height * s)
      const canvas = document.createElement("canvas")
      canvas.width = w
      canvas.height = h
      const ctx = canvas.getContext("2d", { willReadFrequently: true })
      if (!ctx) return null
      ctx.drawImage(bmp, 0, 0, w, h)
      const code = jsQR(ctx.getImageData(0, 0, w, h).data, w, h, { inversionAttempts: "attemptBoth" })
      if (code?.data) return code.data
      if (s === 1) break   // already at full size
    }
    return null
  } finally {
    bmp.close()
  }
}

/** A QR code as an SVG path, one unit per module, for drawing in currentColor at any size. */
export async function qrPath(text: string): Promise<{ size: number; d: string }> {
  const { default: qrcode } = await import("qrcode-generator")
  const qr = qrcode(0, "M")
  qr.addData(text, "Byte")
  qr.make()
  const n = qr.getModuleCount()
  let d = ""
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) if (qr.isDark(r, c)) d += `M${c} ${r}h1v1h-1z`
  }
  return { size: n, d }
}
