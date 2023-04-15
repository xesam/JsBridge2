# Repository Guidelines

## Principles

- 使用简体中文进行输出

## Project Goal

多端 JS-Native bridge 库。同一套协议、同一会话模型、同一套 WebAssets 运行在 Android / iOS / Flutter / HarmonyOS 四端。目标是**跨端协议一致性**，而非共享运行时。

两条核心原则塑造所有设计决策：

1. **Protocol consistency** — 消息信封、策略链求值顺序、握手契约、错误码基线在四端完全一致。运行时按平台各自独立实现（Java / Swift / Dart / ArkTS），共享的只有协议。
2. **Progressive enhancement** — 只有核心协议是必须的。**其余一切可插拔**，在宿主显式启用前保持惰性：`HandshakeGatePolicy` / `AccessControlPolicy`（Level 0 关闭）、`extraPolicies`（空）、整个 `extensions` 层（不接线，`core` 从不依赖它）。

添加功能时，默认形态是"关闭且可选"——不是"默认开启加 escape hatch"。如果某功能无法做成可插拔，需论证为何它属于核心协议。完整五原则列表见 `docs/03-cross-platform.md §1.2`。

## Module Structure

```
js_bridge_android/js-bridge-core/          Android library module（参考实现）
js_bridge_android/js-bridge-example/       Android demo app
js_bridge_ios/js-bridge-core-swift/        iOS Swift Package（Bridge core + BridgeSystem transport）
js_bridge_ios/js-bridge-example/           iOS demo app
js_bridge_flutter/packages/js_bridge_core/ Flutter core package
js_bridge_flutter/                         Flutter host app
js_bridge_hm/js-bridge-core/              HarmonyOS HAR core
js_bridge_hm/js-bridge-example/           HarmonyOS demo app
web-assets/                               共享 WebAssets 正本（sdk/ + demo/）
docs/                                     项目文档
build-jsbridge-from-0-to-1/                 从零实现教程
scripts/                                  工具脚本（test_all.sh / test_android.sh / ...）
```

## Architecture

### 三层叠加架构（各端通用）

```
api          → 稳定公共契约（BridgeMessage, BridgeError, BridgeApiContract, TrustedPageContext）
core/        → Tier 1: 纯协议分发（CoreBridge + handler 接口 + BridgeTransport）
security/    → Tier 2 组件: 上下文、策略链、session/capability（纯逻辑，无 UI）
  JsBridge   → Tier 2 入口: 会话/策略/握手，叠加在 CoreBridge 之上
extensions   → Tier 3: 可选适配器（lifecycle / registry / system）
```

依赖方向单向，反映三层叠加：`JsBridge → CoreBridge → api`，`security → CoreBridge | api`，`extensions → JsBridge | CoreBridge | api`。CoreBridge 零 security 依赖，security 零 core 依赖。transport 与 security 不得互相引用。

**入站闭环**：Android 通过 `resetTransport()` 建立双向闭环；iOS/Flutter/HM 通过 `bindTransport()` 建立等价闭环（`transport.bind { json → processIncomingResponses → transport.send }`）。iOS 的 `WKWebViewBridgeTransport` 封装 `WKScriptMessageHandler` + `evaluateJavaScript` + bootstrap script，消费者无需手写管道代码。

### Protocol v1 Message Envelope

Fields: `id`, `sessionId`, `kind`, `method`, `ts`, `timeoutMs`, `keep`, `payload`, `reqId`, `done`, `ok`, `error`

`kind` 值：`request`（JS→Native）、`response`（Native→JS）、`event`（Native→JS 推送）

### Security Policy Chain（固定求值顺序）

策略始终按此顺序执行，任一返回 `allowed=false` 短路整条链：

1. `RequestShapePolicy` — 校验消息结构
2. `HandshakeGatePolicy` — session 建立前阻断非握手调用
3. `AccessControlPolicy` — origin、session、capability 校验
4. `extraPolicies` — 宿主注入的自定义规则

