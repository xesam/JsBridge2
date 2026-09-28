# iOS

iOS 平台 JsBridge 实现，Swift Package，支持 iOS 13+，WKWebView。

> 消息模型为纯异步（协议 v1 不支持同步调用，所有结果以独立 response/event 消息回传，详见 [docs/03-protocol.md §1 消息模型](../docs/03-protocol.md)）。这也是协议全异步设计的硬约束来源：`WKScriptMessageHandler` 无返回值、`evaluateJavaScript` 仅有异步 completion 形式，WKWebView 从平台层面不存在同步通道。

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
// .package(url: "https://github.com/xesam/JsBridge2.git", from: "0.0.1")
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

CoreBridge 提供两个注册入口：Simple（单帧）与 Async（可多帧）。两者的第一个形参都是内核派生并注入的 `TrustedPageContext`。同一 method 重复注册时**后者覆盖前者**。

```swift
// Simple handler：单帧响应，done 恒为 true
core.registerSimpleHandler(method: "getUser") { context, payload in
    guard case .object(let fields)? = payload, case .string(let userId)? = fields["userId"] else {
        return .failure(BridgeError(code: "E_INVALID_MESSAGE", message: "invalid payload"))
    }
    if userId == "001" {
        return .success(.object(["name": .string("xesam")]))
    }
    return .failure(BridgeError(code: "E_NOT_FOUND", message: "user not found"))
}

// Async handler：多次推帧，emit 的第二个参数 done=true 表示末帧
core.registerAsyncHandler(method: "timerLog") { context, payload, emitter in
    guard let emitter else { return }
    await emitter(.success(.object(["event": .string("tick"), "seq": .number(1)])), false)
    await emitter(.success(.object(["event": .string("stopped")])), true)
}
```

