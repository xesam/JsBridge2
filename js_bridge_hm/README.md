# JsBridge Harmony

跨平台 JsBridge 协议的 HarmonyOS（鸿蒙）实现。

## 模块

| 模块 | 说明 |
|------|------|
| `js-bridge-core` | HAR 核心库：CoreBridge、JsBridge、PolicyEngine、SessionService |
| `js-bridge-example` | 示例应用：完整的集成示例 |

## 快速开始

```bash
cd js_bridge_hm/js-bridge-core
# 运行单元测试（需要 DevEco SDK）
cd ../js-bridge-example
# 在 DevEco Studio 中打开并运行
```

## 集成教程

> 内核分为两层，递进使用：
> - **CoreBridge**（Tier 1）— 纯消息分发，零安全依赖。适合可信本地页面、原型开发。
> - **JsBridge**（Tier 2）— 叠加在 CoreBridge 之上，增加握手、策略链、会话管理。适合生产环境。

### 1. 添加依赖

```json5
// oh-package.json5
{
  "dependencies": {
    "@xesam/js_bridge_core": "file:../../js-bridge-core"
  }
}
```

---

## 第一部分：CoreBridge

CoreBridge 是 Tier 1 核心协议层，只做三件事：注册 handler、分发消息、构建响应/事件。它不感知安全策略、会话、握手——这些全部由上层 JsBridge 负责。

### 1.1 创建 CoreBridge

CoreBridge 可不传 transport（后续通过 `attachTransport` 注入）：

```typescript
import { CoreBridge } from '@xesam/js_bridge_core';

const core = new CoreBridge();
```

### 1.2 注册 Handler

CoreBridge 支持同步 handler 和流式 handler（通过 `StreamingResultEmitter` 逐帧发送）：

```typescript
import { BridgeHandlerResult, BridgeError, StreamingResultEmitter } from '@xesam/js_bridge_core';

// 同步 handler
core.registerHandler('getUser', (payload) => {
  const userId = (payload as Record<string, Object>)?.['userId'];
  if (userId === '001') {
    return BridgeHandlerResult.success({ name: 'xesam' });
  }
  return BridgeHandlerResult.failure(new BridgeError('E_NOT_FOUND', 'user not found'));
});

// 流式 handler（通过 emit 逐帧推送）
core.registerStreamingHandler('timerLog', async (payload, emit?: StreamingResultEmitter) => {
  for (let i = 0; i < 3; i++) {
    emit?.success(BridgeHandlerResult.success(
      { event: 'tick', value: Math.floor(Math.random() * 100), seq: i + 1 }, false
    ));
  }
  emit?.success(BridgeHandlerResult.success(
    { event: 'stopped', running: false }, true
  ));
});
```

### 1.3 主动推送事件

```typescript
// 向 JS 侧推送事件（kind=event），无需等待请求
await core.postEvent('runtime.state', { state: 'foreground' });
```

### 1.4 消息分发

CoreBridge 的 `dispatch` 接收 `BridgeMessage` + `TrustedPageContext`，返回响应 JSON 字符串数组：

```typescript
import { BridgeMessage, TrustedPageContext } from '@xesam/js_bridge_core';

const request = BridgeMessage.fromJsonString(messageJson);
const context = new TrustedPageContext('file://', 'page-1');
const responses = await core.dispatch(request, context);
for (const response of responses) {
  sendToWeb(response);
}
```

### 1.5 独立使用场景

当页面完全可信（如本地 `file://` 页面）、无需安全校验时，CoreBridge 可独立使用。只需自行接收 JS 消息并调用 `dispatch`：

```typescript
const core = new CoreBridge();
core.registerHandler('getUser', (payload) => {
  return BridgeHandlerResult.success({ name: 'xesam' });
});

// 绑定 transport
core.attachTransport((messageJson: string): boolean => sendToWeb(messageJson));

// 手动分发
async function handleMessageFromWeb(messageJson: string): Promise<void> {
  const request = BridgeMessage.fromJsonString(messageJson);
  const context = new TrustedPageContext('file://', 'page-1');
  const responses = await core.dispatch(request, context);
  for (const response of responses) {
    sendToWeb(response);
  }
}
```

> **局限**：CoreBridge 没有握手、没有 origin 校验、没有会话管理。任何能向 WebView 发消息的 JS 都可以调用已注册的 handler。生产环境请使用 JsBridge。

---

## 第二部分：JsBridge

JsBridge 是 Tier 2 会话/策略/握手层，叠加在 CoreBridge 之上。它拦截消息入口，为每条消息插入策略链（结构校验 → 握手门控 → 访问控制），策略通过后再委托 CoreBridge 分发。JsBridge 内部持有一个 CoreBridge 实例，handler 注册委托给 CoreBridge。

### 2.1 安全分级

| Level | 配置 | 行为 |
|-------|------|------|
| **0** | `new JsBridge(options)`（默认） | 仅校验消息结构，无需握手 |
| **1** | `requireHandshake: true` | 需握手，不校验 origin |
| **2** | `JsBridge.secure(options)` | 握手 + origin 白名单 + 方法白名单（生产推荐） |

> **注意**：Level 2 下 `allowedOrigins` 不可包含 `"*"`，否则构造时抛出异常。

### 2.2 创建 JsBridge

