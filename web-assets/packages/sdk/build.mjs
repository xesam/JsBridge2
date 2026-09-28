import * as esbuild from 'esbuild'
import * as babel from '@babel/core'
import presetEnv from '@babel/preset-env'
import { execSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs'

// 先清理 dist：tsc 的 declarationDir 只增不减——重构移走源文件后，旧 .d.ts 会静默
// 留存并随 npm 包发布。构建必须幂等（见 .bugfix/BUG-03）。
rmSync('dist', { recursive: true, force: true })
mkdirSync('dist/esm', { recursive: true })
mkdirSync('dist/iife', { recursive: true })

// ESM：给 npm 消费者（import { getBridge } from 'jsbridge-sdk'）
await esbuild.build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  format: 'esm',
  outfile: 'dist/esm/index.js',
  platform: 'browser',
})

// 类型声明（.d.ts）
execSync('node_modules/.bin/tsc --emitDeclarationOnly', { stdio: 'inherit' })

// IIFE：给 native bundle（<script src="./jsbridge-sdk.js">）
await esbuild.build({
  entryPoints: ['src/index.ts'],
  bundle: true,
  format: 'iife',
  globalName: 'JsBridgeSDK',
  outfile: 'dist/iife/jsbridge-sdk.js',
  platform: 'browser',
})

// 低版本 Android WebView 兼容：语法降级到 ES5
const iifeOutfile = 'dist/iife/jsbridge-sdk.js'
const { code } = await babel.transformAsync(readFileSync(iifeOutfile, 'utf-8'), {
  presets: [[presetEnv, { targets: { ie: '11' } }]],
})
writeFileSync(iifeOutfile, code)

console.log('Build complete → dist/esm/ + dist/iife/')
