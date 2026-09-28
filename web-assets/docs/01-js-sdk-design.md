# 01 JS SDK 设计

> 适用范围：`web-assets/`（jsbridge-sdk + demo）
> 协议依据：[docs/03-protocol.md](../../docs/03-protocol.md)（Protocol v1）

---

## 目录

1. [定位与目标](#1-定位与目标)
2. [工程结构](#2-工程结构)
3. [core 层：CoreBridgeClient 与 protocol](#3-core-层corebridgeclient-与-protocol)
4. [platform 层：传输适配](#4-platform-层传输适配)
5. [会话封装与扩展](#5-会话封装与扩展)
6. [构建与同步](#6-构建与同步)
7. [与项目文档的关系](#7-与项目文档的关系)

---

## 1 定位与目标

`web-assets/` 是 JsBridge2 的 **Web 侧独立工程**，维护 JS 客户端 SDK（`jsbridge-sdk`）与 demo 的唯一正本。四端 Native 仓库中的 WebAssets 均为构建产物的镜像，不纳入版本控制，由 `pnpm sync` 填充。

核心目标：

- **一份代码、四端运行**：同一份 `jsbridge-sdk.js` bundle 在 Android / iOS / Flutter / HarmonyOS 四端的 WebView 中行为完全一致，JS 业务代码不感知平台差异。
- **协议对齐**：消息信封、握手语义、错误码常量与根协议文档及四端 Native 实现严格对齐（`BridgeProtocol` 常量 ↔ Native `BridgeApiContract`）。
- **渐进增强**：会话门控（session gate）、ready、lifecycle 均为可选扩展；不装配扩展时 `CoreBridgeClient` 可裸用（无会话门控）。

### 纯异步消息模型（不支持同步调用）

与根协议一致（见 [docs/03-protocol.md §1 消息模型](../../docs/03-protocol.md)），SDK 是纯异步客户端：

- `callNativeApi(method, { success, fail })` 为**回调式**，返回 `void`，无同步返回值；**bridge 调用链不封装 Promise / async-await**（协议设计决策而非实现风格——iOS WKWebView 无同步通道，四端通道能力交集只有异步）。唯一的例外是装载器 `getBridge()` 本身返回 `Promise<BridgeReadyResult>`（`client` 为已握手的 `JsBridgeClient`，结构正本见 §5 与 [packages/sdk/README.md](../packages/sdk/README.md)）——它兜底的是"页面就绪"而非 bridge 调用。
- 结果以独立 `kind=response` 消息异步送达，按 `reqId` 匹配 pending 回调；配套的超时、settled 去重、迟到帧丢弃，均是异步回调模型的配套机制。
- 若需“同步感”，应使用异步编排：`createReadyExtension().bootstrapReady()` 完成握手后在 `onSuccess` 回调中发起后续调用，用回调链替代阻塞。

## 2 工程结构

pnpm monorepo：

```
web-assets/
├── packages/
│   ├── sdk/                     ← jsbridge-sdk（发布到 npm）
│   │   ├── src/
│   │   │   ├── core/            ← protocol.ts / core-bridge-client.ts
│   │   │   ├── platform/        ← native-transport.ts / web-entry.ts / loader.ts（装载器，v1 新增）
│   │   │   ├── extensions/      ← ready-ext.ts / lifecycle-ext.ts
│   │   │   ├── js-bridge-client.ts   ← 会话门控封装（createJsBridgeClient）
│   │   │   └── index.ts         ← 公共导出清单
│   │   └── dist/
│   │       ├── esm/             ← npm 消费者（ESM + .d.ts）
│   │       └── iife/jsbridge-sdk.js   ← WebView <script src> bundle
│   └── demo/                    ← jsbridge-demo（private，不发布）
│       └── src/                 ← index.html / entry.js / api/ / page/
└── scripts/
    └── deploy.mjs               ← 同步与校验（sync / check / clean）
```

分层职责：

| 层 | 文件 | 职责 |
|----|------|------|
| `core/` | `protocol.ts` | 协议常量（kind / 保留方法 / 错误码）与信封类型 |
| `core/` | `core-bridge-client.ts` | 请求/响应/事件的收发核心：pending 管理、超时、AbortSignal、事件分发 |
| `platform/` | `native-transport.ts` | 平台传输检测与适配：自动发现出站通道、注册入站入口、未就绪排队 |
| `platform/` | `web-entry.ts` | `registerWebEntry`：transport 入站回调装配到 client |
| `platform/` | `loader.ts`（v1 新增） | `getBridge` 装载器：SDK 注入、建 transport/client、完成握手，折叠单例 ready 信号 |
| 会话封装 | `js-bridge-client.ts` | `createJsBridgeClient`：sessionId 未建立时拦截非握手调用 |
| `extensions/` | `ready-ext.ts` / `lifecycle-ext.ts` | 握手 ready 流程、`runtime.state` 生命周期订阅 |

## 3 core 层：CoreBridgeClient 与 protocol

### 3.1 protocol.ts

`BridgeProtocol` 固化协议常量。与 Native 侧 `BridgeApiContract` 的对应关系按层归属（正本见 [docs/03-protocol.md §8 错误码分类表](../../docs/03-protocol.md)）：协议层错误码与方法/事件常量与 Native 契约一一对应；`E_CHANNEL_CLOSED` / `E_NOT_READY` 为 transport 层词汇（Native 契约亦有登记，但 `E_CHANNEL_CLOSED` 由 JS 客户端本地产生、不跨端传输）；`E_TIMEOUT` / `E_CANCELED` 为 JS 客户端本地码，不在 Native `BridgeApiContract` 中：

| 常量组 | 内容 |
|--------|------|
| kind | `KIND_REQUEST` / `KIND_RESPONSE` / `KIND_EVENT` |
| 保留方法 | `METHOD_HANDSHAKE`（`bridge.handshake`）/ `METHOD_LIFECYCLE_STATE`（`runtime.state`）/ `METHOD_CANCEL_SCOPE`（`bridge.cancelScope`） |
| 错误码 | `E_INVALID_MESSAGE` / `E_POLICY_DENY` / `E_ORIGIN_DENY` / `E_METHOD_NOT_ALLOWED` / `E_SESSION_INVALID` / `E_METHOD_NOT_FOUND` / `E_TIMEOUT` / `E_CANCELED` / `E_INTERNAL` |
| transport 层（v1 新增） | `ERR_CHANNEL_CLOSED`（`E_CHANNEL_CLOSED`）/ `ERR_NOT_READY`（`E_NOT_READY`）/ `CHANNEL_EVENT_TYPE`（`bridge:channel`）/ `REQUEST_CHANNEL_ENTRY`（`requestBridgeChannel`） |

### 3.2 请求生命周期

`callNativeApi(method, data)` 的处理流程：

1. **id 生成**：`${Date.now()}_${seq}_${random}`——seq 分量进程内单调递增，整体 id 保证唯一但不保证字典序单调（首个分量为毫秒时间戳）。
2. **默认超时**：`timeoutMs` 缺省 10000ms；`timeoutMs <= 0` 表示不超时（协议 v1 语义）；超时触发 `fail(E_TIMEOUT)`。
3. **payload 剥离**：`success` / `fail` / `timeoutMs` / `keep` / `signal` 从 payload 中剔除后作为请求信封发出。
4. **AbortSignal**：`signal.aborted` 时直接拒绝（`E_CANCELED`，不发送请求）；发出后 abort 则移除 pending、记 settled、回调 `E_CANCELED`。
5. **pending 登记**：`pendingMap[id]` 保存回调、超时句柄与 signal 引用。

### 3.3 settled 记录与迟到响应

请求完成/超时/取消后进入 `settledMap`（记录终止原因），用于幂等丢弃迟到帧：

- TTL 60 秒、容量上限 1000 条（超限先清理过期项）。
- TTL 内收到同 `reqId` 响应 → `late response dropped`；TTL 过期后 → `pending callback not found`。
- 该机制保证 `fail`/`success` 回调各至多触发一次（对应 conformance C14 / C15 / C21）。

### 3.4 响应与流式处理

`handleIncomingMessage` 的分发规则：

| 输入 | 处理 |
|------|------|
| `kind=response`（reqId 匹配 pending） | 按 `reqId` 匹配 pending；命中 settled 则丢弃；响应 sessionId 与请求 sessionId 不一致时**同步 fail-fast `E_SESSION_INVALID`**（跨会话串扰信号，静默丢弃会将其伪装成 E_TIMEOUT——见 docs/03 §4.3 / C63 ③） |
| `ok=true` | 触发 `success(payload)` |
| `ok=false` | 触发 `fail(error)`；error 缺失时归一化为 `E_INTERNAL`。流式中收到 `ok=false` 的帧即**终帧行为**：请求落定、流终结，后续同 reqId 帧按迟到帧丢弃（C63 ①） |
| `keep=true` 且 `done=false` | 流继续：重置超时计时，保留 pending |
| `done=true`（或非流场景） | 流结束：清理 pending、记 settled |
| `kind=event` | 见 §3.5 |
| 其余 kind | 完全无法关联（reqId 不匹配任何请求/记录）则忽略；reqId 可关联到挂起请求的未知 kind 消息**同步快速失败 `E_INTERNAL`**，不得伪装成超时（C50） |

### 3.5 事件分发

- 按 `method` 分发到 `eventHandlers` 中注册的 handler（每 method 一个 handler，后注册覆盖先注册）。
- **sessionId 严格匹配 + 空串兼容**：client 已有 sessionId 且事件携带非空 sessionId 时，两者不一致则忽略；事件 sessionId 为空串时无条件派发（对应 conformance C16 / C22）。
- `registerEventHandler(method, handler, signal?)` 支持 AbortSignal 注销（C26）。

## 4 platform 层：传输适配

### 4.1 出站通道检测与信道建立（native-transport.ts）

**信道建立为 pull 模型（[docs/06-channel-establishment.md](../../docs/06-channel-establishment.md)）**：`createNativeTransport()` 构造即挂 `message` 监听，随后经 `__jsbridge2__.requestBridgeChannel({reqId})` 哑入口拉取信道——因果链为「挂监听 →causes→ 发请求 →causes→ Native 投递」，投递以 `bridge:channel` 信封 `{"type":"bridge:channel","reqId":...}` + port 到达，仅 reqId 匹配当前最新请求才采纳（陈旧/重复投递关端口丢弃）。要点：

- 双实例守卫：第二次 `createNativeTransport()` warn 并复用既有实例（消双实例踩踏）；
- reqId 重试：T 内无匹配投递则换新 reqId 重试，耗尽后经 `onChannelError` 以 `E_CHANNEL_CLOSED` fail 全部 pending；
- Bfcache 自愈：监听 `pageshow`（`persisted`）→ 失效旧端口、新 reqId 重建；
- 常驻通道平台（iOS / Flutter / HarmonyOS）由 JS 侧同步探测豁免拉取（[docs/04-cross-platform.md §3.1](../../docs/04-cross-platform.md)）；
- 入口必须以方法调用形式在注入对象上调用（`obj.method()`），解构引用会触发 Android 包装层 this 绑定校验异常（真机实锤，[docs/04-cross-platform.md §3.1](../../docs/04-cross-platform.md)）。

出站通道按以下优先级解析：

| 优先级 | 通道 | 对应平台 |
|--------|------|---------|
| 1 | `MessagePort`（由 `bridge:channel` 信封投递、reqId 配对采纳后持有） | Android `WebMessageChannel`（现代通道） |
| 2 | `window.NativeBridge.postMessage(json)` | Flutter `JavaScriptChannel` / HarmonyOS `javaScriptProxy` |
| 3 | `window.webkit.messageHandlers.NativeBridge.postMessage(json)` | iOS `WKScriptMessageHandler` |

- **不使用** `__jsbridge2__.callNativeApi` 作为 fallback sender：Android WebMessageChannel 握手完成前该入口不可用，消息应排队等待 `bridge:channel` 投递。
- **未就绪排队**：通道未就绪时消息进入队列，经一次 50ms 延时 flush 冲刷——冲刷时无可用 sender 即终止、不续期轮询（免得死等变泄漏）；端口采纳与 `onMessage` 注册监听器时也会触发冲刷。legacy-only 宿主（仅 `__jsbridge2__.callNativeApi`、无端口也无常驻通道）不入队，`send()` 同步以 `E_CHANNEL_CLOSED` 快速失败。

### 4.2 入站通道

Native → JS 统一调用：

```js
window.__jsbridge2__ && window.__jsbridge2__.receive && window.__jsbridge2__.receive(json)
```

`createNativeTransport()` 创建 `window.__jsbridge2__.receive` 并把消息广播给监听器；Android 现代通道的消息则经 `port.onmessage` 进入同一广播入口。

### 4.3 四端对接契约

| 平台 | JS → Native | Native → JS | 说明 |
|------|-------------|-------------|------|
| Android | `MessagePort.postMessage`（`bridge:channel` 信封 reqId 配对采纳 port） | `window.__jsbridge2__.receive(json)`（`WebMessagePort` / `evaluateJavascript`） | `addJavascriptInterface` 注入的 `LegacyJavascriptChannel` 仅是建链哑入口宿主的装载底座：SDK 的 sender 解析**不使用** `__jsbridge2__.callNativeApi`——API < M 且未建成 MessagePort 的 legacy-only 宿主，一律同步快速失败 `E_CHANNEL_CLOSED`（00472be 裁决，conformance 断言恰一次） |
| iOS | `window.webkit.messageHandlers.NativeBridge.postMessage(json)` | 同上（`evaluateJavaScript`） | bootstrap script 由 `WKWebViewBridgeTransport` 注入 |
| Flutter | `window.NativeBridge.postMessage(json)`（`addJavaScriptChannel('NativeBridge')`） | 同上（`runJavaScript`） | transport 为宿主注入函数 |
| HarmonyOS | `window.NativeBridge.postMessage(json)`（`javaScriptProxy`） | 同上（`runJavaScript`） | transport 为宿主注入函数 |

`registerWebEntry(client, transport)`：将 transport 的入站监听绑定到 `client.handleIncomingMessage`，完成最小装配。

## 5 会话封装与扩展

| 模块 | API | 职责 |
|------|-----|------|
| 会话门控 | `createJsBridgeClient(client, { readyMethod })` | sessionId 为空时拦截非 `readyMethod` 调用（本地 fail `E_NOT_READY`，与 Native 握手门控拒绝码对齐，不发请求）；提供 `getSessionId` / `setSessionId` |
| 装载器（v1 新增） | `getBridge({ sdkUrl?, loadTimeoutMs?, handshakeTimeoutMs?, channelTimeoutMs?, maxChannelRetries?, retryBackoffMs? })` → `Promise<BridgeReadyResult>` | 全 app 唯一 ready 信号：单例 Promise，把"文件/通道/会话"三层就绪折叠为一个"握完手的 client"；各层超时分别参数化，落定后清缓存可重试 |
| ready 扩展 | `createReadyExtension(jsBridgeClient, { readyMethod })` → `bootstrapReady({ onSuccess, onFail }, { timeoutMs? })` | 发起 `bridge.handshake`，成功后自动写入 sessionId，再执行业务回调；v1 起可透传 `timeoutMs` 覆盖默认 10s |
| lifecycle 扩展 | `createLifecycleBridge(client, { lifecycleMethod })` → `on` / `off` / `getState` | 订阅 `runtime.state`，内置 **seq 乱序过滤**（`seq <= lastSeq` 丢弃，对应 conformance C19） |

分层关系：`CoreBridgeClient`（裸协议客户端）→ `createJsBridgeClient`（会话门控）→ `createReadyExtension`（握手流程）；lifecycle 扩展直接基于 `CoreBridgeClient` 的事件分发，与会话无耦合。

## 6 构建与同步

### 6.1 构建产物

| 产物 | 路径 | 用途 |
|------|------|------|
| ESM + `.d.ts` | `packages/sdk/dist/esm/` | npm 消费者（`import`） |
| IIFE | `packages/sdk/dist/iife/jsbridge-sdk.js` | WebView `<script src>`，暴露全局 `window.JsBridgeSDK` |

IIFE 与 demo 的 JS 经 Babel 转译至 ES5（target IE 11），`vconsole.min.js` 为已压缩的第三方产物，跳过转译。

**转译只降语法、不补 polyfill（刻意设计，产物不携带 core-js）**。IIFE 产物的运行时依赖（`Promise` 32+ / `WeakMap`·`WeakSet` 36+ / `Map`·`Symbol` 38+ / `MessagePort` 41+，`AbortSignal` 66+ 为可选能力），无 polyfill 底线为 **Chromium 41+**；低于此需宿主在 SDK 之前自行加载 core-js。完整矩阵与加载示例（含 ESM 产物的语法目标与直接运行门槛）见 [packages/sdk/README.md「运行时依赖与 polyfill」](../packages/sdk/README.md)。ESM 产物不设构建 target、保留现代语法，由消费者构建链按自身 targets 降级。

### 6.2 同步与校验（scripts/deploy.mjs）

- `pnpm sync`：构建 sdk + demo → 将 `packages/demo/dist/` 复制到四端资产目录 → 执行校验。
- `pnpm check`：对 `packages/demo/dist/` **全部共享文件**（动态全量收集）做 SHA-256 四端互比；联动 conformance cases 四端互比、「产物 ⊆ 源」无残留校验与发布覆盖校验。完整语义正本见 [web-assets/README.md](../README.md) 与 `scripts/deploy.mjs` 的 `check()`。
- `pnpm clean:native`：清除四端资产目录。

四端资产目录（由 deploy.mjs 的 `PLATFORM_ROOTS` 维护）：Android `…/assets/web/`、iOS `…/WebAssets/`、Flutter `…/assets/web/`、HarmonyOS `…/rawfile/web/`。

**规则：`packages/` 下任何内容变更后必须立即 `pnpm sync`。**

## 7 与项目文档的关系

| 主题 | 文档 |
|------|------|
| 协议语义（信封 / 握手 / 错误码 / 策略链） | `docs/03-protocol.md` |
| JS 层与 Native 层的架构关系、WebAssets 分层 | `docs/02-architecture.md` §7 |
| JS 客户端验收用例（C14–C16, C19–C27, C31, C32, C39, C40, C41, C50, C57, C63） | `docs/09-conformance.md` |
| 生命周期三层模型中 Scope 层（AbortSignal） | `docs/05-lifecycle-layers.md` |
| SDK 使用方式与 API 参考 | [packages/sdk/README.md](../packages/sdk/README.md) |
