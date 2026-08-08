import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// The dashboard talks to the FastAPI backend over REST. In dev we proxy /api to
// the backend so the browser makes same-origin requests (no CORS surprises),
// while still allowing an explicit VITE_API_BASE_URL override for LAN/prod.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: process.env.VITE_PROXY_TARGET || 'http://127.0.0.1:8000',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
    },
  },
});
