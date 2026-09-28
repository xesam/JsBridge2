import { copyFileSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync, rmSync } from 'node:fs'
import { join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as babel from '@babel/core'
import presetEnv from '@babel/preset-env'

const DIR = fileURLToPath(new URL('.', import.meta.url))
const SRC = join(DIR, 'src')
const DIST = join(DIR, 'dist')
const SDK_IIFE = join(DIR, '../sdk/dist/iife/jsbridge-sdk.js')

// 已是 ES5 产物，跳过转译
const SKIP_TRANSPILE = new Set(['vconsole.min.js'])

// 先清理 dist：copyDir 只增不减——源文件删除后旧副本会留存并被同步到四端
// WebAssets 目录（见 .bugfix/BUG-03）。
rmSync(DIST, { recursive: true, force: true })

mkdirSync(DIST, { recursive: true })
mkdirSync(join(DIST, 'api'), { recursive: true })
mkdirSync(join(DIST, 'page'), { recursive: true })

// SDK bundle
copyFileSync(SDK_IIFE, join(DIST, 'jsbridge-sdk.js'))

// Demo 文件（递归 copy src/ → dist/，.js 文件降级到 ES5）
function copyDir(src, dst, base) {
  mkdirSync(dst, { recursive: true })
  for (const entry of readdirSync(src)) {
    const s = join(src, entry)
    const d = join(dst, entry)
    if (statSync(s).isDirectory()) {
      copyDir(s, d, base)
      continue
    }
    if (entry.endsWith('.js') && !SKIP_TRANSPILE.has(relative(base, s))) {
      const { code } = babel.transformSync(readFileSync(s, 'utf-8'), {
        presets: [[presetEnv, { targets: { ie: '11' } }]],
      })
      writeFileSync(d, code)
    } else {
      copyFileSync(s, d)
    }
  }
}
copyDir(SRC, DIST, SRC)

console.log('Demo build complete → dist/')
