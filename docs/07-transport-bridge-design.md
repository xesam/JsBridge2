# 07 Transport Bridge 详细设计

> 状态：草案 · 2026-07

## 1. 目标

消除 iOS / Flutter / HarmonyOS 三端集成方被迫手写的 50+ 行管道代码（bootstrap script、消息路由循环、`evaluateJavaScript` 调用、字符串转义），使集成代码量向 Android（4 行）对齐。

## 2. 约束（不可违反）

| 约束 | 来源 | 影响 |
|------|------|------|
| Core 层零平台导入 | `05-review.md §2` | iOS `BridgeCore` target 不得 `import WebKit` |
| Transport 收敛到字符串边界 | `05-review.md §2` | 签名中不得出现平台类型 |
| 渐进增强 | `AGENTS.md` | 新增 API 必须是"关闭且可选"——不传 transport 仍可手动 `processIncomingResponses` |
| 不破坏现有 API | 当前 v1 稳定 | 新增方法不删除/不改签名 |
| 四端协议一致 | `AGENTS.md` | 新增方法语义四端对齐 |

## 3. 变更总览

| 平台 | 新增文件 | 修改文件 | 消费者代码行数变化 |
|------|---------|---------|------------------|
| iOS | `Sources/BridgeSystem/WKWebViewBridgeTransport.swift` | `Package.swift`、`CoreBridge.swift`、`JsBridge.swift` | ~50 → ~4 |
| Flutter | — | `core_bridge.dart`、`js_bridge.dart` | ~15 → ~6 |
| HarmonyOS | — | `CoreBridge.ets`、`JsBridge.ets` | ~12 → ~5 |
| Android | — | — | 不变（已有 `resetTransport()`） |
| WebAssets | — | — | 不变（`native-transport.ts` 无需改动） |

## 4. iOS 详细设计

### 4.1 模块结构：新增 `BridgeSystem` target

```
js_bridge_ios/js-bridge-core-swift/
├── Package.swift                      ← 新增 BridgeSystem target
├── Sources/
│   ├── Bridge/                        ← 不变（BridgeCore target，零平台导入）
│   │   ├── Core/
│   │   │   ├── CoreBridge.swift        ← 新增 sendViaTransport()
│   │   │   └── BridgeTransport.swift   ← 不变
│   │   ├── Extensions/
│   │   │   └── LifecycleExtension.swift
│   │   ├── Security/
│   │   ├── Api/
│   │   └── JsBridge.swift              ← 新增 bindTransport()
│   └── BridgeSystem/                  ← 新增 target
│       └── WKWebViewBridgeTransport.swift
└── Tests/
    ├── BridgeCoreTests/
    └── BridgeSystemTests/              ← 新增
```

`Package.swift` 变更：

```swift
targets: [
    .target(name: "BridgeCore", path: "Sources/Bridge"),
    .target(name: "BridgeSystem", dependencies: ["BridgeCore"], path: "Sources/BridgeSystem"),  // 新增
    .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"], path: "Tests/BridgeCoreTests"),
    .testTarget(name: "BridgeSystemTests", dependencies: ["BridgeSystem"], path: "Tests/BridgeSystemTests"),  // 新增
],
products: [
    .library(name: "BridgeCore", targets: ["BridgeCore"]),
    .library(name: "BridgeSystem", targets: ["BridgeSystem"]),  // 新增
    .library(name: "js-bridge-core-swift", targets: ["BridgeCore", "BridgeSystem"]),
]
```

依据：Android `extensions/system/` 同样位于同一 Gradle module 内但持有平台导入；Swift 用独立 target 实现等价隔离。

### 4.2 `WKWebViewBridgeTransport`

```
位置：Sources/BridgeSystem/WKWebViewBridgeTransport.swift
导入：import Foundation · import WebKit · import BridgeCore
继承：NSObject（WKScriptMessageHandler 要求 ObjC 兼容）
遵循：BridgeTransport, WKScriptMessageHandler
```

