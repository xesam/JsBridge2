# 第 11 章：生命周期与事件扩展

## 本章目标
实现 Native 主动通知 JS 的事件通道，支持页面状态同步。

## 核心概念
前面章节都是“请求-响应”模式，本章加入“主动推送”模式：
- 不依赖 JS 发起请求。
- Native 可在生命周期节点发事件。

## 事件格式
沿用 `BridgeMessage`，`kind = event`。协议保留方法名为 `runtime.state`（`BridgeApiContract.METHOD_LIFECYCLE`），payload 结构固定为 `{state, seq}`：

```json
{
  "id": "e-3001",
  "kind": "event",
  "method": "runtime.state",
  "payload": {"state": "resumed", "seq": 3}
}
```

约束（`docs/01-protocol.md §7.2`）：
- `state` 取值由宿主自定义（示例工程使用 `created/started/resumed/paused/stopped/destroyed`）。
- `seq` 从 1 单调递增，跟随发布者实例生命周期，不随 `resetForNewPage()` 重置。

## 扩展示例：LifecycleExtension
`extensions/lifecycle/LifecycleExtension` 是 Tier 3 可选扩展（默认不接线）：
- `onHostEvent(String state)`：宿主在 `onStart/onResume/...` 中调用。
- 内部调用 `bridge.postEvent(BridgeApiContract.METHOD_LIFECYCLE, payload)`。

未 ready 时的排队补发语义：
- `bridge.postEvent` 未 ready 时返回 `false`，事件进入 FIFO 队列（默认上限 32，超限丢弃最旧）。
- 构造时通过 `bridge.addReadyListener` 注册回调，握手成功后按序补发；补发中途失败则剩余事件保留在队列。
- 队列不随页面重置清空。

## 实现要点
- 扩展只表达状态，不耦合业务逻辑。
- JS 侧通过统一监听 `runtime.state` 方法名处理生命周期（共享 WebAssets 的 `jsbridge-sdk.js` 已内置）。
- 事件与握手响应可能乱序到达，客户端对 `sessionId` 为空串的事件无条件派发（conformance C22）。

## 验收清单
1. JS 能收到并消费宿主生命周期事件（`{state, seq}` 结构）。
2. 页面切换重绑后事件仍稳定（seq 持续递增）。
3. 未 ready 时事件入队，握手后按原顺序补发（conformance C28）。

## 常见坑
1. 事件名随意（如自造 `lifecycle` 方法名），前端兼容成本高——必须用保留方法 `runtime.state`。
2. `postEvent` 返回 `false` 后既不排队也不记日志，事件静默丢失。
3. 在生命周期回调里直接写业务判断，扩展职责不清。
4. seq 从 0 开始或不单调，前端无法检测丢帧。

## 小结
事件通道让 Bridge 从“被动服务端”变成“双向事件系统”。第 12 章处理结果型扩展与并发一致性。
