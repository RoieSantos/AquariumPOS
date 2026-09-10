import { defineConfig } from 'vite';

// Builds into www/, matching capacitor.config.json's webDir (Capacitor's default is dist/).
export default defineConfig({
  build: {
    outDir: 'www',
    emptyOutDir: true
  }
});