```typescript
import { JsBridge, JsBridgeOptions, TrustedPageContext, PageContextProvider } from '@xesam/js_bridge_core';

const PAGE_ORIGIN = 'file://';

// 实现 PageContextProvider
class FilePageContextProvider implements PageContextProvider {
  createContext(message: BridgeMessage, pageInstanceId: string): TrustedPageContext {
    return new TrustedPageContext(PAGE_ORIGIN, pageInstanceId);
  }
}

// Level 0 — 开发环境（无握手，无来源校验）
const bridge = new JsBridge({
  transport: (messageJson: string): boolean => sendToWeb(messageJson),
  pageContextProvider: new FilePageContextProvider(),
} as JsBridgeOptions);

// Level 2 — 生产环境（握手 + 来源白名单 + 方法白名单）
const secureBridge = JsBridge.secure({
  allowedOrigins: new Set<string>([PAGE_ORIGIN]),
  methodWhitelist: new Set<string>([
    'bridge.handshake',
    'getUser',
    'getCurrentLocation',
  ]),
  defaultCapabilities: new Set<string>([
    'getUser',
    'getCurrentLocation',
  ]),
  transport: (messageJson: string): boolean => sendToWeb(messageJson),
  pageContextProvider: new FilePageContextProvider(),
} as JsBridgeOptions);
```

### 2.3 配置 Web 组件

HarmonyOS 使用 `javaScriptProxy` 与 WebView 进行通信。消息从 JS 到达后，通过 `bindTransport()` 返回的回调自动进入 JsBridge 处理（策略链 → 握手/会话 → 委托 CoreBridge.dispatch → 响应自动发回）：

```typescript
import { webview } from '@kit.ArkWeb';

private controller: webview.WebviewController = new webview.WebviewController();

// 建立入站闭环：bindTransport() 返回的回调传给 NativeBridgeProxy
const onIncoming = bridge.bindTransport();
private nativeBridge = new NativeBridgeProxy((msg: string) => void onIncoming(msg));

Web({ src: $rawfile('web/index.html'), controller: this.controller })
  .javaScriptProxy({
    object: this.nativeBridge,
    name: 'NativeBridge',
    methodList: ['postMessage'],
    controller: this.controller
  })
  .onPageBegin(() => {
    this.bridge.resetForNewPage();
  })
```

`bindTransport()` 返回的回调内部自动串联 `processIncomingResponsesFromProvider` → `sendViaTransport` 闭环，无需手动处理消息路由和响应发送。

> 出站发送仍需在构造时通过 `transport` 参数注入：
> ```typescript
> transport: (messageJson: string): boolean => this.sendToWeb(messageJson),
> ```

### 2.4 注册 Handler

JsBridge 委托 CoreBridge 注册 handler，同时支持流式 handler：

```typescript
import { BridgeHandlerResult, StreamingResultEmitter } from '@xesam/js_bridge_core';

// 同步处理器（委托 CoreBridge）
bridge.registerHandler('getUser', (payload) => {
  return BridgeHandlerResult.success({ name: 'xesam' });
});

// 流式处理器（多帧响应）
bridge.registerStreamingHandler('timerLog', async (payload, emit?: StreamingResultEmitter) => {
  for (let i = 0; i < 3; i++) {
    emit?.success(BridgeHandlerResult.success(
      { event: 'tick', value: Math.floor(Math.random() * 100), seq: i + 1 }, false
    ));
  }
  emit?.success(BridgeHandlerResult.success(
    { event: 'stopped', running: false }, true
  ));
});
```

### 2.5 页面生命周期

```typescript
import { LifecycleExtension } from '@xesam/js_bridge_core';

private lifecycleExtension: LifecycleExtension = new LifecycleExtension(this.bridge);

aboutToAppear(): void {
  this.bridge.resetForNewPage();
  void this.lifecycleExtension.onHostEvent('created');
}

onPageShow(): void {
  void this.lifecycleExtension.onHostEvent('foreground');
}

onPageHide(): void {
  void this.lifecycleExtension.onHostEvent('background');
}
```

> 在握手完成之前发送的事件会被排队（最多 32 条），握手完成后按顺序刷新。

### 2.6 加载页面

```typescript
// 确保 WebAssets 已通过 `pnpm sync` 同步到 entry/src/main/resources/rawfile/web/
Web({ src: $rawfile('web/index.html'), controller: this.controller })
```

## WebAssets

`entry/src/main/resources/rawfile/web/` 不纳入版本控制。从 `web-assets/` 同步：

```bash
cd web-assets && pnpm sync
```

## 签名配置

HarmonyOS 需要签名配置。示例应用使用调试签名配置。对于你自己的项目，请在 `build-profile.json5` 中配置签名：

```json5
{
  "signingConfigs": [
    {
      "name": "default",
      "type": "HarmonyOS",
      "material": {
        "certpath": "your-cert.cer",
        "storePassword": "your-store-password",
        "keyAlias": "your-key-alias",
        "keyPassword": "your-key-password",
        "profile": "your-profile.p7b",
        "signAlg": "SHA256withECDSA",
        "storeFile": "your-key-store.p12"
      }
    }
  ]
}
```

## 示例方法

| 方法 | 说明 |
|------|------|
| `getUser` | 返回模拟用户信息 |
| `request` | HTTP GET 请求 |
| `timerLog` | 流式定时器（多帧） |
| `showLoading` | 原生加载弹窗 |
| `pickImage` | 图片选择器 |
| `pickInput` | 输入对话框 |
| `getCurrentLocation` | 地理定位 |