策略链通过 `JsBridge.SecurityConfig` **可选且渐进**启用。默认 Level 0（仅 `RequestShapePolicy` 激活），`resetForNewPage()` 后立即可用——无需握手。宿主显式升级：

- `new SecurityConfig()` → Level 0（裸分发；开发/测试/可信本地页面）
- `new SecurityConfig().withHandshakeGate()` → Level 1（需握手，无 origin/capability 校验）
- `SecurityConfig.secure()` → Level 2（增加 `AccessControlPolicy`；生产场景——配置 `allowedOrigins`、`methodWhitelist`、`defaultCapabilities`、`sessionTtlMs`）

Level 1/2 下，`isReady()` 在 `bridge.handshake` 完成前保持 false。Origin 匹配为精确匹配（无前缀匹配）。相同的三级模型在四端均存在等价 API。

握手方法：`bridge.handshake`。生命周期推送方法：`runtime.state`——payload 固定 `{state, seq}`，未 ready 时排队、握手后按序补发（详见 `docs/01-protocol.md` §7.2）；触发时机与 state 取值由宿主定义。

### 三层生命周期模型

| 层面 | 生命周期 | 实现键 | 管理方 |
|------|---------|--------|--------|
| Layer 1: Native 能力 | WebView | `CoreBridge` 实例 + handler 注册表 | Native |
| Layer 2: Session | WebView × 一次页面加载 | `JsBridge` + `pageInstanceId` + `origin` | Native (`SessionService`) |
| Layer 3: Scope | WebView × 一个逻辑页面 | `AbortSignal` (JS 侧) + `scopeId` (协议字段) | JS (`BridgeClient`) |

详见 `docs/06-lifecycle-layers.md`。

### Shared WebAssets

SDK 源码位于 `web-assets/packages/sdk/src/`（TypeScript），构建产物由 `web-assets/scripts/deploy.mjs` 同步到四端。

WebAssets 正本为 `jsbridge-sdk.js` bundle + demo 文件。`pnpm sync` 取代了原来的 `python3 scripts/web_assets.py`。四端 WebAssets 副本不纳入版本控制，由 `pnpm sync` 填充，因此修改 `web-assets/packages/` 下任何内容后必须重新执行 `pnpm sync`。

构建输出为 ESM（npm 消费者）+ IIFE `jsbridge-sdk.js` bundle（Native `<script src>` 加载），通过 Babel 转译到 ES5 以支持旧版 WebView。

JS-client conformance suite（`bridge-client-conformance.cases.js`）每端各存一份副本（路径不同——如 `js_bridge_android/js-bridge-example/src/test/js/`、`js_bridge_hm/tests/js/`）。直接用 `node <path>/bridge-client-conformance.cases.js` 运行。

### Platform Implementations

| Platform | Language | Core entry point | Transport impl |
|----------|----------|-----------------|----------------|
| Android | Java (Java 8) | `js_bridge_android/js-bridge-core` — 参考实现 | `extensions/system/AndroidWebViewBridgeTransport` |
| iOS | Swift Package | `js_bridge_ios/js-bridge-core-swift/Sources/Bridge/` | `Sources/BridgeSystem/WKWebViewBridgeTransport` |
| Flutter | Dart | `js_bridge_flutter/packages/js_bridge_core/lib/src/` | 宿主注入函数 + `bindTransport()` |
| HarmonyOS | ArkTS | `js_bridge_hm/js-bridge-core/src/main/ets/` | 宿主注入函数 + `bindTransport()` |

## Build & Test Commands

### All platforms (convenience runners)
```bash
scripts/test_all.sh        # Android + iOS + Flutter + HarmonyOS（HM 在无 DevEco SDK 时跳过）
scripts/test_android.sh    # 各平台独立 runner：
scripts/test_ios.sh        #   test_ios.sh / test_flutter.sh / test_hm.sh
```
`test_all.sh` 报告每端 PASS/FAIL/SKIP，任一失败则非零退出。

