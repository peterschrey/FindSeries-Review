/// <reference types="vitest" />
import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

const apiPort = Number(process.env.REVIEW_API_PORT ?? 8787);
const apiTarget = `http://127.0.0.1:${apiPort}`;

const apiProxy = {
  '/api': {
    target: apiTarget,
    changeOrigin: true,
  },
} as const;

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: { ...apiProxy },
  },
  // FRV-45: preview must proxy /api to the same REVIEW_API_PORT as the launcher.
  preview: {
    port: 5173,
    proxy: { ...apiProxy },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test/setup.ts'],
  },
});
