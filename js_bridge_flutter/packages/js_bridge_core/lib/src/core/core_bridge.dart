import 'dart:async';
import 'dart:math';

import '../api/bridge_api_contract.dart';
import '../api/bridge_error.dart';
import '../api/bridge_message.dart';
import '../api/trusted_page_context.dart';

/// 传输函数类型：发送消息，返回是否成功。
typedef BridgeTransport = FutureOr<bool> Function(String messageJson);

/// 业务 handler（与 Page 解耦）：仅接收 payload。
typedef NativeHandler = FutureOr<BridgeHandlerResult> Function(dynamic payload);
/// 需要 Page 上下文的高级 handler：显式接收 TrustedPageContext。
typedef NativeHandlerContext = FutureOr<BridgeHandlerResult> Function(
  TrustedPageContext context,
  dynamic payload,
);
typedef NativeStreamingHandler = FutureOr<List<BridgeHandlerResult>> Function(
  dynamic payload,
);
typedef NativeStreamingHandlerContext = FutureOr<List<BridgeHandlerResult>>
    Function(TrustedPageContext context, dynamic payload);

class BridgeHandlerResult {
  const BridgeHandlerResult.success(
    this.payload, {
    this.done = true,
  })  : ok = true,
        error = null;

  const BridgeHandlerResult.failure(this.error)
      : ok = false,
        payload = null,
        done = true;

  final bool ok;
  final dynamic payload;
  final BridgeError? error;
  final bool done;
}

typedef _ContextStreamingHandler = FutureOr<List<BridgeHandlerResult>> Function(
  TrustedPageContext context,
  dynamic payload,
);

/// Tier 1 — 核心协议层。纯消息分发，零 security 依赖。
class CoreBridge {
  CoreBridge({BridgeTransport? transport}) : _transport = transport;

  BridgeTransport? _transport;
  final Map<String, _ContextStreamingHandler> _handlers =
      <String, _ContextStreamingHandler>{};
  final Random _random = Random();
  int _sendFailureCount = 0;

  int get sendFailureCount => _sendFailureCount;

  void attachTransport(BridgeTransport? transport) {
    _transport = transport;
  }

  // MARK: - Handler Registration

  void registerHandler(String method, NativeHandler handler) {
    _handlers[method] = (TrustedPageContext context, dynamic payload) async {
      return <BridgeHandlerResult>[await handler(payload)];
    };
  }

  void registerHandlerWithContext(String method, NativeHandlerContext handler) {
    _handlers[method] = (TrustedPageContext context, dynamic payload) async {
      return <BridgeHandlerResult>[await handler(context, payload)];
    };
  }

  void registerStreamingHandler(String method, NativeStreamingHandler handler) {
    _handlers[method] = (TrustedPageContext context, dynamic payload) async {
      return handler(payload);
    };
  }

  void registerStreamingHandlerWithContext(
    String method,
    NativeStreamingHandlerContext handler,
  ) {
    _handlers[method] = handler;
  }

  // MARK: - Dispatch

  Future<List<String>> dispatch(
    BridgeMessage request,
    TrustedPageContext context,
  ) async {
    final _ContextStreamingHandler? handler = _handlers[request.method];
    if (handler == null) {
      return <String>[
        failResponse(
          request,
          BridgeError(
            code: BridgeApiContract.errorMethodNotFound,
            message: 'Method not found',
          ),
        ).toJsonString(),
      ];
    }
    try {
      final List<BridgeHandlerResult> results =
          await handler(context, request.payload);
      final List<String> responses = <String>[];
      for (final BridgeHandlerResult result in results) {
        if (result.ok) {
          responses.add(
            successResponse(request, result.payload, done: result.done)
                .toJsonString(),
          );
        } else {
          responses.add(failResponse(request, result.error!).toJsonString());
        }
      }
      return responses;
    } catch (error) {
      return <String>[
        failResponse(
          request,
          BridgeError(
            code: BridgeApiContract.errorInternal,
            message: 'handler exception: $error',
          ),
        ).toJsonString(),
      ];
    }
  }

  // MARK: - Event

  String buildEvent({
    required String method,
    required dynamic payload,
    String? sessionId,
  }) {
    return BridgeMessage(
      id: _nextId(),
      sessionId: sessionId ?? '',
      kind: BridgeMessageKind.event,
      method: method,
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    ).toJsonString();
  }

  Future<bool> postEvent({
    required String method,
    required dynamic payload,
    String? sessionId,
  }) async {
    final BridgeTransport? transport = _transport;
    if (transport == null) {
      _sendFailureCount += 1;
      return false;
    }
    final String messageJson = buildEvent(
      method: method,
      payload: payload,
      sessionId: sessionId,
    );
    try {
      final bool sent = await transport(messageJson);
      if (!sent) {
        _sendFailureCount += 1;
      }
      return sent;
    } catch (_) {
      _sendFailureCount += 1;
      return false;
    }
  }

  // MARK: - Response Builders

  BridgeMessage successResponse(
    BridgeMessage request,
    dynamic payload, {
    required bool done,
  }) {
    return BridgeMessage(
      id: _nextId(),
      sessionId: request.sessionId,
      kind: BridgeMessageKind.response,
      method: request.method,
      ts: DateTime.now().millisecondsSinceEpoch,
      timeoutMs: request.timeoutMs,
      keep: request.keep,
      payload: payload,
      reqId: request.id,
      done: done,
      ok: true,
    );
  }

  BridgeMessage failResponse(BridgeMessage request, BridgeError error) {
    return BridgeMessage(
      id: _nextId(),
      sessionId: request.sessionId,
      kind: BridgeMessageKind.response,
      method: request.method,
      ts: DateTime.now().millisecondsSinceEpoch,
      timeoutMs: request.timeoutMs,
      keep: request.keep,
      reqId: request.id,
      done: true,
      ok: false,
      error: error,
    );
  }

  /// 通过已绑定的 transport 发送预构建的 JSON 字符串。
  /// 供 bindTransport 闭环使用；与 Android 的 respondSuccess/respondFail 对齐。
  Future<bool> sendViaTransport(String messageJson) async {
    final BridgeTransport? transport = _transport;
    if (transport == null) {
      _sendFailureCount += 1;
      return false;
    }
    try {
      final bool sent = await transport(messageJson);
      if (!sent) {
        _sendFailureCount += 1;
      }
      return sent;
    } catch (_) {
      _sendFailureCount += 1;
      return false;
    }
  }

  void destroy() {
    _transport = null;
  }

  String _nextId() {
    return '${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(1 << 32)}';
  }
}
