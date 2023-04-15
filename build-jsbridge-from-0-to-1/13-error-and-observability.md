# 第 13 章：错误模型与可观测性

## 本章目标
让故障可以被识别、定位、统计，而不是“只知道失败了”。

## 为什么错误模型很重要
如果错误是随手 `throw new Exception("xxx")`：
- JS 无法分类处理。
- 日志无法聚合统计。
- 线上问题无法快速归因。

## 统一错误模型
`BridgeError` 固定四字段：
- `code`：机器可识别错误码。
- `message`：人类可读说明。
- `retryable`：是否建议重试。
- `details`：附加信息（JSON 对象，默认空）。

配套 `BridgeError.normalize(...)`：把 `Throwable`、`JSONObject`、`String` 等任意形态的失败统一归一——平台原生异常必须归一为 `E_INTERNAL`，不得把异常栈直接透传给 JS。

## 错误码基线
协议基线错误码收口在 `BridgeApiContract`（四端一致，禁止策略/handler 内联字面量）：

| 层 | 错误码 |
|----|--------|
| 协议层（RequestShapePolicy） | `E_INVALID_MESSAGE` |
| 策略层（HandshakeGatePolicy） | `E_POLICY_DENY` |
| 策略层（AccessControlPolicy） | `E_ORIGIN_DENY`、`E_METHOD_NOT_ALLOWED`、`E_SESSION_INVALID`、`E_CAPABILITY_DENY` |
| 路由层（dispatch） | `E_METHOD_NOT_FOUND` |
| 运行时（handler 异常兜底） | `E_INTERNAL` |
| 结果型扩展（业务映射） | `E_BUSY`、`E_CANCELED`、`E_RESULT_EMPTY`、`E_LAUNCH_FAILED` |

业务错误码（如示例工程的 `E_REQUEST_FAILED`）可在此之外自定义。JS 客户端另有 `E_TIMEOUT`（等待响应超时）。

## 可观测性（日志）
策略拒绝的审计日志记录（`JsBridge.auditReject`）：
- `rule`（拒绝策略名）
- `method`
- `origin`
- `pageInstanceId`
- `sessionId`
- `code`

发送侧可观测：`CoreBridge` 对每条发送失败的 response/event 记录 `bridge_send_failed` 日志（含 method/reqId/ok），并递增 `getSendFailureCount()` 计数——conformance C17 验证该行为。

## 验收清单
1. 每条失败响应都带标准错误对象（`code/message/retryable/details`）。
2. 关键拒绝路径都有结构化日志，能定位到策略规则与上下文。
3. 通过错误码可区分“可重试”与“不可重试”。

## 常见坑
1. 直接把底层异常文案透传给前端。
2. 只有 message 没有 code。
3. 日志没有上下文键值，无法检索。
4. 各端各自发明错误码——违反协议一致性原则。

## 小结
错误模型是“系统自解释能力”。第 14 章我们把质量保障落到分层测试。