```swift
import Foundation
import WebKit
import BridgeCore

/// WKWebView 传输适配器。
/// 封装入站（WKScriptMessageHandler）与出站（evaluateJavaScript），
/// 自动处理 bootstrap script 注入、消息体类型转换、字符串转义。
/// 消费者只需创建实例并传给 JsBridge，无需手写任何 JS 或 WebView 管道代码。
public final class WKWebViewBridgeTransport: NSObject, BridgeTransport, WKScriptMessageHandler {

    /// JS 侧 postMessage 的 handler 名称。
    /// 默认 "NativeBridge"，与 native-transport.ts 的检测路径一致。
    public let messageName: String

    private weak var webView: WKWebView?
    private var listener: ((String) -> Void)?
    private var isRegistered = false

    /// 创建并注册到指定 WebView。
    /// - Parameters:
    ///   - webView: 目标 WKWebView；须在页面加载前调用。
    ///   - messageName: WKScriptMessageHandler 注册名。
    public init(webView: WKWebView, messageName: String = "NativeBridge") {
        self.webView = webView
        self.messageName = messageName
        super.init()
        registerHandler()
        injectBootstrap()
    }

    deinit {
        // Best-effort：必须在主线程操作 WKUserContentController。
        // 不调 close()——close() 依赖 isRegistered 状态，deinit 时状态可能不一致。
        let wv = webView
        let name = messageName
        DispatchQueue.main.async {
            wv?.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    // MARK: - BridgeTransport

    public func bind(listener: @escaping (String) -> Void) {
        self.listener = listener
    }

    @discardableResult
    public func send(_ messageJson: String) -> Bool {
        guard let webView else { return false }
        let escaped = jsonStringLiteral(messageJson)
        let js = "window.__bridgeReceiveFromNative && window.__bridgeReceiveFromNative(\"\(escaped)\")"
        webView.evaluateJavaScript(js, completionHandler: nil)
        return true
    }

    public func close() {
        guard isRegistered, let webView else { return }
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: messageName)
        isRegistered = false
        listener = nil
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == messageName else { return }
        guard let body = normalizeBody(message.body) else { return }
        listener?(body)
    }

    // MARK: - Private

    private func registerHandler() {
        guard let webView else { return }
        webView.configuration.userContentController.add(self, name: messageName)
        isRegistered = true
    }

    private func injectBootstrap() {
        guard let webView else { return }
        let source = """
        (function() {
            if (!window.$__native__) { window.$__native__ = {}; }
            window.$__native__.callNativeApi = function(messageJson) {
                window.webkit.messageHandlers.\(messageName).postMessage(String(messageJson));
            };
        })();
        """
        let script = WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        webView.configuration.userContentController.addUserScript(script)
        // 不存储 script 引用——removeUserScript(_:) 是 iOS 14+ API，
        // 而项目支持 iOS 13。user script 是纯 JS 字符串，不产生强引用，
        // 随 WKUserContentController 生命周期自然释放。
    }

    // 仅处理 String 和 [String: Any]——JS 侧始终调用 postMessage(String(json))，
    // dictionary 分支是 WKWebView 自动解析 JSON body 的防御性 fallback。
    private func normalizeBody(_ body: Any) -> String? {
        if let s = body as? String { return s }
        if let dict = body as? [String: Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return json
        }
        return nil
    }

    private func jsonStringLiteral(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
```

### 4.3 `close()` 幂等性

`WKUserContentController.removeScriptMessageHandler(forName:)` 在未注册时调用会触发 precondition crash。设计用 `isRegistered` 标志保护：

- `init` 时 `add(self, name:)` → `isRegistered = true`
- `close()` 时 `guard isRegistered` → 移除 → `isRegistered = false`
- `deinit` 不走 `close()`，直接 dispatch `removeScriptMessageHandler`（已注册时才有效，未注册时 UCC 已释放，无影响）
- `bridge.destroy()` → `core.destroy()` → `transport?.close()` 是正常路径
- Transport 被释放但未显式 `close()` → `deinit` 是安全网

### 4.4 Retain Cycle 分析

```
引用链：
  WKWebView ──strong──► WKWebViewConfiguration ──strong──► WKUserContentController
                                                                                │
                                                                    add(self, name:)
                                                                ──strong──► Transport
                                                                               │
                                                                    [weak webView]──► WKWebView  (weak ✓)
                                                                               │
                                                                    listener closure
                                                                ──captures──► JsBridge (via [weak self]) (weak ✓)

  JsBridge ──strong──► CoreBridge ──strong──► transport  (CoreBridge.transport field)
```

唯一需要手动打断的强引用：`WKUserContentController → Transport`。

打断方式：
1. **正常路径**：`bridge.destroy()` → `core.destroy()` → `transport?.close()` → `removeScriptMessageHandler` → UCC 释放 Transport
2. **安全网**：`Transport.deinit` 直接 dispatch `removeScriptMessageHandler` 到主线程——如果 consumer 忘记 `destroy()`，deinit 会 best-effort 清理

