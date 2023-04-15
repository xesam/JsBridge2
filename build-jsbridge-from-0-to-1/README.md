# Tutorial

本目录是《从 0 到 1 写一个 JsBridge》分章节版本。

教程中出现的类名、API、错误码、协议字段与构建命令均与仓库实际实现对齐（以 Android 参考实现 `js_bridge_android/js-bridge-core` 为准；协议规范见 `docs/01-protocol.md`；iOS/Flutter/HarmonyOS 遵循同一协议）。

## 章节导航
1. `01-goals-and-scope.md`
2. `02-framework-direct-interop.md`
3. `03-minimal-protocol.md`
4. `04-handler-dispatcher.md`
5. `05-async-callback.md`
6. `06-core-bridge-extraction.md`
7. `07-transport-abstraction.md`
8. `08-trusted-context-minimal.md`
9. `09-handshake-session-capability.md`
10. `10-policy-engine.md`
11. `11-lifecycle-event-extension.md`
12. `12-registry-and-single-flight.md`
13. `13-error-and-observability.md`
14. `14-testing-by-layers.md`
15. `15-example-app-integration.md`
16. `16-architecture-retrospective.md`

## 章节与仓库实现对照

| 章节 | 核心产出 | 对应实现 |
|------|---------|---------|
| 02 | 直连互调 | `extensions/system/LegacyJavascriptChannel`（低版本兜底通道） |
| 03 | 消息协议 | `api/model/BridgeMessage.java`、`BridgeError.java`、`api/contract/BridgeApiContract.java` |
| 04 | handler 分发 | `core/message/*`、`core/CoreBridge.dispatch()` |
| 05 | 异步回调 | `core/message/MessageHandlerCallback.java`、示例 `RequestExt` / `TimerExt` |
| 06 | 桥接内核 | `core/CoreBridge.java`（Tier 1） |
| 07 | 传输抽象 | `core/transport/BridgeTransport.java`、`extensions/system/AndroidWebViewBridgeTransport.java` |
| 08 | 可信上下文 | `security/context/PageContextProvider.java`、`api/model/TrustedPageContext.java` |
| 09 | 握手与会话 | `JsBridge.java`、`security/session/*` |
| 10 | 策略引擎 | `security/policy/*`、`JsBridge.SecurityConfig`（Level 0/1/2） |
| 11 | 生命周期事件 | `extensions/lifecycle/LifecycleExtension.java`（`runtime.state`） |
| 12 | 结果型扩展 | `extensions/registry/*`（single-flight） |
| 13 | 错误与可观测 | `api/model/BridgeError.java`、`BridgeApiContract` 错误码、`JsBridge.auditReject` |
| 14 | 分层测试 | `js-bridge-core/src/test/*`、conformance 用例（C01–C30） |
| 15 | 示例组装 | `js-bridge-example`（`WebActivity` / `CompatWebActivity` / `BridgePolicyConfig`） |

## 建议使用方式
1. 按顺序阅读并实践。
2. 每章至少完成一个可运行验证。
3. 每章完成后运行一次测试与构建：
```bash
cd js_bridge_android
./gradlew :js-bridge-core:test :js-bridge-example:assembleDebug
```
4. 涉及 JS 侧行为时运行共享 conformance 用例：
```bash
node js_bridge_android/js-bridge-example/src/test/js/bridge-client-conformance.cases.js
```
