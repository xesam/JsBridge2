# Android

Android 平台 JsBridge 实现，Java 8，`minSdk 21`。

> 消息模型为纯异步（协议 v1 不支持同步调用，所有结果以独立 response/event 消息回传，详见 [docs/03-protocol.md §1 消息模型](../docs/03-protocol.md)）。注意：Android `addJavascriptInterface` 技术上支持 JS 同步调用 Native，但本库 `LegacyJavascriptChannel` 将其签名固定为 `void`，刻意弃用该能力以对齐四端语义。

## 模块

| 模块 | 说明 |
|------|------|
| `js-bridge-core` | 核心库：CoreBridge、JsBridge、PolicyEngine、SessionService、Transport 接口 |
| `js-bridge-example` | 示例 App：演示完整集成流程，WebAssets 由 `pnpm sync` 同步 |

## 快速开始

```bash
cd js_bridge_android

# 运行单元测试
./gradlew :js-bridge-core:test

# 构建示例 APK
./gradlew :js-bridge-example:assembleDebug

# 安装到设备
./gradlew :js-bridge-example:installDebug
```

## 集成教程

> 内核分为两层，递进使用：
> - **CoreBridge**（Tier 1）— 纯消息分发，零安全依赖。适合可信本地页面、原型开发。
> - **JsBridge**（Tier 2）— 叠加在 CoreBridge 之上，增加握手、策略链、会话管理。适合生产环境。

### 1. 添加依赖

MVP 阶段从源码引用：

```gradle
dependencies {
    implementation project(':js-bridge-core')
}
```

> 发布后可改为 `implementation 'io.github.xesam:jsbridge-core:0.0.1'`

---

## 第一部分：CoreBridge

CoreBridge 是 Tier 1 核心协议层，只做三件事：注册 handler、分发消息、发送响应/事件。它不感知安全策略、会话、握手——这些全部由上层 JsBridge 负责。

### 1.1 创建 CoreBridge

CoreBridge 只需要一个 `BridgeTransport`（消息收发通道）：

```java
import io.github.xesam.android.bridge.core.CoreBridge;
import io.github.xesam.android.bridge.extensions.system.AndroidWebViewBridgeTransport;

// AndroidWebViewBridgeTransport 封装了 WebView 的 WebMessagePort / addJavascriptInterface
AndroidWebViewBridgeTransport transport = new AndroidWebViewBridgeTransport(webView);
CoreBridge core = new CoreBridge(transport);
```

> 构造后仍可通过 `attachTransport(newTransport)` 替换 transport 实例（CoreBridge 与 JsBridge 均提供此公开面，后者委托 CoreBridge）。与其他三端不同，Android 的 CoreBridge 构造要求非空 transport，`attachTransport` 用于实例替换；替换后需重新调用 `bind()` / `resetTransport()` 为新 transport 建立入站闭环。

### 1.2 注册 Handler

CoreBridge 固定两个注册入口——`registerSimpleHandler`（恰好一帧）与 `registerAsyncHandler`（可多帧），二者都把 `TrustedPageContext` 作为 handler 的首形参：

```java
import org.json.JSONObject;
import io.github.xesam.android.bridge.api.model.BridgeError;

// Simple：返回时即有答案
core.registerSimpleHandler("getUser", (context, payload) -> {
    String userId = payload.optString("userId");
    if (!"001".equals(userId)) {
        throw new IllegalStateException("user not found");   // 归一化为 E_INTERNAL
    }
    return new JSONObject().put("name", "xesam");
});

// Async：答案来自异步回调（定位、相册、网络…）或需要多帧时使用
core.registerAsyncHandler("getCurrentLocation", (context, payload, emitter) -> {
    String origin = context.getOrigin();   // 需要时直接用首形参
    // ... 获取定位 ...
    emitter.success(locationInfo, true);
});
```

### 1.3 绑定 Transport 并自动分发

```java
// bind() 后 transport 收到的消息会自动解析并 dispatch 到已注册的 handler
core.bind();
```

### 1.4 主动推送事件

```java
// 向 JS 侧推送事件（kind=event），无需等待请求
core.postEvent("runtime.state", new JSONObject().put("state", "resumed"));
```

### 1.5 独立使用场景

当页面完全可信（如本地 `file://` 页面）、无需安全校验时，CoreBridge 可独立使用：

```java
CoreBridge core = new CoreBridge(new AndroidWebViewBridgeTransport(webView));
core.registerSimpleHandler("getUser", (context, payload) -> new JSONObject().put("name", "xesam"));
core.bind();

// 页面加载时无需 resetPageInstance，因为没有会话概念
```