deinit 安全性：
- `webView` 是 weak，deinit 时读取可能为 nil → 闭包内 `wv?` 可选链保护
- `removeScriptMessageHandler` 需在主线程 → `DispatchQueue.main.async` 保证
- 如果 WebView 已释放，`wv` 为 nil，闭包内 `wv?` 跳过，无副作用
- 如果 WebView 仍存活，闭包在主线程安全移除 handler，打断强引用
- `deinit` 不依赖 `isRegistered` 标志——即使 `close()` 已执行过，重复 `remove` 不再注册时 crash
  因为 `DispatchQueue.main.async` 的闭包在 deinit 之后才执行，此时 UCC 可能已释放，
  `wv?` 为 nil，跳过即可

### 4.5 CoreBridge 变更：新增 `sendViaTransport`

```swift
// CoreBridge.swift — 新增

/// 通过已绑定的 transport 发送预构建的 JSON 字符串。
/// 供 bindTransport 闭环使用；与 Android 的 respondSuccess/respondFail 对齐。
@discardableResult
public func sendViaTransport(_ messageJson: String) -> Bool {
    guard let transport else {
        sendFailureCount += 1
        return false
    }
    let sent = transport.send(messageJson)
    if !sent { sendFailureCount += 1 }
    return sent
}
```

依据：Android `CoreBridge.respondSuccess/respondFail` 是 public 方法，内部调 `transport.send()`。iOS 的 `sendViaTransport` 是其等价物——让 JsBridge 能在不持有 transport 引用的前提下发送响应。

### 4.6 JsBridge 变更：新增 `bindTransport`

```swift
// JsBridge.swift — 新增

/// 绑定 transport 入站回调，形成闭环：
/// transport 收到 JS 消息 → 策略检查 → 分发 → 响应自动通过 transport 发回。
///
/// 前置条件：
/// 1. 已通过构造函数或 attachTransport 注入 transport。
/// 2. 已注入 PageContextProvider（Level 2 必需；未注入时 processIncomingResponses 会 preconditionFailure）。
///
/// 幂等：重复调用仅更新回调引用。
public func bindTransport() {
    core.bindTransportListener { [weak self] messageJson in
        guard let self else { return }
        let responses = self.processIncomingResponses(messageJson: messageJson)
        for response in responses {
            _ = self.core.sendViaTransport(response)
        }
    }
}
```

```swift
// CoreBridge.swift — 新增（internal，不暴露给外部消费者）

internal func bindTransportListener(_ listener: @escaping (String) -> Void) {
    transport?.bind(listener)
}
```

### 4.7 消费者集成对比

```swift
// ════════ 之前：50+ 行管道代码 ════════
// WebViewContainer.swift: bootstrap script (10行) + addUserScript (3行) + add(handler) (1行)
// BridgeHost.swift: WKScriptMessageHandler conformance (1行) + attachTransport (3行)
//   + userContentController didReceive (20行) + sendToWeb (3行) + jsonStringLiteral (4行)
//   + WebViewOutboundTransport 私有类 (8行)

// ════════ 之后：4 行 ════════
let transport = WKWebViewBridgeTransport(webView: webView)
let bridge = JsBridge(securityConfig: config, pageContextProvider: provider, transport: transport)
bridge.bindTransport()
bridge.resetForNewPage()
```

## 5. Flutter 详细设计

### 5.1 CoreBridge 变更

```dart
// core_bridge.dart — 新增

/// 通过已绑定的 transport 发送预构建的 JSON 字符串。
Future<bool> sendViaTransport(String messageJson) async {
  final BridgeTransport? transport = _transport;
  if (transport == null) {
    _sendFailureCount += 1;
    return false;
  }
  try {
    final bool sent = await transport(messageJson);
    if (!sent) {
      _sendFailureCount += 1;
    }
    return sent;
  } catch (_) {
    _sendFailureCount += 1;
    return false;
  }
}
```

### 5.2 JsBridge 变更

```dart
// js_bridge.dart — 新增

/// 绑定入站消息处理闭环，返回一个可传给 JavaScriptChannel.onMessageReceived 的回调。
/// 调用前须先 attachTransport。
/// 幂等：每次调用返回新的 handler，内部引用最新的 transport。
Future<void> Function(String) bindTransport() {
  return (String messageJson) async {
    final List<String> responses =
        await processIncomingResponses(messageJson: messageJson);
    for (final String response in responses) {
      await _core.sendViaTransport(response);
    }
  };
}
```

