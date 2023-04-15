# 第 5 章：补齐异步回调语义

## 本章目标
让 Bridge 不只支持同步调用，还能稳定处理异步任务。

## 为什么这一步关键
很多 Native 能力都是异步的：网络、定位、相册、权限弹窗。如果桥接只支持同步，业务会被迫“假同步”，最终出错。

## 回调接口设计
本仓库的 `MessageHandlerCallback` 正是三方法设计：
```java
public interface MessageHandlerCallback {
    void success(Object res);                       // 一次性成功，等价于 success(res, true)
    default void success(Object res, boolean done) { success(res); }  // 分段/流式结果
    void fail(Object error);                        // 失败回包
}
```

## 流程图（逻辑）
1. 收到 request。
2. 进入 handler。
3. handler 异步执行。
4. 异步完成后调用 `success/fail`。
5. core 统一封装成 response（`respondSuccess/respondFail` 是唯一出口）。

## 示例
来自本仓库示例工程的 `RequestExt`（简化）：
```java
bridge.registerNativeHandler("request", (data, cb) -> {
    Payload requestData = parse(data);
    new Thread(() -> {
        try {
            Response response = doHttp(requestData.url);
            JSONObject res = new JSONObject();
            res.put("code", response.code());
            res.put("body", readBody(response));
            cb.success(res);
        } catch (Exception e) {
            cb.fail(new BridgeError("E_REQUEST_FAILED",
                    e.getMessage() == null ? "request failed" : e.getMessage()));
        }
    }).start();
});
```

流式场景参考示例工程 `TimerExt`：JS 发 `keep=true` 请求，Native 周期性 `cb.success(tick, false)` 推送中间帧（`done=false`），停止时 `cb.success(stopEvent, true)` 发最终帧。

## 设计要点
- handler 不直接拼 JSON 响应，交给 core 统一封装（`CoreBridge.respondSuccess/respondFail`）。
- 失败必须走 `fail`，而不是吞异常；handler 抛出的未捕获异常由 core 归一化为 `E_INTERNAL`。
- `done=false` 用于流式场景（进度、分批数据）；最终帧必须 `done=true`。
- 协议侧的配合字段：request 携带 `keep=true` 声明持续回调意图；response 用 `done` 控制帧序列（`docs/01-protocol.md §6`）。
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

## 小结
当回调语义稳定后，Bridge 才能承载真实业务。第 6 章把这些能力提炼为可复用核心类。
