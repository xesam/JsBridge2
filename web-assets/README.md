# jsbridge-web

JsBridge2 的 JS 侧工程，包含 SDK 源码和 demo 示例，使用 pnpm monorepo 管理。

## 包结构

```
web-assets/
  packages/
    sdk/        jsbridge-sdk — JS 客户端 SDK，发布到 npm
    demo/       jsbridge-demo — demo 示例，private，不发布
  scripts/
    deploy.mjs                      — 同步产物到四端 native 项目
```

### sdk

SDK 源码，TypeScript 编写，esbuild 构建两份产物：

| 产物 | 路径 | 用途 |
|------|------|------|
| ESM | `dist/esm/index.js` + `index.d.ts` | npm 消费者（`import`） |
| IIFE | `dist/iife/jsbridge-sdk.js` | native bundle（`<script src>`） |

### demo

依赖 `jsbridge-sdk`（workspace 引用），构建后产出 `dist/`，由 `deploy.mjs sync` 复制到四端 native 资产目录。

## 命令

| 命令 | 说明 |
|------|------|
| `pnpm build` | 构建 sdk（ESM + IIFE + .d.ts）和 demo |
| `pnpm sync` | build + 同步到四端 native + 校验一致性 |
| `pnpm check` | 仅校验四端 native 目录与 demo/dist 一致 |
| `pnpm clean:native` | 清除四端 native 目录下的 WebAssets 文件 |
| `pnpm clean:dist` | 清除各包的 `dist/` 构建产物 |
| `pnpm clean` | `clean:native` + `clean:dist` |
| `pnpm publish:sdk` | 发布 `jsbridge-sdk` 到 npm |

## 开发流程

```bash
# 1. 安装依赖（首次 clone 或 pnpm-workspace.yaml 变更后）
pnpm install

# 2. 修改 packages/sdk/src/ 或 packages/demo/src/ 后，同步到四端验证
pnpm sync

# 3. 安装 Android demo 到设备验证效果
cd ../js_bridge_android && ./gradlew :js-bridge-example:installDebug
```

## 发布流程

```bash
# 1. 确认构建和四端一致
pnpm sync

# 2. 更新版本号
pnpm --filter jsbridge-sdk version patch   # 或 minor / major

# 3. 发布到 npm
pnpm publish:sdk
```

## 与 web_assets.py 的关系

`deploy.mjs` 取代了原来的 `scripts/web_assets.py`：

| 旧命令 | 新命令 |
|--------|--------|
| `python3 scripts/web_assets.py` | `pnpm sync` |
| `python3 scripts/web_assets.py --clean` | `pnpm clean:native` |

主要差异：新方案在 sync 前自动执行构建，native 端不再持有散文件，只有一个 `jsbridge-sdk.js` bundle。

## 四端 native 资产目录

deploy.mjs 同步的目标路径（相对于仓库根目录）：

| 平台 | 路径 |
|------|------|
| Android | `js_bridge_android/js-bridge-example/src/main/assets/web/` |
| iOS | `js_bridge_ios/js-bridge-example/WebAssets/` |
| Flutter | `js_bridge_flutter/assets/web/` |
| HarmonyOS | `js_bridge_hm/js-bridge-example/entry/src/main/resources/rawfile/web/` |

这些目录不纳入版本管理（gitignored），由 `pnpm sync` 填充。