> **上下文**：Tier 1 未叠加 security 层，不存在可信上下文的来源，`CoreBridge.bind()` 传入空上下文（`getOrigin()` 为 `""`）。需要真实 origin / pageInstanceId 时请使用 JsBridge。

> **局限**：CoreBridge 没有握手、没有 origin 校验、没有会话管理。任何能向 WebView 发消息的 JS 都可以调用已注册的 handler。生产环境请使用 JsBridge。

---

## 第二部分：JsBridge

JsBridge 是 Tier 2 会话/策略/握手层，叠加在 CoreBridge 之上。它拦截 transport 入口，为每条消息插入策略链（结构校验 → 握手门控 → 访问控制），策略通过后再委托 CoreBridge 分发。JsBridge 内部持有一个 CoreBridge 实例，handler 注册委托给 CoreBridge。

### 2.1 安全模式

`securityConfig` 参数二选一，没有中间态：

| 配置 | 行为 |
|------|------|
| `null` | 无安全检查：仅校验消息结构，无需握手，`resetPageInstance()` 后立即可用 |
| `SecurityConfig` | 握手门控 + session 校验；`allowedOrigins` / `methodWhitelist` 决定两个白名单维度是否进链（`{"*"}` = 显式不限制）；`methodWhitelist` 为业务方法白名单，协议方法（`bridge.handshake` / `bridge.cancelScope`）由框架自动放行 |

> **配置校验**：传入 `SecurityConfig` 时 `allowedOrigins` 与 `methodWhitelist` 必须显式设置（不可为 `null`），否则构造期抛出 `IllegalArgumentException`；`{"*"}` 是合法的"不限制该维度"声明。`methodWhitelist` 只需列出**业务方法**——协议方法由框架装配期自动并入放行集，无需显式写入 `bridge.handshake`。

### 2.2 创建 JsBridge

```java
import java.util.Arrays;
import java.util.HashSet;
import io.github.xesam.android.bridge.JsBridge;
import io.github.xesam.android.bridge.extensions.system.AndroidWebViewBridgeTransport;
import io.github.xesam.android.bridge.extensions.system.AndroidWebViewPageContextProvider;

// 无安全配置 — 开发/测试（无需握手，resetPageInstance() 后立即可用）
JsBridge bridge = new JsBridge(
        new AndroidWebViewBridgeTransport(webView),
        new AndroidWebViewPageContextProvider(webView),
        null
);

// 传入 SecurityConfig — 生产环境（握手 + origin 白名单 + 方法白名单）
JsBridge secureBridge = new JsBridge(
        new AndroidWebViewBridgeTransport(webView),
        new AndroidWebViewPageContextProvider(webView),
        new JsBridge.SecurityConfig()
                .allowedOrigins(new HashSet<>(Arrays.asList("https://your-domain.com")))
                .methodWhitelist(new HashSet<>(Arrays.asList("getUser", "getCurrentLocation")))
);
```

**参数说明**：

| 参数 | 说明 |
|------|------|
| `BridgeTransport` | 消息传输层，`AndroidWebViewBridgeTransport` 封装了 WebView 的 WebMessagePort / addJavascriptInterface |
| `PageContextProvider` | 提供 `TrustedPageContext`（origin + pageInstanceId），`AndroidWebViewPageContextProvider` 从 WebView URL 提取 origin 并经内核 `OriginNormalizer` 归一化 |
| `SecurityConfig` | 安全配置，传 `null` 或完整 `SecurityConfig`，详见上表 |

> **自实现 `PageContextProvider` 时**：origin 必须经由内核的 `OriginNormalizer.normalize(...)` 派生（协议契约见 `docs/03-protocol.md` §9 细则 5：`TrustedPageContext.origin` 的唯一合法形态由内核的四端统一手写归一化算法产生——刻意不使用 `java.net.URI` 解析，宿主不得自写归一化，验收锚点 C54）。

### 2.3 注册 Handler

JsBridge 与 CoreBridge 的注册表面完全相同：两个入口，`TrustedPageContext` 作为 handler 首形参。策略求值时使用的正是这个对象，因此 handler 看到的 origin / pageInstanceId 与策略判定结果一致。

```java
// Simple handler：返回时通信结束（恰好一帧，done=true）
bridge.registerSimpleHandler("getUser", (context, payload) -> {
    String userId = payload.optString("userId");
    if (!"001".equals(userId)) {
        throw new IllegalStateException("user not found");
    }
    return new JSONObject().put("name", "xesam");
});

// Async handler：需要多帧，或答案来自异步回调
bridge.registerAsyncHandler("timerLog", (context, payload, emitter) -> {
    emitter.success(new JSONObject().put("seq", 1), false);   // done=false，中间帧
    emitter.success(new JSONObject().put("seq", 2), true);    // done=true，末帧
});
```