### 5.3 消费者集成对比

```dart
// ════════ 之前：15 行管道代码 ════════
bridge.attachTransport((String messageJson) async {
  await _sendToWeb(messageJson);  // 3 行
  return true;
});
..addJavaScriptChannel('NativeBridge',
    onMessageReceived: (msg) => unawaited(_handleIncoming(msg.message)));
// _handleIncoming: 10 行
// _sendToWeb: 3 行

// ════════ 之后：6 行 ════════
bridge.attachTransport((String messageJson) async {
  final escaped = jsonEncode(messageJson);
  await webViewController.runJavaScript(
    'window.__bridgeReceiveFromNative && window.__bridgeReceiveFromNative($escaped)');
  return true;
});
final onIncoming = bridge.bindTransport();
webViewController.addJavaScriptChannel('NativeBridge',
  onMessageReceived: (msg) => unawaited(onIncoming(msg.message)));
```

> **残留 3 行 transport lambda** 是不可避免的：Flutter core 是纯 Dart 包，不能依赖 `webview_flutter`。这 3 行是"调用平台 API"的最低限度，不属于管道逻辑。

## 6. HarmonyOS 详细设计

### 6.1 CoreBridge 变更

```typescript
// CoreBridge.ets — 新增

async sendViaTransport(messageJson: string): Promise<boolean> {
  if (this.transport === null) {
    this.sendFailures += 1;
    return false;
  }
  try {
    const sent = await this.transport(messageJson);
    if (!sent) this.sendFailures += 1;
    return sent;
  } catch (e) {
    this.sendFailures += 1;
    return false;
  }
}
```

### 6.2 JsBridge 变更

```typescript
// JsBridge.ets — 新增

/// 绑定入站消息处理闭环，返回一个可传给 NativeBridgeProxy 的处理函数。
/// 与 Flutter bindTransport() 语义一致：调用一次获得 handler，后续逐条调 handler(msg)。
/// 前置条件：已注入 transport + PageContextProvider。
bindTransport(): (messageJson: string) => Promise<void> {
  return async (messageJson: string) => {
    const responses = await this.processIncomingResponsesFromProvider(messageJson);
    for (const response of responses) {
      await this.core.sendViaTransport(response);
    }
  };
}
```

实际用法：

```typescript
// HarmonyOS 消费者
class NativeBridgeProxy {
  constructor(private readonly onMessage: (msg: string) => void) {}
  postMessage(msg: string): void { this.onMessage(msg); }
}

private onIncoming = this.bridge.bindTransport();
private nativeBridge = new NativeBridgeProxy((msg) => void this.onIncoming(msg));
```

### 6.3 消费者集成对比

```typescript
// ════════ 之前：12 行管道代码 ════════
// NativeBridgeProxy 类 (8行) + handleMessageFromWeb (5行) + sendToWeb (5行)
// + javaScriptProxy 注册 (4行) + transport lambda (1行)

// ════════ 之后：5 行 ════════
private onIncoming = this.bridge.bindTransport();
private nativeBridge = new NativeBridgeProxy((msg) => void this.onIncoming(msg));
// bridge 构造时 transport: (msg) => this.sendToWeb(msg)
// sendToWeb: 3 行（runJavaScript 调用）
// .javaScriptProxy({ object: this.nativeBridge, name: 'NativeBridge', methodList: ['postMessage'], ... })
```

> **残留**：`NativeBridgeProxy` 类和 `sendToWeb` 不可避免——ArkTS 的 `javaScriptProxy` 要求注册对象方法，且 core 不能依赖 `@kit.ArkWeb`。

## 7. 命名统一

| 维度 | 之前 | 之后 | 理由 |
|------|------|------|------|
| iOS message handler 名 | `nativeBridge`（camelCase） | `NativeBridge`（PascalCase） | 与 Flutter/HM 一致，与 `native-transport.ts` 检测路径匹配 |
| iOS bootstrap script | 消费者手写在 `WebViewContainer` | `WKWebViewBridgeTransport` 内部注入 | 消费者不可见 |
| `window.__bridgeReceiveFromNative` | 消费者手写在 `sendToWeb` | transport 内部使用 | 消费者不可见 |

命名统一后，`native-transport.ts` 的检测路径将从第 4 优先级（`$__native__.callNativeApi` fallback）提升到第 2 优先级（`webkit.messageHandlers.NativeBridge` 直接命中），消除 fallback 依赖。

## 8. 不涉及的范围

