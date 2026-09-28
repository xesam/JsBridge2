# Repository Guidelines

## Principles

- 使用简体中文进行输出

## Project Goal

多端 JS-Native bridge 库。同一套协议、同一会话模型、同一套 WebAssets 运行在 Android / iOS / Flutter / HarmonyOS 四端。目标是**跨端协议一致性**，而非共享运行时。

核心设计原则详见 `docs/01-design-principles.md`。

## Module Structure

```
js_bridge_android/js-bridge-core/          Android library module（参考实现）
js_bridge_android/js-bridge-example/       Android demo app
js_bridge_ios/js-bridge-core-swift/        iOS Swift Package（Bridge core + BridgeSystem transport）
js_bridge_ios/js-bridge-example/           iOS demo app
js_bridge_flutter/packages/js_bridge_core/ Flutter core package
js_bridge_flutter/                         Flutter host app
js_bridge_harmony/js-bridge-core/         HarmonyOS HAR core
js_bridge_harmony/js-bridge-example/      HarmonyOS demo app
web-assets/                               共享 WebAssets 正本（sdk/ + demo/）
docs/                                     项目文档
build-jsbridge-from-0-to-1/                 从零实现教程
scripts/                                  工具脚本（test_all.sh / test_android.sh / ...）
```

## Architecture

详细架构设计见 `docs/02-architecture.md`。

### 三层叠加架构（各端通用）

```
api          → 稳定公共契约（BridgeMessage, BridgeError, BridgeApiContract, TrustedPageContext）
core/        → Tier 1: 纯协议分发（CoreBridge + handler 接口 + BridgeTransport）
security/    → Tier 2 组件: 上下文、策略链、session（纯逻辑，无 UI）
  JsBridge   → Tier 2 入口: 会话/策略/握手，叠加在 CoreBridge 之上
extensions   → Tier 3: 可选适配器（lifecycle / registry / system）
```

依赖方向单向，反映三层叠加：`JsBridge → CoreBridge → api`，`security → api`，`extensions → JsBridge | CoreBridge | api`（`system` 适配器还实现 security 层的 `PageContextProvider` SPI）。CoreBridge 零 security 依赖，security 零 core 依赖。transport 与 security 不得互相引用（Swift 单 target 形态下按符号级执行，见 docs/07）。

**入站闭环**：Android 通过 `resetTransport()` 建立双向闭环；iOS/Flutter/HarmonyOS 通过 `bindTransport()` 建立等价闭环（`transport.bind { json → processIncomingResponses → transport.send }`）。iOS 的 `WKWebViewBridgeTransport` 封装 `WKScriptMessageHandler` + `evaluateJavaScript` + bootstrap script，消费者无需手写管道代码。

### Protocol v1 Message Envelope

协议详见 `docs/03-protocol.md`。

消息信封字段：`id`, `sessionId`, `kind`, `method`, `ts`, `timeoutMs`, `keep`, `payload`, `reqId`, `done`, `ok`, `error`, `scopeId`（可选 request 字段）

`kind` 值：`request`（JS→Native）、`response`（Native→JS）、`event`（Native→JS 推送）

**纯异步消息模型（不支持同步调用）**：详见 `docs/03-protocol.md §1 消息模型`。

### Security Policy Chain（固定求值顺序）

策略链详见 `docs/02-architecture.md §4`。

策略始终按此顺序执行，任一返回 `allowed=false` 短路整条链：

1. `RequestShapePolicy` — 校验消息结构
2. `HandshakeGatePolicy` — session 建立前阻断非握手调用（`SecurityConfig` 非 null 时进链）
3. `OriginPolicy` — origin 白名单校验（opt-in，`allowedOrigins` 不含 `*` 时进链）
4. `MethodGatePolicy` — 业务方法白名单校验（opt-in，`methodWhitelist` 不含 `*` 时进链；协议方法由框架装配期自动并入放行集）
5. `SessionPolicy` — session 有效性、origin/pageInstanceId 匹配（`SecurityConfig` 非 null 时进链）
6. `extraPolicies` — 宿主注入的自定义规则

`allowedOrigins` 和 `methodWhitelist` 的值语义：`null` = 未配置（`SecurityConfig` 非 null 时构造期报错）；包含 `"*"` 的集合（如 `{"*"}`）= 显式不限制该维度（对应节点不进链；判定为四端一致的 `contains("*")`，混入具体值时整集按"不限制"处理）；具体值集合 = 启用白名单校验。`methodWhitelist` 为**业务方法白名单**——协议方法（`bridge.handshake` / `bridge.cancelScope`）由框架在装配期自动并入放行集，宿主无需显式列入（显式列入亦合法，冗余无副作用）。

