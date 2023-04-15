# Flutter

Flutter 平台 JsBridge 实现，Dart，基于 `webview_flutter`。

## 模块

| 模块 | 说明 |
|------|------|
| `packages/js_bridge_core` | Dart 核心包：CoreBridge、JsBridge、PolicyEngine、SessionService |
| `js_bridge_flutter`（根） | 示例 App：演示完整集成流程 |

## 快速开始

```bash
cd js_bridge_flutter/packages/js_bridge_core && flutter test
cd ../.. && flutter test && flutter analyze
flutter run
```

## 集成教程

> 内核分为两层，递进使用：
> - **CoreBridge**（Tier 1）— 纯消息分发，零安全依赖。适合可信本地页面、原型开发。
> - **JsBridge**（Tier 2）— 叠加在 CoreBridge 之上，增加握手、策略链、会话管理。适合生产环境。

### 1. 添加依赖

MVP 阶段从源码引用：

```yaml
# pubspec.yaml
dependencies:
  js_bridge_core:
    path: ../js_bridge_flutter/packages/js_bridge_core
  webview_flutter: ^4.0.0
```

> 发布后可改为 `js_bridge_core: ^0.1.0`

---

## 第一部分：CoreBridge

CoreBridge 是 Tier 1 核心协议层，只做三件事：注册 handler、分发消息、构建响应/事件。它不感知安全策略、会话、握手——这些全部由上层 JsBridge 负责。

### 1.1 创建 CoreBridge

CoreBridge 可不传 transport（后续通过 `attachTransport` 注入）：

```dart
import 'package:js_bridge_core/js_bridge_core.dart';

final core = CoreBridge();
```

### 1.2 注册 Handler

CoreBridge 支持同步 handler 和流式 handler（返回多帧）：

```dart
// 同步 handler
core.registerHandler('getUser', (dynamic payload) async {
  final object = payload as Map?;
  final userId = object?['userId'] as String?;
  if (userId == '001') {
    return const BridgeHandlerResult.success({'name': 'xesam'});
  }
  return BridgeHandlerResult.failure(
    BridgeError(code: 'E_NOT_FOUND', message: 'user not found'),
  );
});

// 流式 handler（返回多帧）
core.registerStreamingHandler('timerLog', (dynamic payload) async {
  return <BridgeHandlerResult>[
    const BridgeHandlerResult.success(
      {'event': 'tick', 'value': 42, 'seq': 1},
      done: false,
    ),
    const BridgeHandlerResult.success(
      {'event': 'stopped', 'running': false},
    ),
  ];
});
```

### 1.3 主动推送事件

```dart
// 向 JS 侧推送事件（kind=event），无需等待请求
await core.postEvent(method: 'runtime.state', payload: {'state': 'resumed'});
```

### 1.4 消息分发

CoreBridge 的 `dispatch` 接收 `BridgeMessage` + `TrustedPageContext`，返回响应 JSON 字符串列表：

```dart
final responses = await core.dispatch(request, TrustedPageContext(
  origin: 'flutter-asset://',
  pageInstanceId: 'page-1',
));
for (final response in responses) {
  sendToWeb(response);
}
```

### 1.5 独立使用场景

当页面完全可信（如本地 `flutter-asset://` 页面）、无需安全校验时，CoreBridge 可独立使用。只需自行接收 JS 消息并调用 `dispatch`：

```dart
final core = CoreBridge();
core.registerHandler('getUser', (dynamic payload) async {
  return const BridgeHandlerResult.success({'name': 'xesam'});
});

// 绑定 transport：Native → JS 方向
core.attachTransport((String messageJson) async {
  final escaped = jsonEncode(messageJson);
  await webViewController.runJavaScript(
    'window.__bridgeReceiveFromNative && window.__bridgeReceiveFromNative($escaped)',
  );
  return true;
});

// 在 JS channel 回调中手动分发
void _handleIncoming(String messageJson) async {
  final request = BridgeMessage.fromJsonString(messageJson);
  final context = TrustedPageContext(origin: 'flutter-asset://', pageInstanceId: 'page-1');
  final responses = await core.dispatch(request, context);
  for (final response in responses) {
    final escaped = jsonEncode(response);
    await webViewController.runJavaScript(
      'window.__bridgeReceiveFromNative && window.__bridgeReceiveFromNative($escaped)',
    );
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
| **0** | `SecurityConfig()` | 仅校验消息结构，无需握手 |
| **1** | `SecurityConfig().withHandshakeGate()` | 需握手，不校验 origin |
| **2** | `SecurityConfig.secure()` | 握手 + origin 白名单 + 方法白名单（生产推荐） |

### 2.2 创建 JsBridge

```dart
import 'package:js_bridge_core/js_bridge_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

// Level 0 — 开发/测试
final bridge = JsBridge(securityConfig: SecurityConfig());

