# 第 2 章：直接调用框架能力打通互调

## 本章目标
先不抽象，不谈分层。直接用 WebView 原生能力把通信打通，建立直觉。

## 思路
把这一步理解成“拉一根临时网线”：
- JS 端把字符串发给 Native。
- Native 收到后再把字符串回给 JS。

只要这根“网线”能稳定传输，后面再把协议和架构升级。

> 本仓库正式实现里，这条“临时网线”并没有被丢掉：`extensions/system/LegacyJavascriptChannel` 在低版本系统（SDK < M，无法使用 `WebMessageChannel`）时，用的正是本章这套 `addJavascriptInterface` + `evaluateJavascript` 兜底方案（Native 代理对象名为 `$__native__`，JS 侧入口为 `window.__bridgeReceiveFromNative`）。第 7 章会看到它如何被包装成统一的 `BridgeTransport`。

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

## 你会看到什么
- 点击按钮后，Native 日志里出现 JS 传来的字符串。
- JS 控制台收到 Native 回调。

## 验收清单
1. JS -> Native 成功。
2. Native -> JS 成功。
3. 页面刷新后仍可再次调用。

## 常见坑
1. 漏掉 `@JavascriptInterface`，JS 调用无效。
2. 在非主线程调用 `evaluateJavascript`。
3. 页面未加载完成就调用 JS 回调。

## 小结
现在你有了一条“可工作的最小通信链路”。第 3 章我们把裸字符串升级成结构化协议。
