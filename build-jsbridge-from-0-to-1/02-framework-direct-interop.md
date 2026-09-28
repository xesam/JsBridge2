# 第 2 章：直接调用框架能力打通互调

## 目标
零抽象，直接用 WebView 原生能力建立 JS 与 Native 的双向通信，作为后续协议化与分层的基线。

> 本仓库正式实现中，这条通道没有被丢弃：`extensions/system/LegacyJavascriptChannel` 在低版本系统（SDK < M，无法使用 `WebMessageChannel`）时用的正是本章方案——`addJavascriptInterface` + `evaluateJavascript`，Native 代理对象名为 `__jsbridge2__`，JS 侧入口为 `window.__jsbridge2__.receive`。它如何被包装为统一的 `BridgeTransport` 见第 7 章。

## 步骤 1：开启 WebView JS 能力
```java
webView.getSettings().setJavaScriptEnabled(true);
```

## 步骤 2：暴露 Native 接口给 JS
```java
webView.addJavascriptInterface(new Object() {
    @JavascriptInterface
    public void postMessage(String message) {
        android.util.Log.d("Bridge", "from js: " + message);
    }
}, "NativeBridge");
```

## 步骤 3：Native 回调 JS
```java
webView.post(() -> webView.evaluateJavascript(
        "window.onNativeMessage('native ok')", null));
```

## JS 示例
```js
window.onNativeMessage = (res) => {
  console.log('from native:', res)
}

function callNative() {
  window.NativeBridge.postMessage('{"method":"ping"}')
}
```

## 验收清单
1. JS -> Native 成功（Native 日志出现 JS 传来的字符串）。
2. Native -> JS 成功（JS 控制台收到 Native 回调）。
3. 页面刷新后仍可再次调用。

## 常见坑
1. 漏掉 `@JavascriptInterface`，JS 调用无效。
2. 在非主线程调用 `evaluateJavascript`。
3. 页面未加载完成就调用 JS 回调。
4. 试图利用 `addJavascriptInterface` 的同步返回能力（方法声明非 void 返回值，JS 阻塞取回结果）——**本仓库刻意不用**：iOS WKWebView 无同步通道，四端通道能力交集只有异步，协议 v1 因此定义为纯异步模型，任何端不得单方面提供同步 API（见 `docs/03-protocol.md §1 消息模型`）。注入方法签名一律 `void`。
