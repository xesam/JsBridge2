# jsbridge-web

JsBridge2 的 **Web 侧独立工程**，使用 pnpm monorepo 管理。维护 JS 客户端 SDK（`jsbridge-sdk`）与 demo 的唯一正本；四端 Native 仓库中的 WebAssets 均为构建产物的镜像，不纳入版本控制，由 `pnpm sync` 填充。

## 文档

| 文档 | 内容 |
|------|------|
| [docs/01-js-sdk-design.md](docs/01-js-sdk-design.md) | JS SDK 设计：分层结构、CoreBridgeClient 机制、传输检测、构建与同步 |
| [packages/sdk/README.md](packages/sdk/README.md) | jsbridge-sdk 使用方式与 API 参考（IIFE / ESM） |
| 根目录 [docs/03-protocol.md](../docs/03-protocol.md) | Protocol v1 协议规范（信封 / 握手 / 错误码） |

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
| `pnpm build` | 构建 sdk（ESM + IIFE + .d.ts）和 demo（先清理各自 `dist/`，构建幂等） |
| `pnpm sync` | build + 同步到四端 native + 校验一致性 |
| `pnpm check` | 仅校验（不构建）：四端 native 目录与 demo/dist 全部共享文件 SHA-256 一致 + conformance cases 四端互比 + 「产物 ⊆ 源」无残留 + 发布覆盖校验（实际产物 ⊆ `files` 白名单、入口可达）；校验清单正本为 `scripts/deploy.mjs` 的 `check()` |
| `pnpm clean:native` | 清除四端 native 目录下的 WebAssets 文件 |
| `pnpm clean:dist` | 清除各包的 `dist/` 构建产物 |
| `pnpm clean` | `clean:native` + `clean:dist` |
| `pnpm publish:sdk` | 发布 `jsbridge-sdk` 到 npm |

> **冒烟测试（手动运行，不接入 `test_all.sh`）**：`packages/sdk/test/smoke-*.cjs`（node 直接执行，mock window/DOM 走 IIFE 产物）——`smoke-pull-transport.cjs`（C40/C41 端口语义）、`smoke-pull-failover.cjs`（超时重试/耗尽 fail-fast）、`smoke-get-bridge.cjs`（装载器失败清缓存/单例复用/ready 三件套）。改 transport/装载器源码后建议手动跑全三支。

> **「产物 ⊆ 源」校验**（`pnpm check`）：`dist/` 与四端副本中的每个文件都必须能追溯到现役源文件，否则报 FAIL 并非零退出。构建脚本若只增不减（`tsc` 的 `declarationDir`、demo 的递归 copy、`deploy.mjs` 的 sync），重构移走源文件后旧产物会静默留存并进入发布包或四端副本——该校验把这类残留变成可检测的失败。构建脚本刻意产出、无同名源文件的产物在 `deploy.mjs` 的 `ARTIFACT_PACKAGES[].extra` 中显式登记。

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

## 四端 native 资产目录

deploy.mjs 同步的目标路径（相对于仓库根目录）：

| 平台 | 路径 |
|------|------|
| Android | `js_bridge_android/js-bridge-example/src/main/assets/web/` |
| iOS | `js_bridge_ios/js-bridge-example/WebAssets/` |
| Flutter | `js_bridge_flutter/assets/web/` |
| HarmonyOS | `js_bridge_harmony/js-bridge-example/entry/src/main/resources/rawfile/web/` |

这些目录不纳入版本管理（gitignored），由 `pnpm sync` 填充。
