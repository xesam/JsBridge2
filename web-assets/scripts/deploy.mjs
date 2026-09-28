import { createHash } from 'node:crypto'
import { readFileSync, copyFileSync, mkdirSync, rmSync, readdirSync, statSync, existsSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(fileURLToPath(import.meta.url), '../../..')
const DEMO_DIST = join(ROOT, 'web-assets/packages/demo/dist')

const PLATFORM_ROOTS = {
  android: join(ROOT, 'js_bridge_android/js-bridge-example/src/main/assets/web'),
  ios:     join(ROOT, 'js_bridge_ios/js-bridge-example/WebAssets'),
  flutter: join(ROOT, 'js_bridge_flutter/assets/web'),
  harmony: join(ROOT, 'js_bridge_harmony/js-bridge-example/entry/src/main/resources/rawfile/web'),
}

const CONFORMANCE_CASES = {
  android: join(ROOT, 'js_bridge_android/js-bridge-example/src/test/js/bridge-client-conformance.cases.js'),
  ios:     join(ROOT, 'js_bridge_ios/js-bridge-example/tests/js/bridge-client-conformance.cases.js'),
  flutter: join(ROOT, 'js_bridge_flutter/tests/js/bridge-client-conformance.cases.js'),
  harmony: join(ROOT, 'js_bridge_harmony/tests/js/bridge-client-conformance.cases.js'),
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

/// 「产物 ⊆ 源」校验：构建产物必须能追溯到现役源文件。
/// 构建脚本若只增不减（tsc 的 declarationDir、demo 的递归 copy），重构残留会静默留存
/// 并进入 npm 发布包或四端副本。此校验把残留变成可检测的失败（见 .bugfix/BUG-03）。
///
/// - derive: 由源文件列表推出应有产物（相对 dist 的路径）
/// - extra:  构建脚本刻意产出、无同名源文件的产物
const ARTIFACT_PACKAGES = {
  sdk: {
    dir: 'packages/sdk',
    derive: (srcFiles) =>
      srcFiles
        .filter((file) => file.endsWith('.ts'))
        .map((file) => join('esm', file.replace(/\.ts$/, '.d.ts'))),
    extra: [join('esm', 'index.js'), join('iife', 'jsbridge-sdk.js')],
  },
  demo: {
    dir: 'packages/demo',
    derive: (srcFiles) => srcFiles,
    extra: ['jsbridge-sdk.js'],
  },
}

function checkPackageArtifacts() {
  let ok = true
  for (const [name, pkg] of Object.entries(ARTIFACT_PACKAGES)) {
    const pkgDir = join(ROOT, 'web-assets', pkg.dir)
    const expected = [...pkg.derive(collectFiles(join(pkgDir, 'src'))), ...pkg.extra]
    let actual
    try {
      actual = collectFiles(join(pkgDir, 'dist'))
    } catch {
      console.error(`FAIL ${name} artifacts: dist 缺失，请先 pnpm build`)
      ok = false
      continue
    }
    const expectedSet = new Set(expected)
    const actualSet = new Set(actual)
    let pkgOk = true
    for (const file of actual) {
      if (!expectedSet.has(file)) {
        console.error(`FAIL ${name} artifact: dist/${file} 无对应源文件（陈旧残留，重建或删除）`)
        pkgOk = false
      }
    }
    for (const file of expected) {
      if (!actualSet.has(file)) {
        console.error(`FAIL ${name} artifact: dist/${file} 缺失（构建不完整）`)
        pkgOk = false
      }
    }
    if (pkgOk) {
      console.log(`${name} artifacts check passed: ${actual.length} files ⊆ src`)
    } else {
      ok = false
    }
  }
  return ok
}

/// 四端副本 ⊆ demo/dist：sync 只拷贝不删除，源侧删除文件后四端副本会残留。
function checkPlatformResidue(files) {
  const expected = new Set(files)
  let ok = true
  for (const [platform, root] of Object.entries(PLATFORM_ROOTS)) {
    let actual
    try {
      actual = collectFiles(root)
    } catch {
      console.error(`FAIL residue: ${platform} WebAssets 缺失`)
      ok = false
      continue
    }
    for (const file of actual) {
      if (!expected.has(file)) {
        console.error(`FAIL residue: ${platform} 存在无源副本 ${file}（删除或补回源文件）`)
        ok = false
      }
    }
  }
  return ok
}

/// 发布产物完整性：构建产物必须全部进入 npm tarball，且 package.json 声明的入口必须存在。
/// `files` 白名单漏项会让主消费产物（IIFE bundle）静默缺失；`exports` / `unpkg` / `jsdelivr`
/// 的路径错误只在消费者侧暴露。两者都在此变成可检测的失败（见 .bugfix/BUG-02）。
const SDK_DIR = join(ROOT, 'web-assets/packages/sdk')

function isPublished(file, files) {
  return files.some((entry) => {
    const norm = entry.replace(/^\.\//, '').replace(/\/+$/, '')
    return file === norm || file.startsWith(`${norm}/`)
  })
}

function collectEntryPoints(field) {
  if (typeof field === 'string') return [field]
  if (field && typeof field === 'object') return Object.values(field).flatMap(collectEntryPoints)
  return []
}

function checkPublishCoverage() {
  const pkgJson = JSON.parse(readFileSync(join(SDK_DIR, 'package.json'), 'utf8'))
  const files = pkgJson.files ?? []
  let ok = true

  // 1) dist 产物 ⊆ files 白名单：构建产物 = 发布内容
  let artifacts = []
  try {
    artifacts = collectFiles(join(SDK_DIR, 'dist'))
  } catch {
    return true // dist 缺失已由 checkPackageArtifacts 报错
  }
  for (const file of artifacts) {
    if (!isPublished(`dist/${file}`, files)) {
      console.error(`FAIL publish: 产物 dist/${file} 不在 package.json "files" 白名单内（不会进入 tarball）`)
      ok = false
    }
  }

  // 2) 声明的入口必须存在且会被发布
  const entryPoints = [
    ...collectEntryPoints(pkgJson.exports),
    ...(pkgJson.unpkg ? [pkgJson.unpkg] : []),
    ...(pkgJson.jsdelivr ? [pkgJson.jsdelivr] : []),
  ]
  for (const raw of entryPoints) {
    const rel = raw.replace(/^\.\//, '')
    if (!existsSync(join(SDK_DIR, rel))) {
      console.error(`FAIL publish: 入口 ${raw} 不存在于包目录`)
      ok = false
    } else if (!isPublished(rel, files)) {
      console.error(`FAIL publish: 入口 ${raw} 不在 "files" 白名单内`)
      ok = false
    }
  }

  if (ok) {
    console.log(`publish coverage check passed: dist 产物 ⊆ files，${entryPoints.length} 个入口可达`)
  }
  return ok
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

/// JS-client conformance cases 文件四端各存一份副本，仅 SDK 路径行不同（平台目录结构差异）。
/// 校验方式：归一化 root 路径行后四端互比，防止改一端忘三端的漂移。
function normalizeCasesContent(content) {
  return content.replace(/^(\s*)const root = path\.resolve\(__dirname, .*$/m, '$1const root = path.resolve(__dirname, "<PLATFORM_WEB_ASSETS>")')
}

function checkConformanceCases() {
  let reference = null
  let failed = false
  for (const [platform, filePath] of Object.entries(CONFORMANCE_CASES)) {
    let content
    try {
      content = readFileSync(filePath, 'utf8')
    } catch {
      console.error(`FAIL conformance cases: missing on ${platform}`)
      failed = true
      continue
    }
    const normalized = normalizeCasesContent(content)
    if (reference === null) {
      reference = normalized
    } else if (normalized !== reference) {
      console.error(`FAIL conformance cases: ${platform} content drift`)
      failed = true
    }
  }
  if (!failed) {
    console.log(`conformance cases check passed: ${Object.keys(CONFORMANCE_CASES).length} platforms`)
  }
  return !failed
}

function check(files) {
  if (files === undefined) {
    try {
      files = collectFiles(DEMO_DIST)
    } catch {
      console.error('FAIL packages/demo/dist 缺失，请先 pnpm build')
      process.exit(1)
    }
  }
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
  if (!checkConformanceCases()) {
    failed = true
  }
  if (!checkPackageArtifacts()) {
    failed = true
  }
  if (!checkPlatformResidue(files)) {
    failed = true
  }
  if (!checkPublishCoverage()) {
    failed = true
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
