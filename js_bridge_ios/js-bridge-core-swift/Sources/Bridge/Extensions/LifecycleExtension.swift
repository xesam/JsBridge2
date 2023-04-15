import Foundation

/// Tier 3 — lifecycle 事件发布器。未 ready 时事件入 FIFO 队列（上限 maxPendingEvents，
/// 超限丢最旧）；每次握手成功后按序 flush。seq 跟随本实例生命周期，不随页面重置。
/// 语义与 Android extensions/lifecycle/LifecycleExtension.java 逐行对齐。
public final class LifecycleExtension {
    private let bridge: JsBridge
    private let maxPendingEvents: Int
    private var pendingEvents: [JSONValue] = []
    private var seq: Int = 0

    public init(bridge: JsBridge, maxPendingEvents: Int = 32) {
        self.bridge = bridge
        self.maxPendingEvents = max(1, maxPendingEvents)
        bridge.addReadyListener { [weak self] in
            self?.flushPending()
        }
    }

    public func onHostEvent(state: String) {
        seq += 1
        let payload: JSONValue = .object([
            "state": .string(state),
            "seq": .number(Double(seq))
        ])
        if bridge.postEvent(method: BridgeApiContract.methodLifecycle, payload: payload) {
            return
        }
        pendingEvents.append(payload)
        if pendingEvents.count > maxPendingEvents {
            pendingEvents.removeFirst()
        }
    }

    private func flushPending() {
        while !pendingEvents.isEmpty {
            let event = pendingEvents.removeFirst()
            if !bridge.postEvent(method: BridgeApiContract.methodLifecycle, payload: event) {
                pendingEvents.append(event)
                return
            }
        }
    }
}
