import { defineConfig, loadEnv } from 'electron-vite'
import { resolve } from 'path'

export default defineConfig(({ mode }) => {
  const fileEnv = loadEnv(mode, __dirname, '')
  const keys = ['BAIDU_CLIENT_ID', 'BAIDU_CLIENT_SECRET', 'BAIDU_REDIRECT_URI', 'BAIDU_SCOPE']
  const define = Object.fromEntries(keys.map(key => [`process.env.${key}`, JSON.stringify(process.env[key]?.trim() || fileEnv[key]?.trim() || '')]))
  return {
    main: { define, build: { rollupOptions: { input: resolve(__dirname, 'src/main/index.ts') } } },
    preload: { build: { rollupOptions: { input: resolve(__dirname, 'src/preload/index.ts') } } },
    renderer: { define, resolve: { alias: { '@': resolve(__dirname, 'src/renderer') } } }
  }
})
