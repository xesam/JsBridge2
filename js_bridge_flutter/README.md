# Flutter

Flutter 平台 JsBridge 实现，Dart，基于 `webview_flutter`。

> 消息模型为纯异步（协议 v1 不支持同步调用，所有结果以独立 response/event 消息回传，详见 [docs/03-protocol.md §1 消息模型](../docs/03-protocol.md)）。Flutter 的 `JavaScriptChannel` 为 `void postMessage` 形态，无同步返回。

## 模块

| 模块 | 说明 |
|------|------|
| `packages/js_bridge_core` | Dart 核心包：CoreBridge、JsBridge、PolicyEngine、SessionService |
| `js_bridge_flutter`（根） | 示例 App：演示完整集成流程 |

## 快速开始

```bash
cd js_bridge_flutter/packages/js_bridge_core && flutter test
cd ../.. && flutter analyze
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
    # 仓库内宿主 App（js_bridge_flutter/pubspec.yaml）直接引用本地包：
    path: packages/js_bridge_core
    # 外部项目请克隆本仓库后按相对路径引用，或发布后改为：
    # js_bridge_core: ^0.0.1
  webview_flutter: ^4.10.0
```

> 发布后可改为 `js_bridge_core: ^0.0.1`

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

CoreBridge 提供两个注册入口：`registerSimpleHandler`（单帧响应）与 `registerAsyncHandler`（多帧响应）。
两者的 page context（`TrustedPageContext`）均为**第一形参**。Simple handler 恒为单帧（`done=true`），
多帧只能由 Async handler 通过 `ResponseEmitter` 表达。同一 method 重复注册时**后者覆盖前者**。

```dart
// Simple handler：单帧响应，返回即结束
core.registerSimpleHandler('getUser', (TrustedPageContext context, dynamic payload) async {
  final object = payload as Map?;
  final userId = object?['userId'] as String?;
  if (userId == '001') {
    return const BridgeHandlerResult.success({'name': 'xesam'});
  }
  return BridgeHandlerResult.failure(
    BridgeError(code: 'E_NOT_FOUND', message: 'user not found'),
  );
});

// Async handler：多帧响应，可返回后继续推帧（done=false 为非终帧，done=true 收尾）
core.registerAsyncHandler('timerLog',
    (TrustedPageContext context, dynamic payload, ResponseEmitter? emitter) async {
  if (emitter == null) return;
  await emitter(
    const Result<dynamic, BridgeError>.success({'event': 'tick', 'value': 42, 'seq': 1}),
    false,
  );
  await emitter(
    const Result<dynamic, BridgeError>.success({'event': 'stopped', 'running': false}),
    true,
  );
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
core.registerSimpleHandler('getUser', (TrustedPageContext context, dynamic payload) async {
  return const BridgeHandlerResult.success({'name': 'xesam'});
});

// 绑定 transport：Native → JS 方向
core.attachTransport((String messageJson) async {
  final escaped = jsonEncode(messageJson);
  await webViewController.runJavaScript(
    'window.__jsbridge2__ && window.__jsbridge2__.receive && window.__jsbridge2__.receive($escaped)',
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
      'window.__jsbridge2__ && window.__jsbridge2__.receive && window.__jsbridge2__.receive($escaped)',
    );
  }
}
```

> **上下文**：Flutter 无 `bind()` 自动闭环形态（该形态为 Android 特有）：standalone 使用时经 `attachTransport` 注入出站、手动调用 `dispatch`，`TrustedPageContext` 由宿主手工构造——该 origin 为**宿主自声明**（须为归一化形态，见 [docs/03-protocol.md §9 细则 5](../docs/03-protocol.md)），不是内核经 Provider 派生的可信值，信任边界不高于 null 配置（见 [docs/04-cross-platform.md §3.1](../docs/04-cross-platform.md)）；页面非完全可信时请使用 Tier 2 JsBridge。

> **局限**：CoreBridge 没有握手、没有 origin 校验、没有会话管理。任何能向 WebView 发消息的 JS 都可以调用已注册的 handler。生产环境请使用 JsBridge。

---

## 第二部分：JsBridge

JsBridge 是 Tier 2 会话/策略/握手层，叠加在 CoreBridge 之上。它拦截消息入口，为每条消息插入策略链（结构校验 → 握手门控 → 访问控制），策略通过后再委托 CoreBridge 分发。JsBridge 内部持有一个 CoreBridge 实例，handler 注册委托给 CoreBridge。

### 2.1 安全模式

`securityConfig` 参数二选一，没有中间态：

