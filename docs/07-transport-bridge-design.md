# 07 Transport 抽象与平台适配

> 更新日期：2026-09  
> 适用平台：Android · iOS · Flutter · HarmonyOS

本文档说明 Transport 抽象层的设计与各平台适配器实现。

**关于信道建立机制**：信道建立的 pull 模型、reqId 往返、端口轮换等内容已迁移至 [06-channel-establishment.md](06-channel-establishment.md)。本文聚焦于 Transport 接口设计与平台适配。

---

## 1. 目标

消除 iOS / Flutter / HarmonyOS 三端集成方被迫手写的 50+ 行管道代码（bootstrap script、消息路由循环、`evaluateJavaScript` 调用、字符串转义），使集成代码量向 Android（4 行）对齐。

**核心约束**：
- Core 层零平台导入（iOS `BridgeCore` target 不得 `import WebKit`）
- Transport 收敛到字符串边界（签名中不得出现平台类型）
- 渐进增强（不传 transport 仍可手动 `processIncomingResponses`）

---

## 2. Transport 抽象

### 2.1 接口定义

四端统一收敛到字符串边界：

```java
// Android
interface BridgeTransport {
    void bind(Listener listener);
    boolean send(String messageJson);
    void close();
    
    interface Listener {
        void onMessage(String messageJson);
    }
}
```

```swift
// iOS
protocol BridgeTransport: AnyObject {
    func bind(listener: @escaping (String) -> Void)
    func send(_ messageJson: String) -> Bool
    func close()
}
```

```dart
// Flutter
typedef BridgeTransport = FutureOr<bool> Function(String messageJson);
// transport 为宿主注入的函数（构造期 attach），无独立 adapter 类型；
// 入站 listener 形态由 bindTransport() 返回的入站处理闭包承担（见 §3.2），无独立命名的 listener 类型
```

```typescript
// HarmonyOS（ArkTS）
type BridgeTransport = (messageJson: string) => boolean | Promise<boolean>;
// transport 为宿主注入的函数，构造期经 JsBridgeOptions.transport 注入；
// 入站 listener 形态同样由 bindTransport() 返回的闭包承担（见 §3.3），无独立命名的 listener 类型
```

> Android 与 iOS 的 `bind(listener)` 形态用于建立「transport → core listener」的入站接线；
> Flutter / HarmonyOS 的等价接线由 `bindTransport()` 闭包完成（见 [02-architecture.md §6.3](02-architecture.md)），四种形态收敛到同一字符串边界。

### 2.2 集成前后对比

**iOS（从 ~50 行降至 ~5 行）**

集成前（手写管道，示意）：
```swift
// 手写 bootstrap script（实际注入的入口是 callNativeApi）
let bootstrapScript = """
  (function() {
    if (!window.__jsbridge2__) { window.__jsbridge2__ = {}; }
    window.__jsbridge2__.callNativeApi = function(msg) {
      window.webkit.messageHandlers.NativeBridge.postMessage(String(msg));
    };
  })();
"""
webView.configuration.userContentController.addUserScript(
  WKUserScript(source: bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

// 手写消息路由循环
webView.configuration.userContentController.add(self, name: "NativeBridge")

func userContentController(_ controller: WKUserContentController, 
                          didReceive message: WKScriptMessage) {
  guard message.frameInfo.isMainFrame else { return }   // 主 frame 门控也要手写
  guard let messageString = message.body as? String else { return }
  _ = bridge.processIncomingResponses(messageJson: messageString)  // origin 只能来自构造期注入的 PageContextProvider
}

// 手写出站发送
func sendMessage(_ json: String) {
  let escaped = json.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"")
  let script = "window.__jsbridge2__.receive('\(escaped)')"
  webView.evaluateJavaScript(script)
}
```

集成后：
```swift
import BridgeCore
import BridgeSystem

let transport = WKWebViewBridgeTransport(webView: webView)
let bridge = JsBridge(securityConfig: config, pageContextProvider: provider, transport: transport)
bridge.bindTransport()
bridge.resetPageInstance()
```

---

## 3. 平台适配器实现

### 3.1 iOS: WKWebViewBridgeTransport

**模块结构**：新增 `BridgeSystem` target（持有 `WebKit` 导入）