// Level 2 — 生产环境
final secureBridge = JsBridge(
  securityConfig: SecurityConfig.secure()
    ..allowedOrigins = {'file://', 'flutter-asset://', 'about:blank'}
    ..methodWhitelist = {
      'bridge.handshake',
      'getUser',
      'getCurrentLocation',
    }
    ..defaultCapabilities = {
      'getUser',
      'getCurrentLocation',
    },
);
```

### 2.3 配置 PageContextProvider

从 WebView 当前 URL 提取 origin：

```dart
class WebviewPageContextProvider implements PageContextProvider {
  WebviewPageContextProvider(this._currentUrlGetter);
  final String Function() _currentUrlGetter;

  @override
  TrustedPageContext createContext(BridgeMessage message, String pageInstanceId) {
    return TrustedPageContext(
      origin: _normalizeOrigin(_currentUrlGetter()),
      pageInstanceId: pageInstanceId,
    );
  }

  static String _normalizeOrigin(String rawUrl) {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) return 'about:blank';
    if (uri.scheme == 'file') return 'file://';
    if (uri.scheme.startsWith('flutter')) return '${uri.scheme}://';
    if (uri.scheme == 'about') return 'about:blank';
    return '${uri.scheme}://${uri.host}';
  }
}
```

### 2.4 绑定 Transport 和 WebViewController

```dart
String _currentUrl = 'about:blank';

// 绑定 transport（Native → JS 方向）
bridge.attachTransport((String messageJson) async {
  final escaped = jsonEncode(messageJson);
  await webViewController.runJavaScript(
    'window.__bridgeReceiveFromNative && window.__bridgeReceiveFromNative($escaped)',
  );
  return true;
});

// 绑定 PageContextProvider
bridge.attachPageContextProvider(
  WebviewPageContextProvider(() => _currentUrl),
);

// 建立入站闭环：bindTransport() 返回的回调传给 JavaScriptChannel
// JS 发送消息 → onIncoming → processIncomingResponses → 响应自动通过 transport 发回
final onIncoming = bridge.bindTransport();

webViewController = WebViewController()
  ..setJavaScriptMode(JavaScriptMode.unrestricted)
  ..addJavaScriptChannel(
    'NativeBridge',
    onMessageReceived: (JavaScriptMessage message) {
      onIncoming(message.message);
    },
  )
  ..setNavigationDelegate(
    NavigationDelegate(
      onPageStarted: (String url) {
        _currentUrl = url;
        bridge.resetForNewPage();
      },
      onPageFinished: (String url) {
        _currentUrl = url;
      },
    ),
  );
```

> `bindTransport()` 返回一个 `Future<void> Function(String)` 回调，内部自动串联 `processIncomingResponses` → `sendViaTransport` 闭环。无需手动处理消息路由和响应发送。

### 2.5 注册 Handler

JsBridge 委托 CoreBridge 注册 handler，同时支持流式 handler：

```dart
// 同步 handler（委托 CoreBridge）
bridge.registerHandler('getUser', (dynamic payload) async {
  final object = _asMap(payload);
  final userId = object['userId'] as String?;
  if (userId == '001') {
    return const BridgeHandlerResult.success({'name': 'xesam'});
  }
  return BridgeHandlerResult.failure(
    BridgeError(code: 'E_NOT_FOUND', message: 'user not found'),
  );
});

// 流式 handler（返回多帧）
bridge.registerStreamingHandler('timerLog', (dynamic payload) async {
  return <BridgeHandlerResult>[
    const BridgeHandlerResult.success(
      {'event': 'tick', 'value': 42, 'seq': 1},
      done: false,
    ),
    const BridgeHandlerResult.success(
      {'event': 'stopped', 'running': false},
    ),
  ];
});
```

### 2.6 生命周期事件推送（可选）

```dart
import 'package:flutter/widgets.dart';

final lifecycleExtension = LifecycleExtension(bridge);

// 监听 App 生命周期
class _MyApp extends StatefulWidget { ... }
class _MyAppState extends State<_MyApp> with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final mapped = switch (state) {
      AppLifecycleState.resumed  => 'resumed',
      AppLifecycleState.inactive => 'paused',
      AppLifecycleState.hidden   => 'stopped',
      AppLifecycleState.paused   => 'stopped',
      AppLifecycleState.detached => 'destroyed',
    };
    lifecycleExtension.onHostEvent(mapped);
  }
}
```

> 握手完成前的事件会排队缓存（上限 32），握手成功后按序补发。

### 2.7 加载页面

```dart
// 确保 WebAssets 已通过 `pnpm sync` 同步到 assets/web/
await webViewController.loadFlutterAsset('assets/web/index.html');
```

## WebAssets

`assets/web/` 不纳入版本管理，从根目录 `web-assets/` 同步：

```bash
cd web-assets && pnpm sync
```
