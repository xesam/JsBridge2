# jsbridge-sdk

JsBridge2 的 JS 客户端 SDK。为运行在 WebView 中的 JS 页面提供与宿主 Native 应用通信的能力，支持 Android、iOS、Flutter、HarmonyOS 四个平台。

## 安装

> 当前包尚未发布到 npm，以下为发布后的消费方式；发布前请使用下文 IIFE bundle 方式。

```bash
npm install jsbridge-sdk
# 或
pnpm add jsbridge-sdk
```

## 构建产物与兼容性

包内发布**两份**产物，面向两类接入场景，语法目标不同——这是刻意设计，不是缺失：

| 产物 | 路径 | 适用场景 | 语法目标 |
|------|------|---------|---------|
| ESM | `dist/esm/index.js` + `index.d.ts` | 现代打包器消费者（`import`） | 保留现代语法（不设构建 target，含 `?.` / `??` 与类私有字段，直接运行约需 Chromium 84+），由消费者的构建链按自身 targets 降级 |
| IIFE | `dist/iife/jsbridge-sdk.js` | 直接 `<script src>` 加载；旧版 WebView 的直接引用场景 | 语法转译至 **ES5**（target IE 11）；**运行时底线 Chromium 41+**，低于此需宿主自备 polyfill（见下节） |

**为什么 ESM 不做 ES5 降级**：ESM 的消费者必然经过打包器，由打包器按其目标环境统一降级更合理；对 ESM 预降级会破坏现代工具链的优化空间。**旧版 WebView 的直接引用场景一律走 IIFE 产物**（它才是 `<script src>` 加载的那份，也是唯一被降级到 ES5 的产物）。`vconsole.min.js` 不属本包产物。

IIFE 产物有三种获取方式：

```html
<!-- 1. 四端宿主仓库内：由 pnpm sync 同步到 WebView 资源目录（当前推荐） -->
<script src="./jsbridge-sdk.js"></script>

<!-- 2. npm 消费者：从包内路径复制到 WebView 资源目录 -->
<!--    node_modules/jsbridge-sdk/dist/iife/jsbridge-sdk.js -->

<!-- 3. CDN 直引（发布后生效；package.json 已声明 unpkg / jsdelivr 字段） -->
<script src="https://unpkg.com/jsbridge-sdk/dist/iife/jsbridge-sdk.js"></script>
<script src="https://cdn.jsdelivr.net/npm/jsbridge-sdk/dist/iife/jsbridge-sdk.js"></script>
```

### 运行时依赖与 polyfill（读我）

**Babel 只降语法、不补 polyfill，且这是刻意设计**：产物不携带任何 core-js 代码——自带 polyfill 会与宿主页面自身的 polyfill 冲突，也徒增体积。「兼容旧版 WebView」的准确含义是**语法**上已转译至 ES5，**运行时 API** 仍要求宿主环境具备下列能力。真实底线如下：

| 运行时依赖 | 最低 Chromium | 缺失后果 |
|-----------|--------------|---------|
| `Promise` | 32+ | 模块初始化即抛错，SDK 不可用（`getBridge` 装载器依赖） |
| `WeakMap` / `WeakSet` | 36+ | 同上（私有字段转译产物依赖） |
| `Map` / `Symbol` | 38+ | 同上（pending 表与协议标记依赖） |
| `MessagePort`（Android pull 信道） | 41+ | **IIFE 产物实际底线**——低于 41 时信道建不起来，SDK 重试耗尽后以 `E_CHANNEL_CLOSED` 失败（可自愈的降级） |
| `AbortSignal`（可选能力） | 66+ | 仅影响取消请求 / 注销监听两个特性，缺失时其余功能不受影响 |

**结论：IIFE 产物的无 polyfill 底线为 Chromium 41+**（Android 5.0+ 出厂 / 近年的系统 WebView 均满足；无 Play 更新渠道的旧低端机系统 WebView 可能低于此值；iOS WKWebView 不受影响——不存在低于此底线的版本）。**IE 11 上 SDK 不开箱可用**——target IE 11 只约束 Babel 的语法输出，不保证运行时。（历史备注：早期版本的 `failAllPending` 曾依赖 `Array.from` 把底线拉高到 Chromium 45+，已改用 `Map.forEach` 普通遍历消除该依赖。）

**何时需要宿主自备 polyfill**：目标 WebView 的 Chromium 内核低于 41（典型：Android 4.4 / 5.0 无更新系统 WebView，或需覆盖 IE 11）时，**在 `jsbridge-sdk.js` 之前**加载 core-js：

