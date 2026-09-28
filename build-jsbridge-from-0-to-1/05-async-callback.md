# 第 5 章：补齐异步回调语义

## 目标
让 Bridge 稳定处理异步任务。网络、定位、相册、权限弹窗等 Native 能力都是异步的，桥接若只支持同步，业务只能"假同步"。

## 回调接口设计
本仓库的 `ResponseEmitter` 是双方法设计：成功帧显式携带 `done`，失败帧终止通信。
```java
public interface ResponseEmitter {
    void success(Object payload, boolean done);   // done=false 为非终帧，done=true 收尾
    void fail(BridgeError error);                 // 失败回包，通信结束
}
```
单帧场景不需要回调：`SimpleHandler` 直接把结果作为返回值交给内核，其返回类型**不携带 `done`**（语义上恒为 true）。多帧（流式）只能由 `AsyncHandler` + `ResponseEmitter` 表达——这是两个注册入口的分工边界。

## 流程
1. 收到 request，进入 handler。
2. handler 异步执行，完成后经 `emitter` 调用 `success` / `fail`。
3. core 统一封装成 response——`respondSuccess/respondFail` 是唯一出口。

## 示例
来自本仓库示例工程的 `RequestExt`（简化）：
```java
bridge.registerAsyncHandler("request", (ctx, payload, emitter) -> {
    Payload requestData = parse(payload);
    new Thread(() -> {
        try {
            Response response = doHttp(requestData.url);
            JSONObject res = new JSONObject();
            res.put("code", response.code());
            res.put("body", readBody(response));
            emitter.success(res, true);
        } catch (Exception e) {
            emitter.fail(new BridgeError("E_REQUEST_FAILED",
                    e.getMessage() == null ? "request failed" : e.getMessage()));
        }
    }).start();
});
```

流式场景参考示例工程 `TimerExt`：JS 发 `keep=true` 请求，Native 周期性 `emitter.success(tick, false)` 推送中间帧（`done=false`），停止时 `emitter.success(stopEvent, true)` 发最终帧。

## 设计要点
- **协议 v1 为纯异步消息模型，不支持同步调用**：任何方向的调用均不阻塞等待返回值，结果一律以独立 response 消息回传；跨端硬约束是 iOS WKWebView 无同步通道，四端通道能力交集只有异步（详见 `docs/03-protocol.md §1 消息模型`）。Android `addJavascriptInterface` 技术上支持 JS 同步取值，但本仓库刻意弃用（方法签名固定 `void`，见第 2 章的 `LegacyJavascriptChannel` 对应实现）。
- handler 不直接拼 JSON 响应，交给 core 统一封装（`CoreBridge.respondSuccess/respondFail`）。
- 失败必须走 `fail`，而不是吞异常；handler 抛出的未捕获异常由 core 归一化为 `E_INTERNAL`。
- `done=false` 用于流式场景（进度、分批数据）；最终帧必须 `done=true`。
- 协议侧的配合字段：request 携带 `keep=true` 声明持续回调意图；response 用 `done` 控制帧序列（`docs/03-protocol.md §6`）。
- 业务错误码（如 `E_REQUEST_FAILED`）由业务自定义；协议基线错误码必须取自 `BridgeApiContract`，禁止内联字面量。

## 验收清单
1. 异步回包可以正确匹配 `reqId`。
2. 失败路径有统一错误结构。
3. 异步任务异常不会导致 bridge 崩溃（回 `E_INTERNAL`）。
4. 流式请求能收到多帧 `done=false` + 一帧 `done=true`。

## 常见坑
1. 异步线程持有过期页面上下文。
2. 回调多次但未约束 `done` 语义——JS 端无法判断流是否结束。
3. 在 handler 中直接 `send`，绕过 core 的统一响应出口。