| 配置 | 行为 |
|------|------|
| `null` | 无安全检查：仅校验消息结构，无需握手 |
| `SecurityConfig` | 握手门控 + session 校验；`allowedOrigins` / `methodWhitelist` 决定两个白名单维度是否进链（`{'*'}` = 显式不限制）；`methodWhitelist` 为业务方法白名单，协议方法（`bridge.handshake` / `bridge.cancelScope`）由框架自动放行 |

> **配置校验**：传入 `SecurityConfig` 时 `allowedOrigins` 与 `methodWhitelist` 必须显式设置（不可为 `null`），否则构造期抛出 `ArgumentError`；`{'*'}` 是合法的"不限制该维度"声明。`methodWhitelist` 只需列出**业务方法**——协议方法由框架装配期自动并入放行集，无需显式写入 `bridge.handshake`。

### 2.2 创建 JsBridge

```dart
import 'package:js_bridge_core/js_bridge_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

// 无安全配置 — 开发/测试
final bridge = JsBridge(securityConfig: null);

// 传入 SecurityConfig — 生产环境
final secureBridge = JsBridge(
  securityConfig: SecurityConfig(
    allowedOrigins: <String>{'file://', 'flutter-asset://'},
    methodWhitelist: <String>{'getUser', 'getCurrentLocation'},
  ),
);
```

### 2.3 配置 PageContextProvider

从 WebView 当前 URL 派生 origin。**origin 必须经由核心包导出的 `OriginNormalizer.normalize(...)` 产生**（协议契约见 [docs/03-protocol.md §9 细则 5](../docs/03-protocol.md)：`TrustedPageContext.origin` 的唯一合法形态由内核的四端统一手写归一化算法产生——刻意不使用 `dart:core` 的 `Uri` 解析，宿主不得自写归一化，验收锚点 C54）：

```dart
class WebviewPageContextProvider implements PageContextProvider {
  WebviewPageContextProvider(this._currentUrlGetter);
  final String? Function() _currentUrlGetter;

  @override
  TrustedPageContext createContext(BridgeMessage message, String pageInstanceId) {
    return TrustedPageContext(
      origin: OriginNormalizer.normalize(_currentUrlGetter()),
      pageInstanceId: pageInstanceId,
    );
  }
}
```

> 输入为 null / 空串 / scheme 词法非法 / 非层级形态（`about:` / `data:` 等）/ 畸形端口时归一化返回空串 `''`（例：`about:blank` → `''`）——空串 origin 永远不会命中任何白名单，fail-closed。因此**不要**在 `allowedOrigins` 中写 `'about:blank'` 之类的死条目，也不要用占位值替代真实 origin。

### 2.4 绑定 Transport 和 WebViewController

```dart
String? _currentUrl;

// 绑定 transport（Native → JS 方向）
bridge.attachTransport((String messageJson) async {
  final escaped = jsonEncode(messageJson);
  await webViewController.runJavaScript(
    'window.__jsbridge2__ && window.__jsbridge2__.receive && window.__jsbridge2__.receive($escaped)',
  );
  return true;
});

// 绑定 PageContextProvider
bridge.attachPageContextProvider(
  WebviewPageContextProvider(() => _currentUrl),
);

// 建立入站闭环：bindTransport() 返回的回调传给 JavaScriptChannel
// JS 发送消息 → onIncoming（策略检查 + 核心分发）→ 响应自动通过 transport 发回
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
        bridge.resetPageInstance();
      },
      onPageFinished: (String url) {
        _currentUrl = url;
      },
    ),
  );
```

> `bindTransport()` 返回一个 `Future<void> Function(String)` 回调，内部自动串联「JS channel 消息 → 核心分发 → transport 回发」闭环。无需手动处理消息路由和响应发送。

### 2.5 注册 Handler

JsBridge 委托 CoreBridge 注册 handler，注册入口与形参形态完全一致（page context 为第一形参）；
同一 method 重复注册时后者覆盖前者。

```dart
// Simple handler（委托 CoreBridge）：单帧响应
bridge.registerSimpleHandler('getUser', (TrustedPageContext context, dynamic payload) async {
  final object = _asMap(payload);
  final userId = object['userId'] as String?;
  if (userId == '001') {
    return const BridgeHandlerResult.success({'name': 'xesam'});
  }
  return BridgeHandlerResult.failure(
    BridgeError(code: 'E_NOT_FOUND', message: 'user not found'),
  );
});

// Async handler：多帧响应
bridge.registerAsyncHandler('timerLog',
    (TrustedPageContext context, dynamic payload, ResponseEmitter? emitter) async {
  if (emitter == null) return;
  await emitter(
    const Result<dynamic, BridgeError>.success({'event': 'tick', 'value': 42, 'seq': 1}),
    false,
  );
  await emitter(
    const Result<dynamic, BridgeError>.success({'event': 'stopped', 'running': false}),
    true,
  );
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
