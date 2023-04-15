# 从 0 到 1 写一个 JsBridge

本教程面向“第一次做 js-native 通信框架”的工程师，目标是一步步完成一个可用、可扩展、可测试的 JsBridge 库。教程采用“先打通，再抽象，再工程化”的路径，避免一开始陷入复杂设计。

教程各章出现的类名、API、错误码与命令均与本仓库实际实现对齐：Android 参考实现在 `js_bridge_android/js-bridge-core`，协议规范见 `docs/01-protocol.md`。分章节版本见本目录 `01`–`16` 各文件。

## 你将完成什么
- 打通 WebView 中 JS 与 Native 的双向通信。
- 定义稳定的消息协议（request/response/event）。
- 提炼桥接核心（`CoreBridge`）与叠加其上的会话/策略层（`JsBridge`），以及扩展机制（transport/context/policy/registry）。
- 完成一套可维护的分层架构，并具备跨端一致演进能力。

## 学习路径总览
1. 最小互调（框架能力直连）
2. 最小协议（结构化消息）
3. 可复用桥接核心
4. 安全与会话能力
5. 扩展与兼容机制
6. 测试与发布前检查

---

## 第 1 章：定义目标与边界
### 目标
只定义最小成功标准，不做过早设计。

### 最小成功标准
- JS 可以调用 Native 方法。
- Native 可以回调 JS。
- 一次调用可区分成功/失败。

### 非目标
- 不做业务鉴权策略。
- 不做多端共享运行时代码（四端只共享协议）。
- 不做复杂插件系统。

### 验收
- Demo 页面能点击按钮触发 Native 调用，并拿到回调结果。

---

## 第 2 章：直接用 WebView 框架能力打通
### 目标
零抽象完成第一条链路，建立直觉。

### Native 端（示意）
```java
webView.getSettings().setJavaScriptEnabled(true);
webView.addJavascriptInterface(new Object() {
    @JavascriptInterface
    public void postMessage(String message) {
        Log.d("Bridge", message);
        webView.post(() -> webView.evaluateJavascript(
            "window.onNativeMessage('native ok')", null));
    }
}, "NativeBridge");
```

### JS 端（示意）
```js
window.onNativeMessage = (res) => console.log('from native', res)
window.NativeBridge.postMessage('{"method":"ping"}')
```

### 常见坑
- `addJavascriptInterface` 需要 `@JavascriptInterface`。
- 回调 JS 要在主线程执行。
- 这一步先不讨论安全，只求打通。

> 说明：这套 `addJavascriptInterface` + `evaluateJavascript` 并没有被正式实现丢弃——`extensions/system/LegacyJavascriptChannel` 在 SDK < M（无 `WebMessageChannel`）时正是用它兜底；正式通道是 `WebMessageChannel`，见第 7 章。

---

## 第 3 章：定义最小消息协议
### 目标
从“字符串传输”升级到“可解析协议”。

### 协议字段（完整信封）
`id`, `sessionId`, `kind`, `method`, `ts`, `timeoutMs`, `keep`, `payload`, `reqId`, `done`, `ok`, `error`, `scopeId`

- `kind` 值：`request`（JS→Native）、`response`（Native→JS）、`event`（Native→JS 推送）。
- 流式语义：request 可带 `keep=true` 声明持续回调意图；response 用 `done` 标记中间帧（`false`）/最终帧（`true`）。
- 兼容规则：字段只增不改不删；接收方忽略未知字段。

### 建议模型
- `BridgeMessage`（`fromJson` 解析失败返回 `null`，静默丢弃）
- `BridgeError`（`code/message/retryable/details`）
- `BridgeApiContract`（保留方法 `bridge.handshake` / `runtime.state` / `bridge.cancelScope` + 8 个协议错误码基线）

### 验收
- 一次 request 能拿到对应 response（`reqId` 关联）。

---

## 第 4 章：实现最小分发器
### 目标
用 handler 注册替代 if-else 分发。

### 设计
- handler 接口分两个：`SimpleNativeMessageHandler`（只关心 payload）与 `NativeMessageHandler`（带 `TrustedPageContext`，第 8 章引入）。
- `CoreBridge.registerHandler(method, handler)` 注册；`JsBridge.registerNativeHandler` / `registerNativeHandlerWithContext` 是 Tier 2 公开口。
- 收到 request 后按 `method` 查找 handler。
- 未找到时返回 `E_METHOD_NOT_FOUND`；handler 抛异常归一为 `E_INTERNAL`。

### 验收
- 可动态注册多个方法（如 `getUser`、`timerLog`）。

---

## 第 5 章：补齐异步回调语义
### 目标
处理真实业务中的异步场景。

