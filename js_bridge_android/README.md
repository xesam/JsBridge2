# Android

Android 平台 JsBridge 实现，Java 8，`minSdk 21`。

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

> 发布后可改为 `implementation 'io.github.xesam:jsbridge-core:0.1.0'`

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

### 1.2 注册 Handler

CoreBridge 提供简单的 `SimpleNativeMessageHandler`，只接收 payload，不感知页面上下文：

```java
import org.json.JSONObject;
import io.github.xesam.android.bridge.api.model.BridgeError;

core.registerHandler("getUser", (payload, callback) -> {
    String userId = payload.optString("userId");
    if ("001".equals(userId)) {
        JSONObject res = new JSONObject();
        res.put("name", "xesam");
        callback.success(res);
    } else {
        callback.fail(new BridgeError("E_NOT_FOUND", "user not found"));
    }
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
core.registerHandler("getUser", (payload, callback) -> {
    callback.success(new JSONObject().put("name", "xesam"));
});
core.bind();

// 页面加载时无需 resetForNewPage，因为没有会话概念
```

> **局限**：CoreBridge 没有握手、没有 origin 校验、没有会话管理。任何能向 WebView 发消息的 JS 都可以调用已注册的 handler。生产环境请使用 JsBridge。

---

## 第二部分：JsBridge

JsBridge 是 Tier 2 会话/策略/握手层，叠加在 CoreBridge 之上。它拦截 transport 入口，为每条消息插入策略链（结构校验 → 握手门控 → 访问控制），策略通过后再委托 CoreBridge 分发。JsBridge 内部持有一个 CoreBridge 实例，handler 注册委托给 CoreBridge。

### 2.1 安全分级

| Level | 配置 | 行为 |
|-------|------|------|
| **0** | `new SecurityConfig()` | 仅校验消息结构，无需握手，`resetForNewPage()` 后立即可用 |
| **1** | `new SecurityConfig().withHandshakeGate()` | 需握手才能调用，但不校验 origin |
| **2** | `SecurityConfig.secure()` | 握手 + origin 白名单 + 方法白名单（生产推荐） |

> **注意**：Level 2 下 `allowedOrigins` 不可为 `"*"`，否则构造时抛出 `IllegalArgumentException`。

### 2.2 创建 JsBridge

```java
import io.github.xesam.android.bridge.JsBridge;
import io.github.xesam.android.bridge.extensions.system.AndroidWebViewBridgeTransport;
import io.github.xesam.android.bridge.extensions.system.AndroidWebViewPageContextProvider;

// Level 0 — 开发/测试（无需握手，resetForNewPage() 后立即可用）
JsBridge bridge = new JsBridge(
        new AndroidWebViewBridgeTransport(webView),
        new AndroidWebViewPageContextProvider(webView),
        new JsBridge.KernelConfig(),
        new JsBridge.SecurityConfig()
);

// Level 2 — 生产环境（握手 + origin 白名单 + 方法白名单）
JsBridge secureBridge = new JsBridge(
        new AndroidWebViewBridgeTransport(webView),
        new AndroidWebViewPageContextProvider(webView),
        new JsBridge.KernelConfig(),
        JsBridge.SecurityConfig.secure()
                .allowedOrigins(Set.of("https://your-domain.com"))
                .methodWhitelist(Set.of("getUser", "getCurrentLocation"))
                .defaultCapabilities(Set.of("getUser", "getCurrentLocation"))
);
```

**参数说明**：

| 参数 | 说明 |
|------|------|
| `BridgeTransport` | 消息传输层，`AndroidWebViewBridgeTransport` 封装了 WebView 的 WebMessagePort / addJavascriptInterface |
| `PageContextProvider` | 提供 `TrustedPageContext`（origin + pageInstanceId），`AndroidWebViewPageContextProvider` 从 WebView URL 提取 origin |
| `KernelConfig` | 内核配置（如 `maxReadyListeners`） |
| `SecurityConfig` | 安全分级配置，详见上表 |

### 2.3 注册 Handler

JsBridge 委托 CoreBridge 注册 handler，同时提供带 `TrustedPageContext` 的高级注册方式：

```java
// 简单 handler（无需 TrustedPageContext，委托 CoreBridge）
bridge.registerNativeHandler("getUser", (payload, callback) -> {
    String userId = payload.optString("userId");
    if ("001".equals(userId)) {
        callback.success(new JSONObject().put("name", "xesam"));
    } else {
        callback.fail(new BridgeError("E_NOT_FOUND", "user not found"));
    }
});

// 带 TrustedPageContext 的 handler（可获取 origin、pageInstanceId）
bridge.registerNativeHandlerWithContext("getCurrentLocation", (ctx, payload, callback) -> {
    String origin = ctx.getOrigin();  // 可根据 origin 做差异化逻辑
    // ... 获取定位 ...
    callback.success(locationInfo);
});
```

### 2.4 页面生命周期

```java
webView.setWebViewClient(new WebViewClient() {
    @Override
    public void onPageFinished(WebView view, String url) {
        // 每次页面加载完成后重置传输通道和会话
        bridge.resetTransport();   // 重建 WebMessagePort 通道
        bridge.resetForNewPage();   // 轮换 pageInstanceId，清理旧 session
    }
});
```

> `resetForNewPage()` 后，Level 0 下 `isReady()` 立即为 `true`；Level 1/2 下需等待 JS 发起 `bridge.handshake` 并成功后 `isReady()` 才为 `true`。

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
    bridge.destroy();
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

## WebAssets

示例 App 的 `src/main/assets/web/` 不纳入版本管理，从根目录 `web-assets/` 同步：

```bash
cd web-assets && pnpm sync
```
