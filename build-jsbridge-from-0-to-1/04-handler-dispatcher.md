# 第 4 章：实现最小分发器

## 目标
把"写死调用逻辑"升级为"可注册、可扩展"的方法分发机制。

## 从 if-else 到 handler 注册
初期代码常见写法：
```java
if ("getUser".equals(method)) { ... }
else if ("pickImage".equals(method)) { ... }
```
更好的方式是"路由表"：key 为 `method`，value 为 handler 实例。

## 核心接口
本仓库把 handler 接口分成两个，对应"单帧"与"多帧"两种回包形态。**两者的第一个形参都是 `TrustedPageContext`**（可信页面上下文，第 8 章给出它的来源）——上下文是普通形参，不是独立的注册形态：

```java
// 单返回值：通信在 handler 返回时结束，恰好产生一帧（done 恒为 true）。绝大多数业务用这个。
public interface SimpleHandler {
    Object handle(TrustedPageContext context, Object payload) throws Exception;
}

// 多帧/异步：带 ResponseEmitter，可在返回后继续推帧，第 5 章展开。
public interface AsyncHandler {
    void handle(TrustedPageContext context, Object payload, ResponseEmitter emitter) throws Exception;
}
```

> **演进说明**：早期设计常见"payload-only 入口 + 带上下文入口"两个注册 API，调用方要按是否需要上下文二选一。本仓库把上下文统一为两个接口的首形参，注册入口因此收敛为下面的两个。

## 注册 API 与所在层级
- `CoreBridge.registerSimpleHandler(String method, SimpleHandler handler)`——Tier 1 内核的原始注册口（第 6 章）。
- `CoreBridge.registerAsyncHandler(String method, AsyncHandler handler)`——Tier 1 内核的多帧注册口（第 6 章）。
- `JsBridge.registerSimpleHandler(String method, SimpleHandler handler)` / `JsBridge.registerAsyncHandler(String method, AsyncHandler handler)`——Tier 2 对同一能力的公开转发。

两个入口共用同一张 handler 表：**同一 method 重复注册时后者覆盖前者（last wins）**。

## 分发流程
1. 解析 `BridgeMessage`（`fromJson` 失败得到 `null`，直接静默丢弃）。
2. 根据 `method` 查找 handler。
3. 找到则执行；找不到返回 `E_METHOD_NOT_FOUND`。
4. handler 抛出未捕获异常时，core 捕获 `Throwable` 并归一化为 `E_INTERNAL` 回包，bridge 不崩溃。

## 示例
```java
bridge.registerSimpleHandler("getUser", (ctx, payload) -> {
    JSONObject user = new JSONObject();
    user.put("name", "Sam");
    return user;   // 返回即结束，内核封装成唯一一帧成功响应
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
