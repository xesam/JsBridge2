# 第 8 章：最小可信上下文

## 目标
定义"框架应该信任什么"，并且只保留必要信息。把 URL、证书、业务账号等复杂判定写进框架会导致：核心职责膨胀、调用方失去策略自主权、跨端难统一语义。框架层只输出可信事实，策略由调用方决定。

## 上下文模型
- `origin`：来源标识（如 `file://`、`https://example.com`）。
- `pageInstanceId`：页面实例唯一 ID。

## SPI 设计
```java
public interface PageContextProvider {
    TrustedPageContext createContext(BridgeMessage bridgeMessage, String pageInstanceId);
}
```

归属层级：`PageContextProvider` 位于 `security` 包（Tier 2），由 `JsBridge` 在收到消息后调用，产物 `TrustedPageContext` 有三个消费者——策略链（校验）、handler（`SimpleHandler` / `AsyncHandler` 的第一形参）、extensions（WebView 适配）。Tier 1 的 `CoreBridge` 完全不感知它：`CoreBridge` 独立使用时（`bind()`，没有 security 层产出上下文）由内核直接注入空上下文 `new TrustedPageContext("", "")`，保证 handler 签名在两种使用形态下一致。

## Android 端实现
`extensions/system/AndroidWebViewPageContextProvider`：
- 从 WebView 当前状态提取最小可信信息（内部委托 `AndroidWebViewTrustedContextFactory`）。
- 返回 `TrustedPageContext(origin, pageInstanceId)`，null 字段归一化为空串。

## 验收清单
1. `JsBridge` 只依赖 `PageContextProvider` 抽象，不依赖具体 WebView。
2. `TrustedPageContext` 字段保持最小且稳定（只有 `origin` + `pageInstanceId`）。
3. 调用方可在策略层自行增加校验规则。

## 常见坑
1. 上下文字段过多，成为"万能上下文对象"。
2. 框架直接做业务风控判定。
3. 页面重绑后 `pageInstanceId` 未更新（见第 9 章 `resetPageInstance` 的轮换语义）。