握手方法：`bridge.handshake`。生命周期推送方法：`runtime.state`——payload 固定 `{state, seq}`，未 ready 时排队、握手后按序补发（详见 `docs/03-protocol.md` §7.2）；触发时机与 state 取值由宿主定义。

### 三层生命周期模型

| 层面 | 生命周期 | 实现键 | 管理方 |
|------|---------|--------|--------|
| Layer 1: Native 能力 | WebView | `CoreBridge` 实例 + handler 注册表 | Native |
| Layer 2: Session | WebView × 一次页面加载 | `JsBridge` + `pageInstanceId` + `origin` | Native (`SessionService`) |
| Layer 3: Scope | WebView × 一个逻辑页面 | `AbortSignal` (JS 侧) + `scopeId` (协议字段) | JS (`CoreBridgeClient`) |

详见 `docs/05-lifecycle-layers.md`。

### Shared WebAssets

SDK 源码位于 `web-assets/packages/sdk/src/`（TypeScript），构建产物由 `web-assets/scripts/deploy.mjs` 同步到四端。

WebAssets 正本为 `jsbridge-sdk.js` bundle + demo 文件。`pnpm sync` 取代了原来的 `python3 scripts/web_assets.py`。四端 WebAssets 副本不纳入版本控制，由 `pnpm sync` 填充，因此修改 `web-assets/packages/` 下任何内容后必须重新执行 `pnpm sync`。

构建输出为 ESM（npm 消费者）+ IIFE `jsbridge-sdk.js` bundle（Native `<script src>` 加载）。其中**只有 IIFE 产物**通过 Babel 转译到 ES5 以支持旧版 WebView；ESM 产物保留现代语法，由消费者的打包器按自身 targets 降级。两份产物都由 `pnpm sync` 构建并进入 npm 包（`files` 白名单含 `dist/esm` 与 `dist/iife`）。

JS-client conformance suite（`bridge-client-conformance.cases.js`）每端各存一份副本（路径不同——如 `js_bridge_android/js-bridge-example/src/test/js/`、`js_bridge_harmony/tests/js/`）。直接用 `node <path>/bridge-client-conformance.cases.js` 运行。

### Platform Implementations

| Platform | Language | Core entry point | Transport impl |
|----------|----------|-----------------|----------------|
| Android | Java (Java 8) | `js_bridge_android/js-bridge-core` — 参考实现 | `extensions/system/AndroidWebViewBridgeTransport` |
| iOS | Swift Package | `js_bridge_ios/js-bridge-core-swift/Sources/Bridge/` | `Sources/BridgeSystem/WKWebViewBridgeTransport` |
| Flutter | Dart | `js_bridge_flutter/packages/js_bridge_core/lib/src/` | 宿主注入函数 + `bindTransport()` |
| HarmonyOS | ArkTS | `js_bridge_harmony/js-bridge-core/src/main/ets/` | 宿主注入函数 + `bindTransport()` |

## Build & Test Commands

### All platforms (convenience runners)
```bash
scripts/test_all.sh            # 四端 + WebAssets + JS conformance + 编号/origin 向量校验一键验证
scripts/test_android.sh        # 各独立 runner：
scripts/test_ios.sh           #   test_android.sh / test_ios.sh / test_flutter.sh / test_harmony.sh
scripts/test_flutter.sh       #   test_web_assets.sh（pnpm sync：构建 + 同步 + 校验）
scripts/test_harmony.sh       #   test_js_conformance.sh（四端 JS 客户端用例副本）
                              #   check_conformance_ids.sh / check_origin_vectors.sh
                              #   （两个一致性校验脚本，随 test_all.sh 必跑，亦可单独执行）
```

退出码约定：`0` = PASS，`125` = SKIP（环境缺失；哪些环境命中 SKIP 以各 runner 脚本头部注释为准，`test_harmony.sh` / `test_web_assets.sh` / `test_js_conformance.sh` / `check_origin_vectors.sh` 具备 SKIP 分支），其余 = FAIL。注意 `test_android.sh` / `test_ios.sh` 工具链（gradlew / Swift 包）缺失时**直接 FAIL（exit 1）**而非 SKIP——Android/iOS 工具链被视为此仓库的必备环境。`test_all.sh` 报告每项 PASS/FAIL/SKIP，任一失败则非零退出。

### Android
```bash
cd js_bridge_android
./gradlew :js-bridge-core:test                                  # 单元测试
./gradlew :js-bridge-core:testReleaseUnitTest --tests "*.PolicyGroupsTest"  # 单个测试类
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
flutter analyze                                 # host app 静态检查（宿主 app 无 Dart 测试）
```