> 同一 method 重复注册时**后者覆盖前者**（由 C49 固定）。context 是普通形参，不需要时忽略即可——不存在"带上下文的另一个注册口"。

### 2.4 页面生命周期

```java
webView.setWebViewClient(new WebViewClient() {
    @Override
    public void onPageFinished(WebView view, String url) {
        // 每次页面加载完成后重置传输绑定和会话
        bridge.resetTransport();   // 重建入站闭环：绑定监听器、关闭旧通道并轮换绑定周期；新通道由 JS 侧按需拉取（pull 模型）
        bridge.resetPageInstance();   // 轮换 pageInstanceId，清理旧 session
    }
});
```

> `resetPageInstance()` 后，`securityConfig == null` 时 `isReady()` 立即为 `true`；传入 `SecurityConfig` 时需等待 JS 发起 `bridge.handshake` 并成功后 `isReady()` 才为 `true`。

### 2.5 生命周期事件推送（可选）

`LifecycleExtension` 向 JS 推送宿主生命周期状态：

```java
import io.github.xesam.android.bridge.extensions.lifecycle.LifecycleExtension;

LifecycleExtension lifecycleExtension = new LifecycleExtension(bridge);

// 在 Activity 生命周期回调中推送
@Override protected void onStart()    { lifecycleExtension.onHostEvent("started"); }
@Override protected void onResume()   { lifecycleExtension.onHostEvent("resumed"); }
@Override protected void onPause()    { lifecycleExtension.onHostEvent("paused"); }
@Override protected void onStop()     { lifecycleExtension.onHostEvent("stopped"); }
@Override protected void onDestroy() {
    lifecycleExtension.onHostEvent("destroyed");
    bridge.destroy();   // 可选清理 helper：释放监听器等资源；不调用亦无泄漏面
    super.onDestroy();
}
```

> 握手完成前的事件会排队缓存（上限 32），握手成功后按序补发。

### 2.6 加载页面

```java
// 确保 WebAssets 已通过 `pnpm sync` 同步到 src/main/assets/web/
webView.loadUrl("file:///android_asset/web/index.html");
```

---

## Transport

`AndroidWebViewBridgeTransport` 优先使用 `WebMessagePort`（API 23+），自动 fallback 到 `addJavascriptInterface`。

> **安全注记**：`WebMessageChannelBootstrapper` 以通配目标（`Uri.parse("*")`）投递端口——`file://` 页面无法与特定 origin 匹配，通配是务实选择，但也意味着端口投递本身不做 origin 约束。真正的来源防护依赖握手门控与策略链（传入 SecurityConfig 时），不要单独依赖通道投递作为安全边界；通道由 JS 侧按需拉取建立、随绑定周期轮换关闭，不跨页面加载存活。详见 [docs/02-architecture.md §6.2](../docs/02-architecture.md)。

## 扩展模块

除上文用到的 `extensions/system`（WebView 适配）与 `extensions/lifecycle`（生命周期事件）外，`extensions/registry` 负责宿主经 `launchForResult(Intent, callback)` 发起 Android Activity 结果流程的回调登记与结果回执（扩展能力，非内核必需；当前仅 Android 提供），支持并发防重（single-occupy：全局单占用、无 method 维度——任意 launch 在途期间新的 launch 立即以 busy 回执拒绝，不排队、不共享结果）。设计说明见 [docs/02-architecture.md](../docs/02-architecture.md) §5.1。

## 线程与生命周期

- Bridge 生命周期 API（`resetTransport` / `resetPageInstance` / `destroy` / handler 注册）建议保持在单一串行线程（通常为主线程）调用，避免与页面生命周期竞态。
- transport `send()` 返回 `false` 视为投递失败：`sendFailureCount` 为内部计数，无公开读口（公开 reader 已按「零兼容包袱」四端删除，见 [docs/09-conformance.md](../docs/09-conformance.md) C17）。send 失败的公共可观测出口为 `postEvent` 返回 `false`（见 [docs/07-transport-bridge-design.md](../docs/07-transport-bridge-design.md) §4.4）。

## WebAssets

示例 App 的 `src/main/assets/web/` 不纳入版本管理，从根目录 `web-assets/` 同步：

```bash
cd web-assets && pnpm sync
```
