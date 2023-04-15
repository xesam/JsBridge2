# 第 3 章：定义最小消息协议

## 本章目标
把“能传字符串”升级为“能传可维护的消息”。

## 为什么必须有协议
如果没有协议，你很快会遇到问题：
- 多个请求并发时，响应不知道对应谁。
- 错误格式各写各的，前端无法统一处理。
- 后续扩展事件推送时，无从区分消息类型。

协议就是通信双方的“语法规则”。

## 字段设计
起步阶段只需要最小集：
1. `id`：当前消息唯一 ID。
2. `kind`：`request | response | event`。
3. `method`：调用方法名。
4. `payload`：参数或结果。
5. `reqId`：response 对应的 request ID。
6. `ok`：响应是否成功。
7. `error`：失败信息。

但既然要定义协议，就一次定全。本项目 Protocol v1 的完整信封字段（见 `docs/01-protocol.md §2`）：

| 字段 | 说明 | 引入章节 |
|------|------|----------|
| `id` | 消息唯一标识 | 本章 |
| `sessionId` | 会话 ID；握手请求可为空，握手后必填 | 第 9 章 |
| `kind` | `request` / `response` / `event` | 本章 |
| `method` | 方法名，建议 `domain.action` | 本章 |
| `ts` | 发送时间戳（Unix 毫秒） | 本章 |
| `timeoutMs` | 请求超时（毫秒），0 或不填表示不超时 | 本章 |
| `keep` | `true` 表示持续回调意图（流式/订阅），默认 `false` | 第 5 章 |
| `payload` | 请求参数或成功响应数据 | 本章 |
| `reqId` | response 对应 request 的 `id` | 本章 |
| `done` | 流式响应帧标志：`false` 中间帧，`true` 最终帧 | 第 5 章 |
| `ok` | 响应是否成功 | 本章 |
| `error` | `ok=false` 时的错误对象 | 本章 |
| `scopeId` | 逻辑页面 scope 标识（SPA 场景） | 第 11 章后按需 |

协议遵循“只增不改不删”的兼容规则：新版本可以新增可选字段，但不得删除字段或更改已有字段语义；接收方必须忽略不认识的字段。

## Request 示例
```json
{
  "id": "r-1001",
  "kind": "request",
  "method": "getUser",
  "ts": 1716300000000,
  "payload": {"userId": "7"}
}
```

## Response 示例
```json
{
  "id": "s-2001",
  "kind": "response",
  "method": "getUser",
  "reqId": "r-1001",
  "ok": true,
  "done": true,
  "payload": {"name": "Sam"}
}
```

## Error 示例
错误对象结构固定为四字段（见第 13 章）：
```json
{
  "code": "E_METHOD_NOT_FOUND",
  "message": "Method not found: getUser",
  "retryable": false,
  "details": {}
}
```

## 建议实现类
- `BridgeMessage`：消息读写与创建（`fromJson` 解析失败返回 `null`，不抛异常）。
- `BridgeError`：统一错误结构（`code/message/retryable/details`）。
- `BridgeApiContract`：方法名常量与错误码基线。本仓库中它固定了三个保留方法与 8 个协议错误码：
  - 保留方法：`bridge.handshake`（握手）、`runtime.state`（生命周期事件推送）、`bridge.cancelScope`（scope 注销）。
  - 错误码基线：`E_INVALID_MESSAGE`、`E_POLICY_DENY`、`E_ORIGIN_DENY`、`E_METHOD_NOT_ALLOWED`、`E_SESSION_INVALID`、`E_CAPABILITY_DENY`、`E_METHOD_NOT_FOUND`、`E_INTERNAL`。

## 验收清单
1. 能正确解析 request/response/event。
2. 异步响应可通过 `reqId` 关联到请求。
3. 失败回包总是带统一 `error` 对象。
4. 解析非法 JSON 不抛异常（返回 `null` 交给上层静默丢弃）。

## 常见坑
1. 不加 `kind`，导致事件和响应混淆。
2. 不加 `reqId`，并发场景错配。
3. `error` 字段结构不稳定。
4. 错误码散落为内联字面量，而不是收口到 `BridgeApiContract` 常量——四端无法对齐。

## 小结
协议一旦清晰，代码才有长期演进基础。第 4 章开始做请求分发。
