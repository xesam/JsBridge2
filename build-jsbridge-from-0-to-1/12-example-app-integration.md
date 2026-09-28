# 第 12 章：示例应用组装与接入

## 目标
给出一套"新页面可直接复制"的接入模板。以下代码与示例工程 `js_bridge_android/js-bridge-example` 的 `WebActivity` 关键流程保持一致。

## 接入步骤
1. 创建 `JsBridge`：注入 `BridgeTransport`、`PageContextProvider`、`SecurityConfig`。
2. 注册 handler：按业务方法扩展。
3. 页面加载完成后 `resetTransport()` + `resetPageInstance()`。
4. 页面销毁时 `destroy()`。

## 接入代码骨架
```java
mBridge = new JsBridge(
        new AndroidWebViewBridgeTransport(binding.webContainer),
        new AndroidWebViewPageContextProvider(binding.webContainer),
        BridgePolicyConfig.createSecurityConfig());
lifecycleExtension = new LifecycleExtension(mBridge);

binding.webContainer.getSettings().setJavaScriptEnabled(true);
binding.webContainer.setWebViewClient(new WebViewClient() {
    @Override
    public void onPageFinished(WebView view, String url) {
        mBridge.resetTransport();     // invalidate/轮换：关闭旧通道并重建入站闭环（新通道由页面 requestBridgeChannel 拉取）
        mBridge.resetPageInstance();    // 轮换 pageInstanceId，旧 session 失效
    }
});

// 注册业务 handler（示例工程集中收口在 WebActivities.setupBridge）
// 按回包形态选入口：多帧/异步用 registerAsyncHandler，单返回值用 registerSimpleHandler
bridge.registerAsyncHandler("getUser", new UserExt());
bridge.registerAsyncHandler("request", new RequestExt());
bridge.registerAsyncHandler("timerLog", new TimerExt());
bridge.registerSimpleHandler("showLoading", new LoadingPlugin(context));

binding.webContainer.loadUrl("file:///android_asset/web/index.html");
lifecycleExtension.onHostEvent("created");   // 以及 started/resumed/paused/stopped/destroyed

@Override
protected void onDestroy() {
    lifecycleExtension.onHostEvent("destroyed");
    mBridge.destroy();
    super.onDestroy();
}
```

策略配置集中在 `BridgePolicyConfig`（生产形态）：
```java
static JsBridge.SecurityConfig createSecurityConfig() {
    return new JsBridge.SecurityConfig()
            .allowedOrigins(new HashSet<>(Arrays.asList("file://", "https://example.com")))
            .methodWhitelist(allowedMethods());
}
```

## JS 侧
页面只需 `<script src="jsbridge-sdk.js">`：共享 SDK（`web-assets/` 构建产物）自动完成 transport 探测、`bridge.handshake` 握手、sessionId 保存与 `runtime.state` 监听。JS 侧不需要手写任何握手代码。

## 验收清单
1. 请求调用、事件推送都可运行。
2. 页面重进后会话状态正确（旧 session 失效、需重新握手）。
3. Activity 销毁后无残留回调。

## 常见坑
1. `onPageFinished` 只调 `resetPageInstance()` 忘了 `resetTransport()`——MessageChannel 已随页面销毁，通道断链。
2. 忘记 `destroy()` 导致泄漏。
3. 把策略配置写在多个页面里导致不一致——集中到 `BridgePolicyConfig`。
