# js-bridge Architecture

## 三层叠加模型

核心部分遵循三层逐层叠加，每层可独立使用：

```
Tier 3: extensions (lifecycle / registry / system)     ← 可选
         ↓ 依赖
Tier 2: JsBridge (session / policy / handshake)
         ↓ 依赖
Tier 1: CoreBridge (dispatch / transport / response)    ← 可独立使用
```

### Tier 1: CoreBridge — 核心协议层

- Files: `core/CoreBridge`, `core/message/*`, `core/transport/*`
- Responsibility: transport 绑定、消息解析、handler 分发、响应发送、事件推送。
- Dependency: `api` + `core.message` + `core.transport`。**零 security 依赖。**
- 独立使用：`new CoreBridge(transport)` + `core.bind()` + `core.registerHandler()`

### Tier 2: JsBridge — 会话/策略/握手层

- Files: `JsBridge`（根包）
- Responsibility: 策略链求值、session 管理、握手处理、context-aware handler 分发。
- Dependency: `CoreBridge`（Tier 1）+ `security` + `api`。
- 叠加方式：内部创建 `CoreBridge`，拦截 transport 入口，策略通过后委托 `CoreBridge.dispatch()`。

### Tier 3: extensions — 可选适配层

- Files: `extensions/lifecycle/*`, `extensions/registry/*`, `extensions/system/*`
- Responsibility: 生命周期事件、Activity Result 兼容、WebView 适配器。
- Dependency: `JsBridge` + `core` + `security` + `api`。可选，不引入不影响内核。

## api 层（共享契约）

- Files: `api/contract/BridgeApiContract`, `api/model/BridgeError`, `api/model/BridgeMessage`, `api/model/TrustedPageContext`
- Responsibility: 跨层共享的协议常量、消息信封、错误模型、页面上下文数据。
- `TrustedPageContext` 是纯数据模型（origin + pageInstanceId），由 `api.model` 提供，`core` 和 `security` 共同使用。
- Rule: 不依赖任何内部层。

## transport 层

- Files: `core/transport/BridgeTransport`
- Responsibility: 消息 I/O 抽象。
- Rule: 无策略或会话决策。

## security 层

- Files: `security/context/PageContextProvider`, `security/policy/*`, `security/session/*`
- Responsibility: 上下文派生、策略求值、session/capability 校验。
- Rule: 纯决策/状态逻辑，不依赖 `core` 或 `transport`。

## Dependency Rules

- Allowed: `CoreBridge -> api|core.message|core.transport`
- Allowed: `JsBridge -> CoreBridge|security|api`
- Allowed: `extensions -> JsBridge|core|security|api`
- Allowed: `security -> api`
- Forbidden: `transport -> core|security|extensions`
- Forbidden: `security -> core|transport|extensions`
- Forbidden: `api -> any internal layer`
- Forbidden: `CoreBridge -> security`（Tier 1 不依赖 Tier 2）

## Host Integration Boundary

- `JsBridge` 构造时内部创建 `CoreBridge`
- `JsBridge` 依赖抽象：
  - `core.transport.BridgeTransport`
  - `security.context.PageContextProvider`（返回 `api.model.TrustedPageContext`）
- Android WebView 支持由 `extensions/system` 适配器提供：
  - `AndroidWebViewBridgeTransport`
  - `AndroidWebViewPageContextProvider`
  - `AndroidWebViewTrustedContextFactory`

## Dispatch Flow

```
Transport 消息 → JsBridge.onIncomingMessage()
  parse → createContext → findSession → evaluatePolicy
  if denied → core.respondFail()
  if handshake → handleHandshake()
  if cancelScope → handleCancelScope()
  if contextHandler → handler.handle(ctx, payload, callback) → core.respond*
  else → core.dispatch(msg)  ← 委托 Tier 1
           → simpleHandler.handle(payload, callback) → core.respond*
```

## Package Map

- `io.github.xesam.android.bridge` -> `JsBridge`（Tier 2 入口，根包）
- `...bridge.api.contract|api.model` -> `api`（含 `TrustedPageContext`）
- `...bridge.core` -> `core`（`CoreBridge` Tier 1）
- `...bridge.core.message` -> handler 接口（`SimpleNativeMessageHandler`, `NativeMessageHandler`, `MessageHandlerCallback`）
- `...bridge.core.transport` -> `transport` 抽象（`BridgeTransport`）
- `...bridge.security.context|security.policy|security.session` -> `security`
- `...bridge.extensions.*` -> `extensions`

## References
- Extension contracts and error semantics: `EXTENSION_GUIDE.md`