```
Sources/
├── Bridge/              (BridgeCore target，零平台导入)
│   ├── Core/
│   ├── Security/
│   ├── Extensions/      (LifecycleExtension.swift 等)
│   └── Api/
└── BridgeSystem/        (BridgeSystem target，可导入 WebKit)
    └── WKWebViewBridgeTransport.swift
```

> **Swift 模块粒度注记**：security 组件位于 `BridgeCore` target 内（Swift Package 单 target 目录形态所限），transport（`BridgeSystem`）经 `import BridgeCore` 与 security 同处一个**模块级**依赖闭包。本文档的"transport 与 security 互不引用"约束在 Swift 侧按**符号级**执行：`WKWebViewBridgeTransport` 不引用任何 Policy/Session/PageContextProvider 符号，`BridgeCore` 本身零 `import WebKit`——约束实质成立，模块切分粒度属平台固有形态、非违规。

**职责封装**：
- 入站：实现 `WKScriptMessageHandler`，自动转换消息体类型；**主 frame 门控**——`didReceive` 必须校验 `message.frameInfo.isMainFrame`，非主 frame（WebView 内嵌 iframe）的消息一律丢弃，防止 iframe 借主 frame 的可信 origin 越过 OriginPolicy（契约见 docs/03 §9 细则 5 建链信任边界；instrumented 落点 C58）；bootstrap 脚本以 `forMainFrameOnly: true` 注入，iframe 中不出现 bridge 入口
- 出站：封装 `evaluateJavaScript` + 字符串转义
- Bootstrap：自动注入占位对象（`window.__jsbridge2__.callNativeApi` → `window.webkit.messageHandlers.<messageName>.postMessage(String(...))`）

**消费者代码**（~5 行）：
```swift
import BridgeCore
import BridgeSystem

let transport = WKWebViewBridgeTransport(webView: webView)
let bridge = JsBridge(securityConfig: config, pageContextProvider: provider, transport: transport)
bridge.bindTransport()
bridge.resetPageInstance()
```

> **`messageName` 自定义参数的实际边界**：默认 `"NativeBridge"` 与 JS SDK 的检测路径（`window.webkit.messageHandlers.NativeBridge`）一致；JS SDK 硬编码按该名探测，宿主改名会破坏默认建链——该 init 参数仅供测试注入使用，生产宿主不应改名。

### 3.2 Flutter: 宿主注入函数（webview_flutter）

Flutter 端使用 `webview_flutter`，transport 是宿主注入的函数，无需独立适配器文件——入站走 `addJavaScriptChannel`，出站走 `runJavaScript`。

**集成代码**（实然形态，参考 `js_bridge_flutter/lib/src/webview/flutter_bridge_controller.dart`）：
```dart
final bridge = JsBridge(securityConfig: SecurityConfig(...));          // 构造期注入安全配置
bridge.attachPageContextProvider(_WebviewPageContextProvider(...));    // origin 经内核 OriginNormalizer 派生
bridge.attachTransport((String messageJson) async {                   // 出站：注入函数
  try {
    await webViewController.runJavaScript(
      'window.__jsbridge2__ && window.__jsbridge2__.receive && '
      'window.__jsbridge2__.receive(${jsonEncode(messageJson)})',
    );
    return true;
  } catch (_) {
    return false;    // 吞异常后显式返回 false（异常不逃逸），false 即宿主侧 send 失败的可观测出口
  }
});

final onIncoming = bridge.bindTransport();                             // 入站处理闭包
webViewController = WebViewController()
  ..setJavaScriptMode(JavaScriptMode.unrestricted)
  ..addJavaScriptChannel(
    'NativeBridge',                                                    // JS SDK 检测的常驻通道名
    onMessageReceived: (JavaScriptMessage message) {
      unawaited(onIncoming(message.message));
    },
  );
```

### 3.3 HarmonyOS: 宿主注入函数（ArkWeb javaScriptProxy）

HarmonyOS `Web` 组件提供 `javaScriptProxy` 注入机制；transport 为函数类型，构造期经 `JsBridgeOptions.transport` 注入。