### Android
```bash
cd js_bridge_android
./gradlew :js-bridge-core:test                  # 单元测试
./gradlew :js-bridge-core:test --tests "*.PolicyGroupsTest"  # 单个测试类
./gradlew :js-bridge-example:assembleDebug
./gradlew lint
```

### iOS
```bash
cd js_bridge_ios
swift test --package-path js-bridge-core-swift
xcodebuild -project js-bridge-example/JsBridgeExample.xcodeproj \
  -scheme JsBridgeExample \
  -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

### Flutter
```bash
cd js_bridge_flutter/packages/js_bridge_core
flutter test                                    # core package 测试
cd ../..
flutter test                                    # host app 测试
flutter analyze
```

### HarmonyOS
```bash
cd js_bridge_hm/js-bridge-example
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
  /Applications/DevEco-Studio.app/Contents/tools/node/bin/node \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw.js \
  assembleHap --mode module -p product=default --no-daemon
```

### Shared WebAssets
```bash
cd web-assets && pnpm sync    # 构建 SDK（esbuild + Babel→ES5）+ 同步到四端 + 校验
cd web-assets && pnpm check   # 仅校验（不构建）— SHA-256 比对四端共享文件
```

## Coding Conventions

### Android
- Java 8，包根 `io.github.xesam.android.bridge`
- 4 空格缩进，`PascalCase` 类名，`camelCase` 方法/字段，`UPPER_SNAKE_CASE` 常量
- 角色后缀：`*Policy`、`*Activity`、`*Plugin`、`*Service`
- 测试类命名：`<ClassName>Test`；方法命名：`scenario_expectedBehavior`
- 框架：JUnit4（`test`），AndroidX Instrumentation + Espresso（`androidTest`）

### iOS（Swift）、Flutter（Dart）、HarmonyOS（ArkTS）
- iOS：遵循 Swift API Design Guidelines；公共 API 变更须向后兼容
- Flutter：遵循 Dart style guide；文件名 `snake_case`
- HarmonyOS：Stage model；遵守 ArkTS 语法限制——不使用 `any`/动态特性

## Conformance

C01–C30 用例验证跨端行为。Native-core 用例（C01–C13, C17, C18, C28–C30）位于各平台的 `ConformanceCoreBaseline*` 测试中；JS-client 用例（C14–C16, C19–C27）位于共享的 `bridge-client-conformance.cases.js` 中。所有用例必须在每个平台全部通过。修改 bridge 契约（策略、消息路由、session 行为）或新增用例时，须同步更新四端。

任何 WebAssets 变更后必须执行 `pnpm sync` 重新构建并同步，再执行 `pnpm check` 验证四端一致性。

## Commit Style

Conventional Commits 格式：`feat(scope): ...`、`fix(scope): ...`、`refactor(scope): ...`

scope 按模块：

| scope | 对应内容 |
|-------|---------|
| `android-core` | `js_bridge_android/js-bridge-core` |
| `ios-core` | `js_bridge_ios/js-bridge-core-swift` |
| `flutter-core` | `js_bridge_flutter/packages/js_bridge_core` |
| `hm-core` | `js_bridge_hm/js-bridge-core` |
| `web-assets` | `web-assets/` 及四端镜像 |
| `docs` | `docs/` |

## Further Reading

`docs/` 下的深度文档：

| 文档 | 说明 |
|------|------|
| `01-protocol.md` | Protocol v1 消息格式与语义 |
| `02-architecture.md` | 分层内核设计与依赖方向 |
| `03-cross-platform.md` | 跨端一致性约束与 WebAssets 管理 |
| `04-conformance.md` | Conformance 用例说明（C01–C30） |
| `05-review.md` | 架构评审——原则成立处、已知跨端 API 差异、设计债务 |
| `06-lifecycle-layers.md` | 三层生命周期模型：Native 能力 / Session / Scope，及 SPA 场景分析 |

修改跨端契约前，先更新对应文档。
