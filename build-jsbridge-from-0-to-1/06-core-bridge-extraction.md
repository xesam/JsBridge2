# 第 6 章：提炼第一版桥接内核 CoreBridge

## 目标
把分散在 Activity/WebView 里的桥接逻辑，收敛到一个可复用的内核类。

本仓库把这一步的结果命名为 `CoreBridge`（Tier 1，`core` 包）——纯协议分发层，零 security 依赖。第 9 章会再叠加一个 `JsBridge`（Tier 2）承载会话与策略，两者是"叠加"而非"合并"关系。

## 重构前后对比
- 重构前：页面层负责解析消息、分发方法、回包、错误处理；多页面接入复制大量逻辑。
- 重构后：页面层只做生命周期与初始化；`CoreBridge` 负责收包、分发、回包；业务只通过 handler 注册扩展。

## 第一版应包含的能力（对照 `CoreBridge` 公开 API）
1. `registerSimpleHandler(String method, SimpleHandler handler)` / `registerAsyncHandler(String method, AsyncHandler handler)`：两个注册入口（第 4 章），两者的第一形参都是 `TrustedPageContext`。
2. `bind()` / `bind(Listener)`：绑定 transport 收包入口（自分发 / 交给上层拦截，第 9 章用后者）。
3. `attachTransport(BridgeTransport)`：替换 transport 实例。
4. `dispatch(BridgeMessage, TrustedPageContext)`：按 method 分发；找不到 handler 回 `E_METHOD_NOT_FOUND`；handler 异常回 `E_INTERNAL`。
5. `respondSuccess / respondFail`：响应的唯一出口。
6. `postEvent(String method, Object payload)`：向 JS 主动发 `kind=event` 消息，返回是否发送成功。
7. `destroy()`：关闭 transport。
8. `sendFailureCount` 内部计数：发送链失败时递增并记日志（不作公开 API——send 失败的公开可观测出口是 `postEvent` 返回 `false`，C17；第 13 章）。

页面绑定（`resetPageInstance`）、会话、策略不在 Tier 1——它们属于 `JsBridge`，第 9 章引入。

## 关键实现建议
- 把消息解析失败作为"静默丢弃"处理：`BridgeMessage.fromJson` 返回 `null` 时不崩溃、不回包。
- 统一 `respondSuccess/respondFail` 出口；发送失败时递增 `sendFailureCount` 并记日志。
- handler Map（`ConcurrentHashMap`）作为实例状态，而非全局状态。

## 示例骨架
```java
public final class CoreBridge {
    private volatile BridgeTransport transport;
    private final Map<String, HandlerEntry> handlers = new ConcurrentHashMap<>();   // 两个入口写入同一张表

    public void registerSimpleHandler(String method, SimpleHandler handler) { ... }
    public void registerAsyncHandler(String method, AsyncHandler handler) { ... }
    public void bind() { transport.bind(this::autoDispatch); }
    public void dispatch(BridgeMessage message, TrustedPageContext context) { ... }  // E_METHOD_NOT_FOUND / E_INTERNAL 兜底
    public boolean postEvent(String method, Object payload) { ... }
    public void destroy() { ... }
}
```

`HandlerEntry` 是内核内部的联合体：`SimpleEntry` 把返回值封装成唯一一帧成功响应，`AsyncEntry` 构造 `ResponseEmitter` 适配器把 `emitter.success(payload, done)` / `emitter.fail(error)` 转成响应帧。对外只暴露两个注册入口，不暴露第三种形态。

## 验收清单
1. 在第二个页面复用同一套 bridge 接入流程。
2. 页面代码明显变薄。
3. 回包逻辑在 core 中唯一实现。
4. core 源码中不出现任何 `security` 包 import——为第 9 章的分层叠加留出空间。

## 常见坑
1. 核心类仍直接依赖 Activity/Fragment。
2. 在内核里提前做会话/策略判断，导致 Tier 1 被污染——本仓库明确约束 CoreBridge 零 security 依赖。
3. `destroy` 不清理 transport，导致泄漏或重复回调。
