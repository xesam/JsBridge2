# 第 9 章：握手、会话与能力

## 本章目标
把 Bridge 从“能通信”升级到“可控通信”。从本章起，正式引入 Tier 2 入口类 `JsBridge`——叠加在 `CoreBridge` 之上，拦截 transport 入口，插入策略链，策略通过后委托 core 分发。

## 为什么要握手
如果没有握手，任何页面消息都可能被当成合法请求处理。握手的作用是建立“当前页面实例 + 会话能力”的最小信任关系。

> 渐进增强原则：握手在本仓库是**可选能力**而非强制前置。宿主通过 `SecurityConfig.withHandshakeGate()` 选择启用（第 10 章 Level 1/2）；默认 Level 0 下 `resetForNewPage()` 后立即可用，无需握手。

## 标准流程
保留方法名为 `bridge.handshake`（定义在 `BridgeApiContract.METHOD_HANDSHAKE`）：
1. JS 发送 `method="bridge.handshake"` 的 request（`sessionId` 可为空）。
2. Native 校验来源并创建会话。
3. Native 返回 `sessionId` 与能力信息：payload 固定为 `{sessionId, capabilities, sessionTtlMs, policyVersion, origin, accepted}`。
4. 后续 request 必须携带 `sessionId`。

同一页面重复握手应刷新会话，而非报错。

## 会话对象
`SessionRecord` 包含：
- `sessionId`
- `origin`
- `pageInstanceId`
- `capabilities`
- `expiresAtMs`

## 关键组件
- `SessionService`：接口，提供 `find / issueHandshake / clearByPageInstance / clearAll`。
- `DefaultSessionService`：默认实现，负责签发握手响应 payload。
- `CapabilitySessionStore`：会话存储接口。
- `InMemoryCapabilitySessionStore`：内存实现（首版足够）。

## JsBridge 的页面生命周期 API
- `resetForNewPage()`：轮换 `pageInstanceId`（UUID），并把 `ready` 重置为“是否要求握手”的初值；同时 `clearByPageInstance` 使旧页面 session 立即失效。宿主在 WebView 页面加载回调（如 `onPageFinished`）中调用。
- `resetTransport()`：重新 `bind()` transport，建立“transport 收包 → JsBridge 策略 → core 分发 → transport 回包”的入站闭环（Android 端写法；iOS/Flutter/HarmonyOS 为等价的 `bindTransport()`）。
- `isReady()`：Level 1/2 下握手完成前为 `false`；Level 0 下 `resetForNewPage()` 后即为 `true`。
- `addReadyListener(ReadyListener)`：握手成功后回调（`LifecycleExtension` 用它做事件补发，第 11 章）。
- `destroy()`：`clearAll` 清空会话并关闭 transport。

## 实现要点
- 查询到过期会话时应立即清理（`InMemoryCapabilitySessionStore.find` 命中过期即 remove）。
- 会话必须绑定 `pageInstanceId`——session 与请求的 origin / pageInstanceId 不匹配时拒绝（第 10 章 AccessControlPolicy）。
- SPA 路由跳转（`pushState`/`hashchange`）不触发 `resetForNewPage`，session 自然延续（详见 `docs/06-lifecycle-layers.md`）。

## 验收清单
1. Level 1/2 下未握手请求被拒绝（`E_POLICY_DENY`）。
2. 伪造或不属于当前页面的 sessionId 返回 `E_SESSION_INVALID`。
3. `resetForNewPage()` 后旧 session 自动失效。
4. 握手响应 payload 字段与协议文档一致。

## 常见坑
1. 会话不绑定 `pageInstanceId`，跨页面串用。
2. 忘记 TTL，session 永不过期（默认 `sessionTtlMs` 为 15 分钟）。
3. 握手后不返回能力集合，前端无法判断可用方法。
4. 把 `resetForNewPage` 用在 SPA 路由跳转上，导致会话被误杀。

## 小结
握手与会话解决了“身份与边界”问题。第 10 章我们把策略判定系统化。
