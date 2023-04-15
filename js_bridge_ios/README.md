# iOS

iOS 平台 JsBridge 实现，Swift Package，支持 iOS 13+，WKWebView。

## 模块

| 模块 | 说明 |
|------|------|
| `js-bridge-core-swift` | Swift Package 核心库：BridgeCore（CoreBridge、JsBridge、PolicyEngine、SessionService）+ BridgeSystem（WKWebViewBridgeTransport）|
| `js-bridge-example` | 示例 App：演示完整集成流程 |

## 快速开始

```bash
cd js_bridge_ios
swift test --package-path js-bridge-core-swift
```

## 集成教程

> 内核分为两层，递进使用：
> - **CoreBridge**（Tier 1）— 纯消息分发，零安全依赖。适合可信本地页面、原型开发。
> - **JsBridge**（Tier 2）— 叠加在 CoreBridge 之上，增加握手、策略链、会话管理。适合生产环境。

### 1. 添加依赖

通过 Swift Package Manager 添加：

```swift
// Package.swift
dependencies: [
    .package(path: "../js-bridge-core-swift")
]
// 或发布后：
// .package(url: "https://github.com/xesam/JsBridge2.git", from: "0.1.0")
```

---

## 第一部分：CoreBridge

CoreBridge 是 Tier 1 核心协议层，只做三件事：注册 handler、分发消息、构建响应/事件。它不感知安全策略、会话、握手——这些全部由上层 JsBridge 负责。

### 1.1 创建 CoreBridge

CoreBridge 可不传 transport（后续通过 `attachTransport` 注入）：

```swift
import BridgeCore

let core = CoreBridge()
```

### 1.2 注册 Handler

CoreBridge 支持同步 handler 和流式 handler（返回多帧）：

```swift
// 同步 handler
core.registerHandler(method: "getUser") { payload in
    guard let userId = payload?.asObject?["userId"]?.asString else {
        return .failure(BridgeError(code: "E_INVALID_MESSAGE", message: "invalid payload"))
    }
    if userId == "001" {
        return .success(.object(["name": .string("xesam")]))
    }
    return .failure(BridgeError(code: "E_NOT_FOUND", message: "user not found"))
}

// 流式 handler（返回多帧，done=false 表示后续还有帧）
core.registerStreamingHandler(method: "timerLog") { payload in
    return [
        .success(.object(["event": "tick", "value": 42, "seq": 1]), done: false),
        .success(.object(["event": "stopped", "running": false]), done: true)
    ]
}
```

### 1.3 主动推送事件

```swift
// 向 JS 侧推送事件（kind=event），无需等待请求
core.postEvent(method: "runtime.state", payload: .object(["state": .string("resumed")]))
```

### 1.4 消息分发

CoreBridge 的 `dispatch` 接收 `BridgeMessage` + `TrustedPageContext`，返回响应 JSON 字符串数组：

```swift
let responses = core.dispatch(request: message, context: TrustedPageContext(origin: "file://", pageInstanceId: "page-1"))
for response in responses {
    sendToWeb(response)
}
```

### 1.5 独立使用场景

当页面完全可信（如本地 `file://` 页面）、无需安全校验时，CoreBridge 可独立使用。只需创建 transport 并手动绑定：

```swift
import BridgeCore
import BridgeSystem

let transport = WKWebViewBridgeTransport(webView: webView)
let core = CoreBridge(transport: transport)
core.registerHandler(method: "getUser") { payload in
    return .success(.object(["name": .string("xesam")]))
}

// 建立入站闭环：transport 收到 JS 消息 → CoreBridge.dispatch → 响应自动通过 transport 发回
transport.bind { messageJson in
    guard let request = BridgeMessage.fromJsonString(messageJson) else { return }
    let context = TrustedPageContext(origin: "file://", pageInstanceId: "page-1")
    let responses = core.dispatch(request: request, context: context)
    for response in responses { _ = transport.send(response) }
}
```

> **局限**：CoreBridge 没有握手、没有 origin 校验、没有会话管理。任何能向 WebView 发消息的 JS 都可以调用已注册的 handler。生产环境请使用 JsBridge。n

---

## 第二部分：JsBridge

JsBridge 是 Tier 2 会话/策略/握手层，叠加在 CoreBridge 之上。它拦截消息入口，为每条消息插入策略链（结构校验 → 握手门控 → 访问控制），策略通过后再委托 CoreBridge 分发。JsBridge 内部持有一个 CoreBridge 实例，handler 注册委托给 CoreBridge。

### 2.1 安全分级

| Level | 配置 | 行为 |
|-------|------|------|
| **0** | `JsBridge.SecurityConfig()` | 仅校验消息结构，无需握手 |
| **1** | `JsBridge.SecurityConfig().withHandshakeGate()` | 需握手，不校验 origin |
| **2** | `JsBridge.SecurityConfig.secure()` | 握手 + origin 白名单 + 方法白名单（生产推荐） |

### 2.2 创建 JsBridge

