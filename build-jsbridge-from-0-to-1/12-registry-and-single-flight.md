# 第 12 章：结果型扩展与 single-flight 语义

## 本章目标
把相册/文件选择等“系统回调型能力”纳入桥接体系，并解决错配问题。

## 问题背景
结果型能力通常流程是：
1. Native 发起系统页面。
2. 用户操作后系统回调结果。
3. Native 把结果再回给 JS。

如果没有清晰的 pending 设计，并发场景容易错配。

## 设计原则
对照 `extensions/registry` 的实际结构：
1. `BridgeResultRegistry`：SPI，`launchForResult(Intent, BridgeResultCallback)` 负责发起与跟踪，返回 `launchId`（忙碌时返回空串）。
2. `DefaultBridgeResultRegistry`：默认实现，基于 `ComponentActivity.registerForActivityResult`（`ActivityResultLauncher`）。
3. `CompatBridgeResultRegistry`：兼容 `onActivityResult` 的实现，同时实现 `BridgeResultDispatcher`，内部使用固定 `requestCode`（`0x4A42`）。
4. `SingleFlightPendingLaunches`：同一 registry 实例采用 single-flight——同一时刻只有一个在途请求。

## 为什么 single-flight 合理
- 行为确定，跨端语义容易一致。
- 首版实现简单，风险低。
- 可以通过“多实例 registry”支持更高并发，而不是在单实例里混乱并发。

## 错误语义
registry 层用轻量 token（`busy` / `canceled` / `nothing`）描述结果（`BridgeLaunchResult`）；映射到协议错误码是业务 handler 的职责。示例工程 `PickImagePlugin` 的映射：

| token | 协议错误码 |
|-------|-----------|
| `busy` | `E_BUSY` |
| `canceled` | `E_CANCELED` |
| `nothing` | `E_RESULT_EMPTY` |
| 其他失败 | `E_LAUNCH_FAILED` |

## 验收清单
1. 在途时再次发起 `launchForResult`，忙碌回调立即触发、返回空 launchId，稳定映射为 `E_BUSY`。
2. 请求完成后 pending 状态被正确清理（`consume` 取走即清空）。
3. 兼容入口只消费属于自己的 `requestCode`，不会把结果分发给错误请求。

## 常见坑
1. 只存一个 requestCode 槽位但未定义并发语义。
2. 结果回调到来后忘记清理 pending。
3. 错误码不统一，前端无法稳定处理。
4. 在 registry 层直接拼 JS 错误响应，绕过 handler 的 `callback.fail` 出口。

## 小结
结果型扩展是桥接库走向生产的关键一步。第 13 章我们完善错误模型和可观测性。