```html
<!-- 整包引入 es（推荐，省心）： -->
<script src="https://unpkg.com/core-js@3/minified.min.js"></script>

<!-- 或按需引入（最小集对应上表前三行）： -->
<script src="https://unpkg.com/core-js@3/features/promise/index.min.js"></script>
<script src="https://unpkg.com/core-js@3/features/map/index.min.js"></script>
<script src="https://unpkg.com/core-js@3/features/weak-map/index.min.js"></script>
<script src="https://unpkg.com/core-js@3/features/weak-set/index.min.js"></script>
<script src="https://unpkg.com/core-js@3/features/symbol/index.min.js"></script>

<!-- core-js 必须先于 SDK 加载 -->
<script src="./jsbridge-sdk.js"></script>
```

npm / ESM 场景由消费者的构建链自行处理（如 `@babel/preset-env` 配 `useBuiltIns: 'usage'` + `core-js@3`，或打包器 targets 覆盖），SDK 不做任何假设。

## 使用

### IIFE（直接通过 script 标签加载，当前推荐）

构建产物为 `dist/iife/jsbridge-sdk.js`（Babel 转译至 ES5 **语法**；运行时底线与 polyfill 需求见上文「运行时依赖与 polyfill」），复制到 WebView 资源目录后加载，暴露全局 `window.JsBridgeSDK`。该产物同样随 npm 包发布（`dist/iife/` 在白名单内），获取方式见上文「构建产物与兼容性」。

```html
<script src="./jsbridge-sdk.js"></script>
<script>
  const {
    BridgeProtocol,
    CoreBridgeClient,
    createNativeTransport,
    registerWebEntry,
    createJsBridgeClient,
    createReadyExtension,
    createLifecycleBridge,
  } = window.JsBridgeSDK

  // 1. 创建 transport + client，绑定消息接收
  const transport = createNativeTransport()
  const client = new CoreBridgeClient(transport)
  registerWebEntry(client, transport)

  // 2. 会话封装：sessionId 未建立前拦截非握手调用
  const jsBridgeClient = createJsBridgeClient(client, {
    readyMethod: BridgeProtocol.METHOD_HANDSHAKE,
  })

  // 3. 订阅生命周期事件（可选）
  const lifecycle = createLifecycleBridge(client, {
    lifecycleMethod: BridgeProtocol.METHOD_LIFECYCLE_STATE,
  })
  lifecycle.on((payload) => console.log('state:', payload.state, 'seq:', payload.seq))

  // ⚠️ 时序提示：lifecycle handler 必须在读取握手结果**之前**注册。
  // Native 侧对「握手后才注册 handler」的页面无补偿机制——补发事件可能在
  // 注册前到达而丢失（runtime.state 未 ready 时排队、握手后按序补发，但补发
  // 不等注册）。正确顺序：构造 client → 立即注册 lifecycle → 再 bootstrapReady。

  // 4. 握手成功后调用 Native 方法
  const ready = createReadyExtension(jsBridgeClient, {
    readyMethod: BridgeProtocol.METHOD_HANDSHAKE,
  })
  ready.bootstrapReady({
    onSuccess(res) {
      console.log('bridge ready, session:', jsBridgeClient.getSessionId())
      jsBridgeClient.callNativeApi('getUser', {
        userId: '001',
        success(user) { console.log('user:', user) },
        fail(err)    { console.error(err) },
      })
    },
    onFail(err) {
      console.error('handshake failed', err)
    },
  })
</script>
```

### ESM（现代构建工具，发布后可用）

```js
import {
  BridgeProtocol,
  CoreBridgeClient,
  createNativeTransport,
  registerWebEntry,
  createJsBridgeClient,
  createReadyExtension,
} from 'jsbridge-sdk'

const transport = createNativeTransport()
const client = new CoreBridgeClient(transport)
registerWebEntry(client, transport)

const jsBridgeClient = createJsBridgeClient(client, {
  readyMethod: BridgeProtocol.METHOD_HANDSHAKE,
})

createReadyExtension(jsBridgeClient, {
  readyMethod: BridgeProtocol.METHOD_HANDSHAKE,
}).bootstrapReady({
  onSuccess(res) {
    jsBridgeClient.callNativeApi('getUser', {
      userId: '001',
      success(user) { console.log(user) },
      fail(err)  { console.error(err) },
    })
  },
  onFail(err) { console.error('handshake failed', err) },
})
```

## API

> **消息模型为纯异步**：所有调用均为回调式（`success` / `fail`），返回 `void`，无同步返回值，也不封装 Promise——这是协议设计决策（iOS 无同步通道，四端通道交集只有异步），详见 [docs/03-protocol.md §1 消息模型](../../../docs/03-protocol.md)。

### `BridgeProtocol`

协议常量（与 Native 侧 `BridgeApiContract` 对齐）：