```swift
import BridgeCore
import BridgeSystem

// 创建 transport（封装 WKScriptMessageHandler + evaluateJavaScript + bootstrap script）
let transport = WKWebViewBridgeTransport(webView: webView)

// Level 0 — 开发/测试
let bridge = JsBridge(
    securityConfig: JsBridge.SecurityConfig(),
    pageContextProvider: WebViewPageContextProvider(webView: webView),
    transport: transport
)

// Level 2 — 生产环境
var secureConfig = JsBridge.SecurityConfig.secure()
secureConfig.allowedOrigins = ["file://", "https://your-domain.com"]
secureConfig.methodWhitelist = [
    BridgeApiContract.methodHandshake,
    "getUser",
    "getCurrentLocation"
]
secureConfig.defaultCapabilities = ["getUser", "getCurrentLocation"]
let secureBridge = JsBridge(
    securityConfig: secureConfig,
    pageContextProvider: WebViewPageContextProvider(webView: webView),
    transport: transport
)
```

需要自行实现 `PageContextProvider`，从 WebView URL 提取 origin：

```swift
final class WebViewPageContextProvider: PageContextProvider {
    private weak var webView: WKWebView?

    init(webView: WKWebView) { self.webView = webView }

    func createContext(for message: BridgeMessage, pageInstanceId: String) -> TrustedPageContext {
        TrustedPageContext(origin: normalizeOrigin(webView?.url), pageInstanceId: pageInstanceId)
    }

    private func normalizeOrigin(_ url: URL?) -> String {
        guard let url else { return "about:blank" }
        switch url.scheme?.lowercased() {
        case "file":  return "file://"
        case "about": return "about:blank"
        default:
            if let host = url.host, let scheme = url.scheme {
                return "\(scheme)://\(host)"
            }
            return "about:blank"
        }
    }
}
```

### 2.3 WKWebViewBridgeTransport

`WKWebViewBridgeTransport` 封装了 WKWebView 的全部管道代码。在 `init` 时自动完成：

1. 向 `WKUserContentController` 注册 `WKScriptMessageHandler`（名称默认 `"NativeBridge"`，与 JS 侧 `native-transport.ts` 检测路径一致）
2. 注入 bootstrap script（设置 `window.$__native__.callNativeApi` 桥接到 `webkit.messageHandlers.NativeBridge.postMessage`）
3. 出站发送时自动处理 JSON 字符串转义 + `evaluateJavaScript` 调用

> `WKWebViewBridgeTransport` 位于 `BridgeSystem` target，依赖 `WebKit`。`BridgeCore` target 保持平台无关。

### 2.4 建立入站闭环

`bindTransport()` 将 transport 的入站回调与 JsBridge 的策略链 + 分发逻辑串联，形成闭环：transport 收到 JS 消息 → 策略检查 → 分发 → 响应自动通过 `transport.send()` 发回。

```swift
// 建立入站闭环
bridge.bindTransport()
```

调用后无需手动处理 `WKScriptMessageHandler` 回调、手动调用 `processIncomingResponses`、手动 `evaluateJavaScript` 发送响应——全部由 `WKWebViewBridgeTransport` + `bindTransport()` 自动完成。

### 2.5 注册 Handler

JsBridge 委托 CoreBridge 注册 handler，同时支持流式 handler：

```swift
// 同步 handler（委托 CoreBridge）
bridge.registerHandler(method: "getUser") { payload in
    guard let userId = payload?.asObject?["userId"]?.asString else {
        return .failure(BridgeError(code: "E_INVALID_MESSAGE", message: "invalid payload"))
    }
    if userId == "001" {
        return .success(.object(["name": .string("xesam")]))
    }
    return .failure(BridgeError(code: "E_NOT_FOUND", message: "user not found"))
}

// 流式 handler（返回多帧）
bridge.registerStreamingHandler(method: "timerLog") { payload in
    return [
        .success(.object(["event": "tick", "value": 42, "seq": 1]), done: false),
        .success(.object(["event": "stopped", "running": false]), done: true)
    ]
}
```

### 2.6 页面生命周期

```swift
// 页面加载开始时重置会话
bridge.resetForNewPage()

// 生命周期事件推送（可选）
let lifecycleExtension = LifecycleExtension(bridge: bridge)

// 通过 NotificationCenter 监听 App 生命周期
NotificationCenter.default.addObserver(self, selector: #selector(handleDidBecomeActive),
    name: UIApplication.didBecomeActiveNotification, object: nil)
NotificationCenter.default.addObserver(self, selector: #selector(handleDidEnterBackground),
    name: UIApplication.didEnterBackgroundNotification, object: nil)

@objc func handleDidBecomeActive() { lifecycleExtension.onHostEvent(state: "resumed") }
@objc func handleDidEnterBackground() { lifecycleExtension.onHostEvent(state: "stopped") }

// 页面加载
if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebAssets") {
    webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
}
```

> 握手完成前的事件会排队缓存（上限 32），握手成功后按序补发。

## WebAssets

`js-bridge-example/WebAssets/` 不纳入版本管理，从根目录 `web-assets/` 同步：

```bash
cd web-assets && pnpm sync
```
