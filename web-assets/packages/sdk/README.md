# jsbridge-sdk

JsBridge2 的 JS 客户端 SDK。为运行在 WebView 中的 JS 页面提供与宿主 Native 应用通信的能力，支持 Android、iOS、Flutter、HarmonyOS 四个平台。

## 安装

> 当前包尚未发布到 npm，以下为发布后的消费方式；发布前请使用下文 IIFE bundle 方式。

```bash
npm install jsbridge-sdk
# 或
pnpm add jsbridge-sdk
```

## 使用

### ESM（现代构建工具，发布后可用）

```js
import {
  BridgeClient,
  BridgeProtocol,
  createNativeTransport,
  registerWebEntry,
  createSessionApi,
  createReadyExtension,
  createLifecycleBridge,
} from 'jsbridge-sdk'

const transport = createNativeTransport()
const client = new BridgeClient(transport)
registerWebEntry(client, transport)

const sessionApi = createSessionApi(client, {
  readyMethod: BridgeProtocol.METHOD_HANDSHAKE
})
const ready = createReadyExtension(sessionApi, {
  readyMethod: BridgeProtocol.METHOD_HANDSHAKE
})

ready.bootstrapReady({
  onSuccess(res) {
    console.log('bridge ready, session:', res.sessionId)
    sessionApi.callNativeApi('getUser', {
      userId: '001',
      success(user) { console.log(user) },
      fail(err)  { console.error(err) }
    })
  },
  onFail(err) {
    console.error('handshake failed', err)
  }
})
```

### IIFE（直接通过 script 标签加载，当前推荐）

由 `pnpm sync` 构建产物 `dist/iife/jsbridge-sdk.js`（经 Babel 转译到 ES5，兼容旧版 WebView），复制到 WebView 资源目录后加载，暴露全局 `window.JsBridgeSDK`。

```html
<script src="./jsbridge-sdk.js"></script>
<script>
  const {
    BridgeClient, BridgeProtocol,
    createNativeTransport, registerWebEntry,
    createSessionApi, createReadyExtension,
  } = window.JsBridgeSDK

  const transport = createNativeTransport()
  const client = new BridgeClient(transport)
  // ...
</script>
```

## API

### `BridgeProtocol`

协议常量：

| 常量 | 值 |
|------|----|
| `KIND_REQUEST` | `'request'` |
| `KIND_RESPONSE` | `'response'` |
| `KIND_EVENT` | `'event'` |
| `METHOD_HANDSHAKE` | `'bridge.handshake'` |
| `METHOD_LIFECYCLE_STATE` | `'runtime.state'` |
| `METHOD_CANCEL_SCOPE` | `'bridge.cancelScope'` |
| `ERR_INVALID_MESSAGE` | `'E_INVALID_MESSAGE'` |
| `ERR_TIMEOUT` | `'E_TIMEOUT'` |
| `ERR_CANCELED` | `'E_CANCELED'` |
| `ERR_INTERNAL` | `'E_INTERNAL'` |

### `BridgeClient`

```ts
new BridgeClient(transport: Transport, sessionId?: string)

client.setSessionId(sessionId: string): void
client.getSessionId(): string
client.registerEventHandler(method: string, handler: (payload: unknown) => void, signal?: AbortSignal): void
client.callNativeApi(method: string, data?: CallOptions): void
client.callNativeApiWithSession(method: string, data?: CallOptions, sessionId?: string): void
client.handleIncomingMessage(messageJsonString: string): void
```

`CallOptions`：

```ts
{
  success?: (payload: unknown) => void
  fail?: (error: BridgeError) => void
  timeoutMs?: number   // 默认 10000ms
  keep?: boolean       // 流式响应，默认 false
  signal?: AbortSignal // 取消请求
  [key: string]: unknown
}
```

### `createNativeTransport()`

自动检测运行平台（Android / iOS / HarmonyOS / WebMessagePort）并返回对应的 transport 实现。

```ts
const transport: NativeTransport = createNativeTransport()
// transport.send(messageJson)
// transport.onMessage(listener)
```

### `registerWebEntry(client, transport)`

将 transport 的消息接收回调绑定到 client，完成 bridge 初始化。

### `createSessionApi(client, options?)`

封装 sessionId 管理，握手完成前拦截非握手调用。

```ts
const sessionApi = createSessionApi(client, { readyMethod?: string })
sessionApi.callNativeApi(method, data)
sessionApi.callNativeApiWithSession(method, data, sessionId)
sessionApi.getSessionId(): string
sessionApi.setSessionId(sessionId: string): void
```

### `createReadyExtension(sessionApi, options?)`

封装握手流程，握手成功后自动写入 sessionId。

```ts
const ready = createReadyExtension(sessionApi, { readyMethod?: string })
ready.bootstrapReady({
  onSuccess?: (res: unknown) => void
  onFail?: (err: BridgeError) => void
})
```

### `createLifecycleBridge(client, options?)`

订阅 `runtime.state` 事件，内置 seq 乱序过滤。

```ts
const lifecycle = createLifecycleBridge(client, { lifecycleMethod?: string })

lifecycle.on((payload: StatePayload) => { /* state, seq */ })
lifecycle.off(listener)
lifecycle.getState(): string
```

## 协议版本

当前版本：**Protocol v1**

握手响应中的 `policyVersion` 字段用于运行时感知 Native 侧的协议能力。详见 [协议规范](../../../docs/01-protocol.md)。
