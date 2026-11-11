import path from "node:path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

// The radio serves this UI (`npm run build` writes it to dist/, which ../gen_webui_assets.py embeds
// in the firmware) and owns /api and /ws. `npm run dev` serves the UI from here and proxies /api and
// /ws to a radio running the MeshChat firmware: MESHCHAT_BACKEND=http://<radio> picks which one.
// The radio only accepts requests addressed to itself from its own origin, so the proxy rewrites
// Host and Origin to match (dev only).
const backend = process.env.MESHCHAT_BACKEND ?? "http://meshcore.local"

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: false,
    // Vendor code changes rarely: separate chunks cache across app updates.
    rolldownOptions: {
      output: {
        codeSplitting: {
          groups: [
            { name: "react", test: /node_modules[\\/](react|react-dom|react-router|scheduler)[\\/]/ },
            { name: "radix", test: /node_modules[\\/](radix-ui|@radix-ui|cmdk)[\\/]/ },
            { name: "query", test: /node_modules[\\/]@tanstack[\\/]/ },
          ],
        },
      },
    },
  },
  server: {
    proxy: {
      "/api": {
        target: backend,
        changeOrigin: true,
        configure: (proxy) => proxy.on("proxyReq", (req) => req.setHeader("origin", backend)),
      },
      "/ws": { target: backend, ws: true, changeOrigin: true, headers: { origin: backend } },
    },
  },
})
