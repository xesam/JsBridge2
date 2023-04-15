# 第 4 章：实现最小分发器

## 本章目标
把“写死调用逻辑”升级为“可注册、可扩展”的方法分发机制。

## 从 if-else 到 handler 注册
初期代码常见写法：
```java
if ("getUser".equals(method)) { ... }
else if ("pickImage".equals(method)) { ... }
```

这种方式短期可用，但扩展性差。更好的方式是“路由表”：
- key：`method`
- value：handler 实例

## 核心接口
本仓库把 handler 接口分成两个，对应“是否需要页面上下文”：

```java
// 与页面解耦：只关心 payload。绝大多数业务用这个。
public interface SimpleNativeMessageHandler {
    void handle(Object data, MessageHandlerCallback callback);
}

// 需要可信页面上下文（origin / pageInstanceId）的场景，第 8 章引入。
public interface NativeMessageHandler {
    void handle(TrustedPageContext trustedPageContext, Object data, MessageHandlerCallback callback);
}
```

注册 API 与所在层级有关：
- `CoreBridge.registerHandler(String method, SimpleNativeMessageHandler handler)`——Tier 1 内核的原始注册口（第 6 章）。
- `JsBridge.registerNativeHandler(String method, SimpleNativeMessageHandler handler)`——Tier 2 对同一能力的公开转发。
- `JsBridge.registerNativeHandlerWithContext(String method, NativeMessageHandler handler)`——带上下文 handler 的注册口。

## 分发流程
1. 解析 `BridgeMessage`（`fromJson` 失败得到 `null`，直接静默丢弃）。
2. 根据 `method` 查找 handler。
3. 找到则执行；找不到返回 `E_METHOD_NOT_FOUND`。
4. handler 抛出未捕获异常时，core 捕获 `Throwable` 并归一化为 `E_INTERNAL` 回包，bridge 不崩溃。

## 示例
```java
bridge.registerNativeHandler("getUser", (data, cb) -> {
    JSONObject user = new JSONObject();
    user.put("name", "Sam");
    cb.success(user);
});
```

## 验收清单
1. 同时注册多个 handler 并独立生效。
2. 未注册方法返回标准错误 `E_METHOD_NOT_FOUND`。
3. 不改核心分发代码即可新增业务方法。
4. handler 内部抛异常时收到 `ok=false, error.code=E_INTERNAL`，而不是崩溃或无响应。

## 常见坑
1. 分发层直接依赖页面 UI 组件。
2. handler 抛异常后没有标准回包。
3. 使用全局静态 Map，生命周期不可控——handler 表应是 bridge 实例状态。

## 小结
你已经有了“协议 + 分发”的最小桥接骨架。第 5 章我们补齐异步回调语义，让它能处理真实业务。