### 回调接口（`MessageHandlerCallback`）
- `success(Object res)`
- `success(Object res, boolean done)`（流式/分段结果）
- `fail(Object error)`

### 验收
- 一个异步任务可在完成后回包（参考示例 `RequestExt`）。
- 失败回包带标准错误码；流式场景多帧 `done=false` + 最终帧 `done=true`（参考 `TimerExt`）。
- handler 不直接拼 JSON 响应，统一走 `CoreBridge.respondSuccess/respondFail`。

---

## 第 6 章：提炼第一版桥接内核 CoreBridge
### 目标
把桥接逻辑从 Activity 中抽离成可复用内核。

### 结果
- 页面层只做初始化和生命周期。
- 业务只关心注册 handler。
- 内核统一处理收包、分发、回包（`registerHandler` / `bind` / `dispatch` / `respondSuccess` / `respondFail` / `postEvent` / `destroy`）。
- 内核零 security 依赖，为第 9 章叠加 `JsBridge` 留出空间。

### 验收
- 第二个页面接入只需复用 bridge 初始化代码。

---

## 第 7 章：抽象传输层（BridgeTransport）
### 目标
避免核心直接依赖具体 WebView 实现。

### SPI
- `bind(Listener listener)`
- `send(String messageJson)` 返回 boolean
- `close()`

### Android 适配器
- `AndroidWebViewBridgeTransport`：API ≥ M 走 `WebMessageChannel`（`createWebMessageChannel` + `bridge:init` 注入端口），低版本回退 `LegacyJavascriptChannel`。

### 价值
未来可替换为自定义容器、iOS/Flutter/HarmonyOS 同构实现（协议一致，代码不共享）。transport 不做策略判断，与 security 互不引用。

---

## 第 8 章：引入最小可信上下文
### 目标
只提供框架必须信任的信息，避免过度解析。

### 上下文模型
- `TrustedPageContext(origin, pageInstanceId)`

### 上下文提供者
- `PageContextProvider`（security 层 SPI，由 `JsBridge` 消费）
- Android 实现：`AndroidWebViewPageContextProvider`

### 原则
框架只给“可信事实”，策略由调用方决定。

---

## 第 9 章：握手、会话、能力
### 目标
从“谁都能调”升级为“可控调用”。本章正式引入 Tier 2 入口 `JsBridge`。

### 关键流程
1. JS 发 `bridge.handshake`
2. Native 颁发 `sessionId`（响应 payload 含 `sessionId/capabilities/sessionTtlMs/policyVersion/origin/accepted`）
3. 后续请求带 `sessionId`
4. 会话绑定 `capabilities` 与 TTL（默认 15 分钟）

### 关键组件
- `SessionService` / `DefaultSessionService`
- `CapabilitySessionStore` / `InMemoryCapabilitySessionStore`（过期会话查询时即时清理）

### 页面生命周期 API
- `resetForNewPage()`：轮换 `pageInstanceId`，旧 session 失效。
- `resetTransport()`：重建通道并 bind，形成入站闭环。
- `isReady()` / `addReadyListener` / `destroy()`。

### 验收
- Level 1/2 下未握手请求被拒绝；伪造或不属于当前页面的 sessionId 返回 `E_SESSION_INVALID`。
- 过期会话不可用。

---

## 第 10 章：策略引擎（渐进增强）
### 目标
协议固定基线策略链与求值顺序 + 支持调用方扩展。

### 基线策略（固定顺序，deny 短路）
1. `RequestShapePolicy`——永远激活（`E_INVALID_MESSAGE`）
2. `HandshakeGatePolicy`——Level 1 起启用（`E_POLICY_DENY`）
3. `AccessControlPolicy`——Level 2 启用（`E_ORIGIN_DENY` / `E_METHOD_NOT_ALLOWED` / `E_SESSION_INVALID` / `E_CAPABILITY_DENY`）
4. `extraPolicies`——宿主注入

### 三级配置
- `new SecurityConfig()` → Level 0（裸分发，无需握手）
- `withHandshakeGate()` → Level 1
- `SecurityConfig.secure()` → Level 2（必须显式配置 `allowedOrigins` 等；通配 `"*"` 直接抛异常）

### 验收
- 可新增一条业务策略并独立生效。

---

## 第 11 章：事件与生命周期扩展
### 目标
支持 Native 主动推送事件。

### 扩展
- `LifecycleExtension`（Tier 3，可选）
- 事件走保留方法 `runtime.state`，payload 固定 `{state, seq}`，seq 从 1 单调递增。
- 未 ready 时事件进入 FIFO 队列（默认上限 32），握手成功后按序补发。

