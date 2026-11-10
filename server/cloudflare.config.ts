import { defineConfig, bindings } from 'cf/config';
export default defineConfig({
  worker: {
    name: 'minimal-chat-api',
    entrypoint: './src/index.js',
    compatibilityDate: '2026-11-10',
    observability: { enabled: true, logs: { enabled: true }, traces: { enabled: true } },
    env: {
      DB: bindings.d1({id:'092d142d-646c-4b80-8245-2c7eff2ee536', name:'minimal-chat-db'}),
      MEDIA: bindings.r2({name:'minimal-chat-media-20261110'})
    }
  }
});