| 常量 | 值 |
|------|----|
| `KIND_REQUEST` | `'request'` |
| `KIND_RESPONSE` | `'response'` |
| `KIND_EVENT` | `'event'` |
| `METHOD_HANDSHAKE` | `'bridge.handshake'` |
| `METHOD_LIFECYCLE_STATE` | `'runtime.state'` |
| `METHOD_CANCEL_SCOPE` | `'bridge.cancelScope'` |
| `ERR_INVALID_MESSAGE` | `'E_INVALID_MESSAGE'` |
| `ERR_POLICY_DENY` | `'E_POLICY_DENY'` |
| `ERR_ORIGIN_DENY` | `'E_ORIGIN_DENY'` |
| `ERR_METHOD_NOT_ALLOWED` | `'E_METHOD_NOT_ALLOWED'` |
| `ERR_SESSION_INVALID` | `'E_SESSION_INVALID'` |
| `ERR_METHOD_NOT_FOUND` | `'E_METHOD_NOT_FOUND'` |
| `ERR_TIMEOUT` | `'E_TIMEOUT'`（客户端本地码，不跨端） |
| `ERR_CANCELED` | `'E_CANCELED'`（客户端本地码，不跨端） |
| `ERR_INTERNAL` | `'E_INTERNAL'` |
| `ERR_CHANNEL_CLOSED` | `'E_CHANNEL_CLOSED'`（transport 层，v1 新增） |
| `ERR_NOT_READY` | `'E_NOT_READY'`（transport 层，v1 新增） |
| `CHANNEL_EVENT_TYPE` | `'bridge:channel'`（transport 层，v1 新增） |
| `REQUEST_CHANNEL_ENTRY` | `'requestBridgeChannel'`（transport 层，v1 新增） |

> **关于 `METHOD_CANCEL_SCOPE`（`bridge.cancelScope`）**：当前为协议预留方法——Native 侧返回空壳 ack，JS 客户端不主动发送它。AbortSignal 取消（`CallOptions.signal`）是纯客户端本地行为：JS 侧直接清理回调注册并按 `E_CANCELED` 落定，不产生跨端消息。

### `CoreBridgeClient`

裸协议客户端：请求/响应/事件收发、超时管理、AbortSignal 取消。

```ts
new CoreBridgeClient(transport: Transport, sessionId?: string)

client.setSessionId(sessionId: string): void
client.getSessionId(): string
client.registerEventHandler(method: string, handler: (payload: unknown) => void, signal?: AbortSignal): void
client.callNativeApi(method: string, data?: CallOptions, overrideSessionId?: string): void
client.handleIncomingMessage(messageJsonString: string): void
```

`overrideSessionId`（可选第三参）：显式指定请求帧的 sessionId（覆盖已绑定值）；会话门控语义见下方 `createJsBridgeClient`。

`CallOptions`：

```ts
{
  success?: (payload: unknown) => void
  fail?: (error: BridgeError) => void
  timeoutMs?: number   // 缺省 10000ms；0 或负数表示不超时（协议 v1：0 = 不超时）
  keep?: boolean       // 流式响应，默认 false
  signal?: AbortSignal // 取消请求 / 注销监听
  [key: string]: unknown
}
```

### `createNativeTransport()`

自动检测运行平台（Android `WebMessagePort` / `NativeBridge` JS channel / iOS `webkit.messageHandlers`）并返回对应的 transport 实现。

接受可选 `ChannelOptions` 调整建链行为（手动编排 + 自定义建链窗口时使用；缺省值见下）：

```ts
interface ChannelOptions {
    channelTimeoutMs?: number  // 单次 pull 后等待投递的窗口，超时换新 reqId 重试；默认 2000
    maxChannelRetries?: number // reqId 重试上限，耗尽后 E_CHANNEL_CLOSED；默认 3
    retryBackoffMs?: number    // 重试退避基数，线性退避；默认 500
}

const transport: NativeTransport = createNativeTransport({ channelTimeoutMs: 4000, maxChannelRetries: 1 })
```

**信道建立为 pull 模型（v1）**：构造即挂监听并经 `__jsbridge2__.requestBridgeChannel({reqId})` 哑入口拉取信道，端口以 `bridge:channel` 信封（reqId 配对）投递；reqId 超时重试、耗尽后经 `onChannelError` 以 `E_CHANNEL_CLOSED` fail 全部 pending；内置双实例守卫（重复创建 warn 并复用）与 Bfcache 自愈（`pageshow(persisted)` 后自动重建信道）。常驻通道平台（iOS `WKScriptMessageHandler` / Flutter / HarmonyOS）构造期经 `isResidentChannel()` 同步探测即豁免拉取、直接使用常驻通道——仅 Android 走 `bridge:channel` 拉取路径（[docs/06-channel-establishment.md §2.1](../../../docs/06-channel-establishment.md)）。详见 [docs/06-channel-establishment.md](../../../docs/06-channel-establishment.md)。