**集成代码**（实然形态，参考 `js_bridge_harmony/js-bridge-example/.../pages/Index.ets`）：
```typescript
const onIncoming = bridge.bindTransport();    // 无参，返回入站处理闭包（fail-fast：provider 缺失在绑定期即抛错）

Web({ src: url, controller: this.controller })
  .javaScriptProxy({
    object: {
      postMessage: (json: string) => { onIncoming(json); },   // void 回调，纯异步入站
    },
    name: 'NativeBridge',                                     // JS SDK 检测的常驻通道名
    methodList: ['postMessage'],
  });

// 出站 transport（构造期注入，实码为 sendToWeb）——try/catch 捕获
// runJavaScript 异常后显式 return false，异常不逃逸（与 §4.4 定性一致）：
// （json: string）=> {
//   const script = `window.__jsbridge2__ && window.__jsbridge2__.receive &&
//     window.__jsbridge2__.receive(${JSON.stringify(json)})`;
//   try {
//     this.controller.runJavaScript(script);
//     return true;
//   } catch (e) {
//     return false;
//   }
// }
```

### 3.4 Android: AndroidWebViewBridgeTransport（参考实现）

Android 端在 extensions/system 提供 `AndroidWebViewBridgeTransport`（实现 `BridgeTransport` 的 bind/send/close 三件套，另注入 pull 建链哑入口）。

**集成代码**（实然形态）：
```java
AndroidWebViewBridgeTransport transport = new AndroidWebViewBridgeTransport(webView);
JsBridge bridge = new JsBridge(transport, provider, securityConfig);        // 三参构造，无 Builder
bridge.resetTransport();     // 无参：建立入站闭环（bind + 暂存队列补投）。哑入口 requestBridgeChannel 随 transport 构造注入（早于 loadUrl），不随 bind/resetTransport
bridge.resetPageInstance();  // 无参：页面导航回调中轮换 pageInstanceId
```

---

## 4. 使用方关注要点

### 4.1 何时需要 Transport

| 场景 | 是否需要 | 原因 |
|------|---------|------|
| WebView 容器内正常集成 | ✅ 需要 | 提供自动管道，4–6 行完成集成 |
| 单测（不涉及 WebView） | ❌ 不需要 | 直接调用 `processIncomingResponses(messageJson)`（origin/context 注入形态为测试面：Dart 用 `@visibleForTesting` 收敛、Swift 为 internal + `@testable`、ArkTS 公开但仅限测试注入——均经 OriginNormalizer 归一化，不得作生产旁路） |
| 离线调试（Mock 响应） | ❌ 不需要 | 手动注入 Mock 响应 |

### 4.2 Transport 的职责边界

**Transport 负责**：
- 字符串收发管道（入站 + 出站）
- 平台 API 封装（`evaluateJavaScript` 等）
- Bootstrap script 注入（JS 侧占位对象）

**Transport 不负责**：
- 信道建立（由 `native-transport.ts` + pull 模型完成，见 [06-channel-establishment.md](06-channel-establishment.md)）
- 消息序列化/反序列化（由 `CoreBridge` 完成）
- 安全策略（由 `PolicyEngine` 完成）

### 4.3 故障排查

| 症状 | 可能原因 | 排查方法 |
|------|---------|---------|
| `bridge.send()` 返回 false | 发送通道不可用 | Android：现代路径为「无 channel」（pull 建链前的常态，见 [06-channel-establishment.md](06-channel-establishment.md)）或 send 捕获 WebView 异常；`resetTransport()` 只建入站闭环、不建通道。iOS：transport 未注册或 webView 为 nil（构造期决定）。Flutter/HarmonyOS：transport 未 attach 或注入函数自行返回 false |
| 控制台报 `__jsbridge2__ is not defined` | Bootstrap 未注入 | iOS 检查 `WKWebViewBridgeTransport` 初始化时机；Flutter/HarmonyOS 检查 SDK bundle 加载次序（`__jsbridge2__.receive` 由 SDK 挂载） |
| 消息发出但 Native 无响应 | 入站 listener 未接线 | 确认建链闭环已完成：Android `resetTransport()` / iOS·Flutter·HarmonyOS `bindTransport()`——listener 由 core 在闭环内自动绑到 transport |

### 4.4 send() 的语义与失败可观测性

**返回值语义（四端统一）**：`send(messageJson)` 的返回值表示「**已接受投递**」（已移交平台发送通道），不表示「已送达 JS」——系统级发送 API 均为 fire-and-forget（`postMessage` 返回 `void`、`runJavaScript` 不回传 JS 结果、`evaluateJavaScript` 的错误是延迟回调），同步 `Bool` 契约在结构上无法表达「送达」。

**各端 `false` 的触发集不一致**——send 失败的公共可观测出口为 `postEvent` 返回 `false`（C17）；Native 侧内部失败计数不作为跨端可比指标公开：

| 平台 | transport 归属 | `false` 触发条件 | 异步失败观察 |
|------|---------------|-----------------|--------------|
| iOS | 框架（`WKWebViewBridgeTransport`） | 未注册 / webView 为 nil | 无（`evaluateJavaScript` 延迟错误不外露——零读者观测面已收敛；send 失败的可观测出口为 `postEvent` 返回 `false`，见 C17） |
| Android | 框架（`AndroidWebViewBridgeTransport`） | 无 channel（现代路径）；send 捕获 WebView 异常后显式返回 false（legacy 路径同款吞异常） | 无（`postMessage` 为 `void`） |
| Flutter | 宿主注入函数（示例 `flutter_bridge_controller.dart`） | 宿主自定（示例为 try/catch 捕获注入调用异常后显式 `return false`，异常不逃逸） | 无（`runJavaScript` 不上报 JS 错误） |
| HarmonyOS | 宿主注入函数（示例 `Index.ets`） | 宿主自定（示例为 try/catch 捕获 `runJavaScript` 异常后显式 `return false`，异常不逃逸） | 无 |

**已知边界——「receiver 未挂载」不可观测**：iOS / Flutter / HarmonyOS 与 Android legacy 路径的出站注入表达式同形 `__jsbridge2__ && __jsbridge2__.receive && __jsbridge2__.receive(...)`，receiver 未挂载时表达式求值为 `undefined`、不产生任何异常，与成功不可区分。Android 现代路径（API ≥ M）不执行 JS 表达式——经 `WebMessagePort.postMessage` 直接出站，发送通道未就绪时由 transport 显式返回 false。任何基于回调错误的观测都覆盖不了「表达式求值为 undefined」这一分支；排查「JS 侧是否就绪」依赖握手 / lifecycle 信号，而非发送链。

**JS 侧的对偶行为**：入站消息 reqId 可关联但被放弃（kind 未知 / 信封不可处理）→ `CoreBridgeClient` **立即**以 `E_INTERNAL` 快速失败其关联请求，而非放任其等待超时后伪装成 `E_TIMEOUT`（用例 C50，[09-conformance.md](09-conformance.md) §3）；字节级不可解析的消息结构上无法关联，维持丢弃、诊断日志为 `console.error`。

---

## 5. 与其他文档的关系

- **信道建立机制**：[06-channel-establishment.md](06-channel-establishment.md) — pull 模型、reqId 往返、端口轮换
- **生命周期模型**：[05-lifecycle-layers.md](05-lifecycle-layers.md) — Transport 属于 Layer 1
- **跨平台契约**：[04-cross-platform.md](04-cross-platform.md) — Transport 接口四端签名对齐
- **设计原则**：[01-design-principles.md](01-design-principles.md) — Transport 抽象验证平台无关性

---

## 附：实施入口速查

| 平台 | Transport 形态 | 实现文件 / 集成指南 |
|------|---------------|-------------------|
| Android | `BridgeTransport` 接口（bind / send / close）+ pull 哑入口 | `extensions/system/AndroidWebViewBridgeTransport`；[js_bridge_android/README.md](../js_bridge_android/README.md) |
| iOS | `BridgeTransport` 协议 + `WKWebViewBridgeTransport` 适配器（BridgeSystem target） | [js_bridge_ios/README.md](../js_bridge_ios/README.md) |
| Flutter | 宿主注入函数（webview_flutter `addJavaScriptChannel` 入站 / `runJavaScript` 出站） | [js_bridge_flutter/README.md](../js_bridge_flutter/README.md) |
| HarmonyOS | 宿主注入函数（ArkWeb `javaScriptProxy` 入站 / `runJavaScript` 出站） | [js_bridge_harmony/README.md](../js_bridge_harmony/README.md) |

信道建立的 pull 模型与 reqId 往返见 [06-channel-establishment.md](06-channel-establishment.md)。