### 验收
- 页面可收到 `created/started/resumed/paused/stopped/destroyed` 等宿主事件。

---

## 第 12 章：Activity Result 扩展与并发语义
### 目标
支持选图等系统能力，并解决回调错配。

### 设计要点
- `BridgeResultRegistry` 负责发起结果型操作（返回 `launchId`）。
- `DefaultBridgeResultRegistry`（ActivityResultLauncher）/ `CompatBridgeResultRegistry`（兼容 `onActivityResult`，兼做 `BridgeResultDispatcher`）。
- 明确 single-flight：同一 registry 实例同一时刻仅一个在途请求。

### 验收
- 并发发起第二个请求回调 busy token，业务侧稳定映射为 `E_BUSY`。

---

## 第 13 章：错误模型与可观测性
### 目标
让故障可定位、可统计、可治理。

### 建议
- 统一错误模型：`code/message/retryable/details`（`BridgeError` + `normalize`）
- 错误码基线收口 `BridgeApiContract`：`E_INVALID_MESSAGE` / `E_POLICY_DENY` / `E_ORIGIN_DENY` / `E_METHOD_NOT_ALLOWED` / `E_SESSION_INVALID` / `E_CAPABILITY_DENY` / `E_METHOD_NOT_FOUND` / `E_INTERNAL`（+结果型扩展的 `E_BUSY` / `E_CANCELED` / `E_RESULT_EMPTY` / `E_LAUNCH_FAILED`）
- 审计日志记录：rule/method/origin/pageId/session/code
- 发送失败可观测：`bridge_send_failed` 日志 + `getSendFailureCount()`

### 验收
- 任一拒绝路径都可从日志定位到策略规则与上下文。

---

## 第 14 章：分层测试策略
### 目标
避免只依赖端到端测试。

### 测试分层
- `core`：消息分发、握手流程、成功失败回包（`JsBridgeTest`）
- `security`：session TTL、policy allow/deny（`PolicyGroupsTest` / `InMemoryCapabilitySessionStoreTest`）
- `extensions`：registry single-flight（`SingleFlightPendingLaunchesTest`）
- 跨端一致性：`ConformanceCoreBaselineTest`（C01–C13, C17, C18, C28–C30）+ 共享 JS 用例 `bridge-client-conformance.cases.js`（C14–C16, C19–C27）

### 命令
```bash
cd js_bridge_android
./gradlew :js-bridge-core:test :js-bridge-example:assembleDebug
```

---

## 第 15 章：组装示例应用
### 目标
给出完整可运行接入基线。

### 参考步骤
1. 初始化 `JsBridge`（注入 transport/context/kernelConfig/securityConfig）。
2. 注册业务 handler（`getUser`、`pickImage` 等）。
3. `onPageFinished` 调用 `resetTransport()` + `resetForNewPage()`。
4. 页面销毁调用 `destroy()`。

### 验收
- 示例 app 能稳定演示请求、事件、结果型扩展。

---

## 第 16 章：从 0 到 1 的架构复盘
### 复盘清单
- 核心是否只做核心能力（协议、分发、会话、基线策略）？
- 业务策略是否通过扩展注入，而非写死在核心？
- 分层依赖是否单向（`JsBridge → CoreBridge → api`；`security → api`；`extensions → JsBridge | CoreBridge | api`）？
- API 字段是否保持兼容（协议字段只增不改不删）？
- 单测是否覆盖关键路径与错误语义？

### 你最终得到的能力
- 一套可以上线的 Android JsBridge 核心。
- 一套可迁移到 iOS/Flutter/HarmonyOS 的一致性架构蓝图（本仓库已在四端落地）。
- 一套能持续演进而不失控的扩展机制。

---

## 附录 A：实际目录结构
```text
js_bridge_android/js-bridge-core/src/main/java/io/github/xesam/android/bridge/
  api/            # BridgeMessage、BridgeError、BridgeApiContract、TrustedPageContext
  core/           # CoreBridge + handler 接口
    transport/    # BridgeTransport SPI
  security/       # context / policy / session（Tier 2 组件）
  JsBridge.java   # Tier 2 入口
  extensions/     # lifecycle / registry / system（Tier 3，可选）
js_bridge_android/js-bridge-example/
```

iOS / Flutter / HarmonyOS 端为同构分层（Swift Package / Dart package / HAR），目录语义一致。

## 附录 B：章节实践方式
每章都按同一流程执行：
1. 新增或修改 1~3 个类。
2. 补 1~2 个针对性测试。
3. 运行一次最小构建命令。
4. 在示例页面手动验证一个场景。

这能保证教程学习过程中，每一步都“可运行、可验证、可回滚”。
