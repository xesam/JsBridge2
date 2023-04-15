# 第 15 章：示例应用组装与接入

## 本章目标
给出一套“新页面可直接复制”的接入模板。以下代码与示例工程 `js_bridge_android/js-bridge-example` 的 `WebActivity` 保持一致。

## 接入步骤
1. 创建 `JsBridge`：注入 `BridgeTransport`、`PageContextProvider`、`KernelConfig`、`SecurityConfig`。
2. 注册 handler：按业务方法扩展。
3. 页面加载完成后 `resetTransport()` + `resetForNewPage()`。
4. 页面销毁时 `destroy()`。

## 接入代码骨架
```java
mBridge = new JsBridge(
        new AndroidWebViewBridgeTransport(binding.webContainer),
        new AndroidWebViewPageContextProvider(binding.webContainer),
        BridgePolicyConfig.createKernelConfig(),
        BridgePolicyConfig.createSecurityConfig());
lifecycleExtension = new LifecycleExtension(mBridge);
mBridgeResultRegistry = new DefaultBridgeResultRegistry(this);

binding.webContainer.getSettings().setJavaScriptEnabled(true);
binding.webContainer.setWebViewClient(new WebViewClient() {
    @Override
    public void onPageFinished(WebView view, String url) {
        mBridge.resetTransport();     // 重建 MessageChannel 并 bind，建立入站闭环
        mBridge.resetForNewPage();    // 轮换 pageInstanceId，旧 session 失效
    }
});

// 注册业务 handler（示例工程集中收口在 WebActivities.setupBridge）
bridge.registerNativeHandler("getUser", new UserExt());
bridge.registerNativeHandler("request", new RequestExt());
bridge.registerNativeHandler("timerLog", new TimerExt());
bridge.registerNativeHandler("pickImage", new PickImagePlugin(context, mBridgeResultRegistry));

binding.webContainer.loadUrl("file:///android_asset/web/index.html");
lifecycleExtension.onHostEvent("created");   // 以及 started/resumed/paused/stopped/destroyed

@Override
protected void onDestroy() {
    lifecycleExtension.onHostEvent("destroyed");
    mBridge.destroy();
    super.onDestroy();
    mBridgeResultRegistry.destroy();
}
```

策略配置集中在 `BridgePolicyConfig`（Level 2 生产形态）：
```java
static JsBridge.SecurityConfig createSecurityConfig() {
    return JsBridge.SecurityConfig.secure()
            .allowedOrigins(new HashSet<>(Arrays.asList("file://", "https://example.com")))
            .methodWhitelist(allowedMethods())
            .defaultCapabilities(capabilities());
}
```

## JS 侧
页面只需 `<script src="jsbridge-sdk.js">`：共享 SDK（`web-assets/` 构建产物）自动完成 transport 探测、`bridge.handshake` 握手、sessionId 保存与 `runtime.state` 监听。JS 侧不需要手写任何握手代码。

## 兼容场景
如果宿主仍使用 `onActivityResult`（见示例工程 `CompatWebActivity`）：
- 使用 `CompatBridgeResultRegistry`（同时实现 `BridgeResultDispatcher`）。
- 在 Activity 的 `onActivityResult` 中调用 `dispatchResult(requestCode, resultCode, data)`。

## 验收清单
1. 请求调用、事件推送、结果型扩展都可运行。
2. 页面重进后会话状态正确（旧 session 失效、需重新握手）。
3. Activity 销毁后无残留回调。

## 常见坑
1. `onPageFinished` 只调 `resetForNewPage()` 忘了 `resetTransport()`——MessageChannel 已随页面销毁，通道断链。
2. 忘记 `destroy()` 导致泄漏。
3. 把策略配置写在多个页面里导致不一致——集中到 `BridgePolicyConfig`。

## 小结
示例应用是对外沟通的最佳“活文档”。最后一章我们做总复盘与上线前检查。