`context` 即本次请求所属页面的可信上下文（`origin` / `pageInstanceId`），可用于按页面区分响应行为。

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
core.registerSimpleHandler(method: "getUser") { context, payload in
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

> **上下文**：iOS 无 `bind()` 自动闭环形态（该形态为 Android 特有）：standalone 使用时经构造期注入（或 `attachTransport`）出站、手动调用 `dispatch`，`TrustedPageContext` 由宿主手工构造——该 origin 为**宿主自声明**（须为归一化形态，见 [docs/03-protocol.md §9 细则 5](../docs/03-protocol.md)），不是内核经 Provider 派生的可信值，信任边界不高于 null 配置（见 [docs/04-cross-platform.md §3.1](../docs/04-cross-platform.md)）；页面非完全可信时请使用 Tier 2 JsBridge。

> **局限**：CoreBridge 没有握手、没有 origin 校验、没有会话管理。任何能向 WebView 发消息的 JS 都可以调用已注册的 handler。生产环境请使用 JsBridge。

---

## 第二部分：JsBridge

JsBridge 是 Tier 2 会话/策略/握手层，叠加在 CoreBridge 之上。它拦截消息入口，为每条消息插入策略链（结构校验 → 握手门控 → 访问控制），策略通过后再委托 CoreBridge 分发。JsBridge 内部持有一个 CoreBridge 实例，handler 注册委托给 CoreBridge。

### 2.1 安全模式

`securityConfig` 参数二选一，没有中间态：

| 配置 | 行为 |
|------|------|
| `nil` | 无安全检查：仅校验消息结构，无需握手 |
| `JsBridge.SecurityConfig` | 握手门控 + session 校验；`allowedOrigins` / `methodWhitelist` 决定两个白名单维度是否进链（`["*"]` = 显式不限制）；`methodWhitelist` 为业务方法白名单，协议方法（`bridge.handshake` / `bridge.cancelScope`）由框架自动放行 |

> **配置校验**：传入 `SecurityConfig` 时 `allowedOrigins` 与 `methodWhitelist` 必须显式设置（不可为 `nil`），否则构造期触发 `precondition(...)` 断言失败（如 `precondition(config.allowedOrigins != nil, ...)`，见 `JsBridge.init`）；`["*"]` 是合法的"不限制该维度"声明。`methodWhitelist` 只需列出**业务方法**——协议方法由框架装配期自动并入放行集，无需显式写入 `bridge.handshake`。

### 2.2 创建 JsBridge

```swift
import BridgeCore
import BridgeSystem

// 创建 transport（封装 WKScriptMessageHandler + evaluateJavaScript + bootstrap script）
let transport = WKWebViewBridgeTransport(webView: webView)

// 无安全配置 — 开发/测试
let bridge = JsBridge(
    securityConfig: nil,
    pageContextProvider: WebViewPageContextProvider(webView: webView),
    transport: transport
)

// 传入 SecurityConfig — 生产环境
var secureConfig = JsBridge.SecurityConfig()
secureConfig.allowedOrigins = ["file://", "https://your-domain.com"]
secureConfig.methodWhitelist = [
    "getUser",
    "getCurrentLocation"
]
let secureBridge = JsBridge(
    securityConfig: secureConfig,
    pageContextProvider: WebViewPageContextProvider(webView: webView),
    transport: transport
)
```

需要自行实现 `PageContextProvider`。**origin 必须经由内核的 `OriginNormalizer` 派生**（协议契约见 [docs/03-protocol.md §9 细则 5](../docs/03-protocol.md)：`TrustedPageContext.origin` 的唯一合法形态由内核的四端统一手写归一化算法产生——刻意不使用 `URL`/`URLComponents` 解析，宿主不得自写归一化，验收锚点 C54）：

```swift
final class WebViewPageContextProvider: PageContextProvider {
    private weak var webView: WKWebView?

    init(webView: WKWebView) { self.webView = webView }

    func createContext(for message: BridgeMessage, pageInstanceId: String) -> TrustedPageContext {
        TrustedPageContext(origin: OriginNormalizer.normalize(webView?.url), pageInstanceId: pageInstanceId)
    }
}
```

> URL 缺失 / scheme 词法非法 / 非层级形态（`about:` / `data:` 等）/ 畸形端口，归一化一律返回空串 `""`（例：`about:blank` → `""`）——空串 origin 永远不会命中任何白名单，fail-closed。因此**不要**在 `allowedOrigins` 中写 `"about:blank"` 之类的死条目，也不要用占位值替代真实 origin。字符串 URL 可用 `OriginNormalizer.normalize(urlString:)` 重载。

### 2.3 WKWebViewBridgeTransport

`WKWebViewBridgeTransport` 封装了 WKWebView 的全部管道代码。在 `init` 时自动完成：

1. 向 `WKUserContentController` 注册 `WKScriptMessageHandler`（名称默认 `"NativeBridge"`，与 JS 侧 `native-transport.ts` 检测路径一致）
2. 注入 bootstrap script（设置 `window.__jsbridge2__.callNativeApi` 桥接到 `webkit.messageHandlers.NativeBridge.postMessage`）
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

JsBridge 委托 CoreBridge 注册 handler：Simple（单帧）与 Async（可多帧）两个入口，第一个形参均为内核注入的 `TrustedPageContext`。同一 method 重复注册时**后者覆盖前者**。

```swift
// Simple handler（委托 CoreBridge）：单帧响应，done 恒为 true
bridge.registerSimpleHandler(method: "getUser") { context, payload in
    guard case .object(let fields)? = payload, case .string(let userId)? = fields["userId"] else {
        return .failure(BridgeError(code: "E_INVALID_MESSAGE", message: "invalid payload"))
    }
    if userId == "001" {
        return .success(.object(["name": .string("xesam")]))
    }
    return .failure(BridgeError(code: "E_NOT_FOUND", message: "user not found"))
}

// Async handler：多次推帧，emit 的第二个参数 done=true 表示末帧
bridge.registerAsyncHandler(method: "timerLog") { context, payload, emitter in
    guard let emitter else { return }
    await emitter(.success(.object(["event": .string("tick"), "seq": .number(1)])), false)
    await emitter(.success(.object(["event": .string("stopped")])), true)
}
```

### 2.6 页面生命周期

```swift
// 页面加载开始时重置会话
bridge.resetPageInstance()

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
