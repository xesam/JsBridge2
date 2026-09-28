import '../api/bridge_api_contract.dart';
import '../js_bridge.dart';

/// Tier 3 — lifecycle 事件发布器。postEvent 返回 false 时事件入 FIFO 队列（上限 maxPendingEvents，
/// 超限丢最旧）；每次握手成功后按序 flush。seq 跟随本实例生命周期，不随页面重置。
/// 语义对齐 Android extensions/lifecycle/LifecycleExtension.java；差异点：Dart 的
/// postEvent 是异步的，故另加 _enqueueOp 串行链保证事件不因 await 交错而乱序
/// （Android / iOS 为同步 postEvent，无此需求）。
class LifecycleExtension {
  LifecycleExtension(this._bridge, {int maxPendingEvents = 32})
      : _maxPendingEvents = maxPendingEvents < 1 ? 1 : maxPendingEvents {
    _bridge.addReadyListener(() {
      // ready 监听为同步回调，flush 内部按序 await，事件发起顺序保持不变。
      _flushPending();
    });
  }

  final JsBridge _bridge;
  final int _maxPendingEvents;
  final List<Map<String, dynamic>> _pendingEvents = <Map<String, dynamic>>[];
  int _seq = 0;
  Future<void> _tail = Future<void>.value();

  Future<void> onHostEvent(String state) {
    _seq += 1;
    final Map<String, dynamic> payload = <String, dynamic>{
      'state': state,
      'seq': _seq,
    };
    return _enqueueOp(() async {
      final bool sent = await _bridge.postEvent(
        method: BridgeApiContract.methodLifecycle,
        payload: payload,
      );
      if (!sent) {
        _pendingEvents.add(payload);
        if (_pendingEvents.length > _maxPendingEvents) {
          _pendingEvents.removeAt(0);
        }
      }
    });
  }

  void _flushPending() {
    _enqueueOp(() async {
      while (_pendingEvents.isNotEmpty) {
        final Map<String, dynamic> event = _pendingEvents.removeAt(0);
        final bool sent = await _bridge.postEvent(
          method: BridgeApiContract.methodLifecycle,
          payload: event,
        );
        if (!sent) {
          _pendingEvents.add(event);
          return;
        }
      }
    });
  }

  Future<void> _enqueueOp(Future<void> Function() op) {
    _tail = _tail.then((_) => op());
    return _tail;
  }
}
