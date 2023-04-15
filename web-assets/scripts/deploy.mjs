import { createHash } from 'node:crypto'
import { readFileSync, copyFileSync, mkdirSync, rmSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(fileURLToPath(import.meta.url), '../../..')
const DEMO_DIST = join(ROOT, 'web-assets/packages/demo/dist')

const PLATFORM_ROOTS = {
  android: join(ROOT, 'js_bridge_android/js-bridge-example/src/main/assets/web'),
  ios:     join(ROOT, 'js_bridge_ios/js-bridge-example/WebAssets'),
  flutter: join(ROOT, 'js_bridge_flutter/assets/web'),
  harmony: join(ROOT, 'js_bridge_hm/js-bridge-example/entry/src/main/resources/rawfile/web'),
}

function sha256(filePath) {
  return createHash('sha256').update(readFileSync(filePath)).digest('hex')
}

function collectFiles(dir, base = dir) {
  const files = []
  for (const entry of readdirSync(dir)) {
    const abs = join(dir, entry)
    if (statSync(abs).isDirectory()) {
      files.push(...collectFiles(abs, base))
    } else {
      files.push(relative(base, abs))
    }
  }
  return files
}

function sync() {
  const files = collectFiles(DEMO_DIST)
  let count = 0
  for (const file of files) {
    const src = join(DEMO_DIST, file)
    for (const [, root] of Object.entries(PLATFORM_ROOTS)) {
      const dst = join(root, file)
      mkdirSync(dirname(dst), { recursive: true })
      copyFileSync(src, dst)
    }
    count++
  }
  console.log(`synced ${count} files to ${Object.keys(PLATFORM_ROOTS).length} platforms`)
  check(files)
}

function check(files) {
  files = files ?? collectFiles(DEMO_DIST)
  let failed = false
  for (const file of files) {
    for (const [platform, root] of Object.entries(PLATFORM_ROOTS)) {
      let hash
      try {
        hash = sha256(join(root, file))
      } catch {
        console.error(`FAIL ${file}: missing on ${platform}`)
        failed = true
        continue
      }
      const expected = sha256(join(DEMO_DIST, file))
      if (hash !== expected) {
        console.error(`FAIL ${file}: ${platform} hash mismatch`)
        failed = true
      }
    }
  }
  if (!failed) {
    console.log(`check passed: ${files.length} files`)
  } else {
    process.exit(1)
  }
}

function clean() {
  for (const [platform, root] of Object.entries(PLATFORM_ROOTS)) {
    try {
      rmSync(root, { recursive: true, force: true })
      console.log(`cleaned ${platform}`)
    } catch (e) {
      console.error(`failed to clean ${platform}: ${e.message}`)
    }
  }
}

const cmd = process.argv[2]
if (cmd === 'sync') sync()
else if (cmd === 'check') check()
else if (cmd === 'clean') clean()
else {
  console.log('Usage: node deploy.mjs [sync|check|clean]')
  process.exit(1)
}