### HarmonyOS
```bash
cd js_bridge_harmony/js-bridge-example
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

C01–C65 用例验证跨端行为（含 C04b，为 C04 的补充用例；C09/C44 为登记空缺，不复用）。Native-core 用例（C01–C13 含 C04b, C17, C18, C28–C30, C33–C38, C43, C48, C49, C51–C56, C60, C61, C62, C64, C65）位于各平台的 `ConformanceCoreBaseline*` 测试中——例外：Android 的 C43 由 `UnifiedHandlerApiTest` 承载，C47 由 `PendingChannelRequestsTest` 承载且仅 Android 存在此形态（已登记缺口，详见 `docs/09-conformance.md §4`）；C45/C46（策略链求值）由各端独立的策略链测试承载——Android `PolicyGroupsTest`、iOS `PolicyChainTests`、Flutter `policy_chain_test.dart`、HarmonyOS `PolicyGroupsTest.test.ets`；JS-client 用例（C14–C16, C19–C27, C31, C32, C39, C40, C41, C50, C57, C63）位于共享的 `bridge-client-conformance.cases.js` 中；C42（宿主 invalidate 桩断言）与 C58/C59（建链安全边界：iOS 主 frame 隔离、JS MessagePort 采纳来源校验）属 instrumented 层，宿主 instrumented 套件尚未建设，属已登记缺口（代码侧逻辑已存在；详见 `docs/09-conformance.md §4`）。用例编号的登记正本以 `docs/09-conformance.md` 为准。所有用例必须在每个平台全部通过。修改 bridge 契约（策略、消息路由、session 行为、信道建立）或新增用例时，须同步更新四端。

编号一致性由 `scripts/check_conformance_ids.sh` 程序化校验（已接入 `test_all.sh`）：检测未登记编号、四端编号漂移、登记未实现、docs/09 自称最大编号与登记表不一致、四端 JS client 副本编号漂移五类问题。合法例外（instrumented 层、已登记缺口）在该脚本中显式列出并与 `docs/09-conformance.md §4` 保持同步。

C54 的 origin 归一化向量（正本 `docs/origin-normalizer-vectors.json`）由 `scripts/check_origin_vectors.sh` 强制四端 C54 测试内嵌同一向量集（已接入 `test_all.sh`）——修改向量正本必须四端同改。

任何 WebAssets 变更后必须执行 `pnpm sync` 重新构建并同步，再执行 `pnpm check` 验证四端一致性。

验收用例义务与触发表详见 `docs/09-conformance.md §6`。

## Commit Style

Conventional Commits 格式：`feat(scope): ...`、`fix(scope): ...`、`refactor(scope): ...`

scope 按模块：

| scope | 对应内容 |
|-------|---------|
| `android-core` | `js_bridge_android/js-bridge-core` |
| `ios-core` | `js_bridge_ios/js-bridge-core-swift` |
| `flutter-core` | `js_bridge_flutter/packages/js_bridge_core` |
| `harmony-core` | `js_bridge_harmony/js-bridge-core` |
| `web-assets` | `web-assets/` 及四端镜像 |
| `docs` | `docs/` |

## Further Reading

`docs/` 下的深度文档：

| 文档 | 说明 |
|------|------|
| `01-design-principles.md` | 五条设计原则及其验证 |
| `02-architecture.md` | 分层内核设计与依赖方向 |
| `03-protocol.md` | Protocol v1 消息格式与语义 |
| `04-cross-platform.md` | 跨端一致性约束与 WebAssets 管理 |
| `05-lifecycle-layers.md` | 三层生命周期模型：Native 能力 / Session / Scope，及 SPA 场景分析 |
| `06-channel-establishment.md` | 信道建立 pull 模型与 reqId 往返 |
| `07-transport-bridge-design.md` | Transport 入站闭环设计（bindTransport / WKWebViewBridgeTransport） |
| `08-handler-interface-contract.md` | CoreBridge 接口契约规范 |
| `09-conformance.md` | Conformance 用例说明（C01–C65） |

各端集成指南位于各平台项目 README 中：`js_bridge_android/README.md`、`js_bridge_ios/README.md`、`js_bridge_flutter/README.md`、`js_bridge_harmony/README.md`。

Web 侧独立工程的文档：`web-assets/README.md`（概览与命令）、`web-assets/docs/01-js-sdk-design.md`（JS SDK 设计）、`web-assets/packages/sdk/README.md`（SDK API）。

修改跨端契约前，先更新对应文档。