```ts
const transport: NativeTransport = createNativeTransport()
// transport.send(messageJson)
// transport.onMessage(listener)                        // 注册幂等
// transport.onChannelError(listener)                   // v1 新增：信道失败（E_CHANNEL_CLOSED）回调
// transport.removeOnMessage(listener)                  // 移除面（装载器失败重试防 stale 分发）
// transport.removeChannelErrorListener(listener)
```

### `registerWebEntry(client, transport)`

将 transport 的消息接收回调绑定到 client，完成 bridge 初始化；同时接线 `onChannelError`（存在时）——信道失败时全部 pending 请求立即以 `E_CHANNEL_CLOSED` fail，而非各自等待 10s `E_TIMEOUT`。

### `createJsBridgeClient(client, options?)`

会话门控封装：sessionId 为空时拦截非握手调用（本地直接 fail `E_NOT_READY`，与 Native `HandshakeGatePolicy` 的拒绝码一致，不发送请求）。

```ts
const jsBridgeClient = createJsBridgeClient(client, { readyMethod?: string })
jsBridgeClient.callNativeApi(method, data)
jsBridgeClient.callNativeApiWithSession(method, data, sessionId)
jsBridgeClient.getSessionId(): string
jsBridgeClient.setSessionId(sessionId: string): void
```

### `createReadyExtension(jsBridgeClient, options?)`

封装握手流程，握手成功后自动写入 sessionId。

```ts
const ready = createReadyExtension(jsBridgeClient, { readyMethod?: string })
ready.bootstrapReady({
  onSuccess?: (res: unknown) => void
  onFail?: (err: BridgeError) => void
}, {
  timeoutMs?: number   // v1 新增：覆盖默认 10000ms 握手超时（非容器降级场景可缩短）
})
```

### `getBridge(options?)`（v1 新增）

官方装载器：全 app 唯一的 ready 信号。单例 Promise，把"文件就绪 / 通道就绪 / 会话就绪"三层折叠为一个**握完手的 client**——异步加载场景推荐入口，替代人人手抄的编排胶水：

```ts
import { getBridge } from 'jsbridge-sdk'

const { client, transport, bridgeClient } = await getBridge({
  // 以下均可选：
  sdkUrl: './jsbridge-sdk.js',       // window.JsBridgeSDK 不在且给出时动态注入 script
  loadTimeoutMs: 5000,              // 注入加载超时
  handshakeTimeoutMs: 8000,        // 握手超时（缺省走 CoreBridgeClient 默认 10s）
  channelTimeoutMs: 2000,          // 单次 requestBridgeChannel 等待窗口，超时换新 reqId 重试
  maxChannelRetries: 3,             // 重试耗尽后 fail E_CHANNEL_CLOSED
  retryBackoffMs: 500,              // 建链重试退避基数（缺省 500ms，随重试次数线性放大）
})
client.callNativeApi('getUser', { userId: '001', success: console.log, fail: console.error })
```

返回 `BridgeReadyResult`：`{ client: JsBridgeClient, transport, bridgeClient: CoreBridgeClient }`。要点：缓存清除发生在 promise 落定之后（失败可重试）；超时全部参数化；命令队列 stub 场景下冲刷时机必须在握手成功后（会话门控对未握手调用直接本地 fail）。lifecycle 订阅若走此入口，须注意补发事件先于注册到达的丢失窗口（见 `createLifecycleBridge` 的时序说明）。

### `createLifecycleBridge(client, options?)`

订阅 `runtime.state` 事件，内置 seq 乱序过滤（`seq <= lastSeq` 的迟到/乱序事件被丢弃）。

> **注册时序**：若在握手结果落定之后才注册 handler，Native 的补发事件可能先于注册到达而永久丢失——务必在读取握手结果前完成注册（上例「使用」流程中的顺序即正确顺序）。`getBridge` 场景等价写法：不要 `await getBridge()` 之后才订阅生命周期——先经装载器之前的入口注册做不到时，应在 `onSuccess` 回调的第一条语句里注册（握手 ack 与补发事件同信道先后到达，回调首语句注册仍早于后续补发帧的概率较高，但唯一无窗口丢失的做法是装载前注册）。

```ts
const lifecycle = createLifecycleBridge(client, { lifecycleMethod?: string })

lifecycle.on((payload: StatePayload) => { /* state, seq */ })
lifecycle.off(listener)
lifecycle.getState(): string
```

## 协议版本

当前版本：**Protocol v1**

握手响应中的 `policyVersion` 字段用于运行时感知 Native 侧的协议能力。协议规范见 [docs/03-protocol.md](../../../docs/03-protocol.md)，SDK 设计见 [web-assets/docs/01-js-sdk-design.md](../../docs/01-js-sdk-design.md)。
