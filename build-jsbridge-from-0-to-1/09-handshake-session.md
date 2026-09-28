# 第 9 章：握手与会话

## 目标
把 Bridge 从"能通信"升级到"可控通信"。从本章起，正式引入 Tier 2 入口类 `JsBridge`——叠加在 `CoreBridge` 之上，拦截 transport 入口，插入策略链，策略通过后委托 core 分发。

握手建立"当前页面实例 + 会话"的最小信任关系：没有握手，任何页面消息都可能被当成合法请求处理。

> 渐进增强原则：握手在本仓库是**可选能力**而非强制前置。宿主通过传入 `SecurityConfig` 选择启用（第 10 章）；`securityConfig` 传 `null` 时 `resetPageInstance()` 后立即可用，无需握手。

## 标准流程
保留方法名为 `bridge.handshake`（定义在 `BridgeApiContract.METHOD_HANDSHAKE`）：
1. JS 发送 `method="bridge.handshake"` 的 request（`sessionId` 可为空）。
2. Native 校验来源并创建会话。
3. Native 返回会话信息：payload 固定为 `{sessionId, sessionTtlMs, policyVersion, origin, accepted}`。
4. 后续 request 必须携带 `sessionId`。

同一页面重复握手应刷新会话，而非报错。

## 会话对象
`SessionRecord` 包含：
- `sessionId`
- `origin`
- `pageInstanceId`
- `expiresAtMs`

## 关键组件
- `SessionService`：接口，提供 `find / issueHandshake / clearByPageInstance / clearAll`。
- `DefaultSessionService`：默认实现，负责签发握手响应 payload。
- `SessionStore`：会话存储接口。
- `InMemorySessionStore`：内存实现（首版足够）。

## JsBridge 的页面生命周期 API
- `resetPageInstance()`：轮换 `pageInstanceId`（UUID），并把 `ready` 重置为"是否传入 SecurityConfig"的初值；同时 `clearByPageInstance` 使旧页面 session 立即失效。宿主在 WebView 页面加载回调（如 `onPageFinished`）中调用。
- `resetTransport()`：重新 `bind()` transport，建立"transport 收包 → JsBridge 策略 → core 分发 → transport 回包"的入站闭环（Android 端写法；iOS/Flutter/HarmonyOS 为等价的 `bindTransport()`）；v1 pull 模型下其职责语义为 **invalidate/轮换**（关闭旧通道、轮换绑定周期，新通道由页面 `requestBridgeChannel` 拉取重建，docs/03 §3.1）。
- `isReady()`：传入 `SecurityConfig` 时握手完成前为 `false`；`securityConfig == null` 下 `resetPageInstance()` 后即为 `true`。
- `addReadyListener(ReadyListener)`：握手成功后回调（`LifecycleExtension` 用它做事件补发，第 11 章）。
- `destroy()`：`clearAll` 清空会话并关闭 transport。

## 实现要点
- 查询到过期会话时应立即清理（`InMemorySessionStore.find` 命中过期即 remove）。
- 会话必须绑定 `pageInstanceId`——session 与请求的 origin / pageInstanceId 不匹配时拒绝（第 10 章 `SessionPolicy`）。
- SPA 路由跳转（`pushState`/`hashchange`）不触发 `resetPageInstance`，session 自然延续（详见 `docs/05-lifecycle-layers.md`）。

## 验收清单
1. 传入 `SecurityConfig` 时未握手请求被拒绝（`E_NOT_READY`，v1 起从 `E_POLICY_DENY` 分立——"策略拒绝"与"未握手"不再混码）。
2. 伪造或不属于当前页面的 sessionId 返回 `E_SESSION_INVALID`。
3. `resetPageInstance()` 后旧 session 自动失效。
4. 握手响应 payload 字段与协议文档一致。

## 常见坑
1. 会话不绑定 `pageInstanceId`，跨页面串用。
2. 忘记 TTL，session 永不过期（默认 `sessionTtlMs` 为 15 分钟）。
3. 把 `resetPageInstance` 用在 SPA 路由跳转上，导致会话被误杀。