| 不改 | 理由 |
|------|------|
| Android `resetTransport()` | 已存在且工作正常 |
| Android `AndroidWebViewBridgeTransport` | 已存在于 `extensions/system/` |
| `BridgeTransport` protocol/interface/typedef 定义 | 不改签名，只新增具体实现 |
| `native-transport.ts` | 无需改动——已支持 `NativeBridge` 路径 |
| `processIncomingResponses` 系列 | 保留——高级消费者仍可手动调用 |
| `dispatch()` 返回值语义 | 不改为 void——保留灵活性 |

## 9. 测试策略

### 9.1 iOS BridgeSystemTests

| 用例 | 验证点 |
|------|--------|
| `test_transport_send_callsEvaluateJavaScript` | `send()` 调用 `evaluateJavaScript`，JS 字符串包含 `__bridgeReceiveFromNative` |
| `test_transport_bind_receivesScriptMessage` | `bind()` 后，模拟 `WKScriptMessage` 回调，listener 收到字符串 |
| `test_transport_normalizeBody_string` | `body` 为 String 时直接传递 |
| `test_transport_normalizeBody_dictionary` | `body` 为 `[String: Any]` 时 JSON 序列化 |
| `test_transport_normalizeBody_unsupported` | `body` 为 Int/Bool 时返回 nil，不崩溃 |
| `test_transport_close_removesHandler` | `close()` 后 UCC 不再持有 transport |
| `test_transport_messageName_default` | 默认为 "NativeBridge" |
| `test_jsBridge_bindTransport_fullRoundtrip` | transport 收到消息 → processIncomingResponses → response 通过 transport.send 发回 |

> WKWebView 测试使用 `XCTestCase` + mock；不依赖真实 WebView 渲染。

### 9.2 Flutter / HM

| 用例 | 验证点 |
|------|--------|
| `bindTransport_returnsHandler` | 返回值是函数，调用后触发 processIncomingResponses + sendViaTransport |
| `sendViaTransport_nullTransport` | transport 为空时返回 false，自增 sendFailureCount |
| `sendViaTransport_success` | transport 函数被调用，参数为 response JSON |
| `bindTransport_multipleResponses` | 多条 response 逐条发送 |

### 9.3 Conformance

现有 C01–C30 无需修改——本次变更不触及协议层。`bindTransport` 是平台便利层，不属于协议一致性范围，不新增 Conformance 用例。闭环行为由各平台独立测试覆盖（§9.1、§9.2）。

## 10. 破坏性变更分析

| 变更 | 破坏性 | 分析 |
|------|--------|------|
| iOS 新增 `BridgeSystem` target | 否 | 纯新增 target + product，不影响 `BridgeCore` |
| iOS `CoreBridge.sendViaTransport()` | 否 | 纯新增 public 方法 |
| iOS `CoreBridge.bindTransportListener()` | 否 | `internal` 方法，模块内可见 |
| iOS `JsBridge.bindTransport()` | 否 | 纯新增 public 方法 |
| Flutter `CoreBridge.sendViaTransport()` | 否 | 纯新增方法 |
| Flutter `JsBridge.bindTransport()` | 否 | 纯新增方法 |
| HM `CoreBridge.sendViaTransport()` | 否 | 纯新增方法 |
| HM `JsBridge.bindTransport()` | 否 | 纯新增方法 |
| Example app 简化 | 不涉及库 | Example 代码变更不影响库消费者 |

**结论：零破坏性变更。** 所有改动都是新增 API，现有代码无需修改即可继续工作。

## 11. 实施顺序

```
1. iOS: Package.swift 新增 BridgeSystem target
2. iOS: CoreBridge.swift 新增 sendViaTransport + bindTransportListener
3. iOS: JsBridge.swift 新增 bindTransport
4. iOS: WKWebViewBridgeTransport.swift 新建
5. iOS: BridgeSystemTests 新建
6. iOS: Example 简化 (BridgeHost + WebViewContainer)
7. iOS: swift test 通过

8. Flutter: core_bridge.dart 新增 sendViaTransport
9. Flutter: js_bridge.dart 新增 bindTransport
10. Flutter: flutter test 通过
11. Flutter: Example 简化

12. HM: CoreBridge.ets 新增 sendViaTransport
13. HM: JsBridge.ets 新增 bindTransport
14. HM: Example 简化

15. 文档更新: docs/02-architecture.md §6, docs/05-review.md, docs/03-cross-platform.md
16. 各平台 bindTransport 闭环测试
```
