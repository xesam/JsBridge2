import 'dart:async';
import 'dart:math';

import '../api/bridge_api_contract.dart';
import '../api/bridge_error.dart';
import '../api/bridge_message.dart';
import '../api/trusted_page_context.dart';

/// 传输函数类型：发送消息，返回是否成功。
typedef BridgeTransport = FutureOr<bool> Function(String messageJson);

// MARK: - Handler API

/// Simple Handler: 单帧响应，通信在返回时结束；page context 为第一形参。
typedef SimpleHandler = FutureOr<BridgeHandlerResult> Function(
  TrustedPageContext context,
  dynamic payload,
);

/// Response Emitter: 异步多响应发送器
typedef ResponseEmitter = Future<void> Function(
  Result<dynamic, BridgeError> result,
  bool done,
);

/// Async Handler: 带 ResponseEmitter 参数，可在返回后继续推帧；page context 为第一形参。
typedef AsyncHandler = Future<void> Function(
  TrustedPageContext context,
  dynamic payload,
  ResponseEmitter? emitter,
);

/// Result type for ResponseEmitter
class Result<T, E> {
  final T? value;
  final E? error;
  final bool isSuccess;

  const Result.success(this.value)
      : error = null,
        isSuccess = true;

  const Result.failure(this.error)
      : value = null,
        isSuccess = false;
}

/// Simple handler 是单帧语义：`done` 恒为 true，多帧只能由 [AsyncHandler] 表达。
class BridgeHandlerResult {
  const BridgeHandlerResult.success(this.payload)
      : ok = true,
        error = null;

  /// [error] 必填（fail 帧不携带 error 属协议违例——JS 侧只能挂死到超时）。
  const BridgeHandlerResult.failure(this.error)
      : ok = false,
        payload = null;

  final bool ok;
  final dynamic payload;
  final BridgeError? error;
}

typedef _ContextHandler = FutureOr<BridgeHandlerResult> Function(
  TrustedPageContext context,
  dynamic payload,
);

enum _InternalHandlerType { sync, async }

class _InternalHandler {
  final _InternalHandlerType type;
  final _ContextHandler? syncHandler;
  final AsyncHandler? asyncHandler;

  const _InternalHandler.sync(this.syncHandler)
      : type = _InternalHandlerType.sync,
        asyncHandler = null;

  const _InternalHandler.async(this.asyncHandler)
      : type = _InternalHandlerType.async,
        syncHandler = null;
}

/// Tier 1 — 核心协议层。纯消息分发，零 security 依赖。
class CoreBridge {
  CoreBridge({BridgeTransport? transport}) : _transport = transport;

  BridgeTransport? _transport;
  final Map<String, _InternalHandler> _handlers = <String, _InternalHandler>{};
  final Random _random = Random();
  // send 失败只写计数（供调试），可观测性由 postEvent 返回值断言承载（conformance C17）。
  // ignore: unused_field
  int _sendFailureCount = 0;

  /// 是否已注入 transport（bindTransport 闭环装配期 fail-fast 判断用）。
  bool get hasTransport => _transport != null;

  void attachTransport(BridgeTransport? transport) {
    _transport = transport;
  }

  // MARK: - Handler Registration

  /// Register a Simple Handler: single-response, communication ends when handler returns
  void registerSimpleHandler(String method, SimpleHandler handler) {
    _handlers[method] = _InternalHandler.sync(handler);
  }

  /// Register an Async Handler: multi-response with ResponseEmitter, can push frames after return
  void registerAsyncHandler(String method, AsyncHandler handler) {
    _handlers[method] = _InternalHandler.async(handler);
  }

  // MARK: - Dispatch

  Future<List<String>> dispatch(
    BridgeMessage request,
    TrustedPageContext context,
  ) async {
    // Tier-1 kind 路由守卫（docs/09 C64 / docs/08 dispatch 契约）：仅 request 信封参与派发。
    // response/event 是 Native→JS 方向（docs/03 §1），standalone 使用 CoreBridge 时按 method
    // 命中同名 handler 属协议路由错误而非"无策略"自由；JsBridge 路径已在策略链
    // RequestShapePolicy 先行拒绝，此处为 belt-and-braces（Dart 端无日志设施，静默丢弃由验收锚定）。
    if (request.kind != BridgeMessageKind.request) {
      return const <String>[];
    }
    final _InternalHandler? handler = _handlers[request.method];
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

    switch (handler.type) {
      case _InternalHandlerType.sync:
        // 同步 handler：单帧响应，done 恒为 true
        try {
          final BridgeHandlerResult result =
              await handler.syncHandler!(context, request.payload);
          if (result.ok) {
            return <String>[
              successResponse(request, result.payload, done: true).toJsonString(),
            ];
          }
          // failure 不携带 error 属协议违例——归一化为 E_INTERNAL
          return <String>[
            failResponse(
              request,
              result.error ??
                  BridgeError(
                    code: BridgeApiContract.errorInternal,
                    message: 'handler emitted failure without error',
                  ),
            ).toJsonString(),
          ];
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

      case _InternalHandlerType.async:
        final String requestId = request.id;
        final String sessionId = request.sessionId;
        final String method = request.method;
        final int timeoutMs = request.timeoutMs;
        final bool keep = request.keep;
        final dynamic payload = request.payload;

        // ignore: unawaited_futures — 任务体内部已全量 catch，无错误外逃
        Future<void>(() async {
          Future<void> emitter(
            Result<dynamic, BridgeError> result,
            bool done,
          ) async {
            final BridgeMessage response;
            if (result.isSuccess) {
              response = BridgeMessage(
                id: _nextId(),
                sessionId: sessionId,
                kind: BridgeMessageKind.response,
                method: method,
                ts: DateTime.now().millisecondsSinceEpoch,
                timeoutMs: timeoutMs,
                keep: keep,
                payload: result.value,
                reqId: requestId,
                done: done,
                ok: true,
              );
            } else {
              response = BridgeMessage(
                id: _nextId(),
                sessionId: sessionId,
                kind: BridgeMessageKind.response,
                method: method,
                ts: DateTime.now().millisecondsSinceEpoch,
                timeoutMs: timeoutMs,
                keep: keep,
                reqId: requestId,
                done: true,
                ok: false,
                // failure 缺 error 与 Simple 路径同语义归一化（协议违例不得静默吞帧）
                error: result.error ??
                    BridgeError(
                      code: BridgeApiContract.errorInternal,
                      message: 'async handler emitted failure without error',
                    ),
              );
            }
            await sendViaTransport(response.toJsonString());
          }

          try {
            await handler.asyncHandler!(context, payload, emitter);
          } catch (error) {
            final BridgeMessage errorResponse = BridgeMessage(
              id: _nextId(),
              sessionId: sessionId,
              kind: BridgeMessageKind.response,
              method: method,
              ts: DateTime.now().millisecondsSinceEpoch,
              timeoutMs: timeoutMs,
              keep: keep,
              reqId: requestId,
              done: true,
              ok: false,
              error: BridgeError(
                code: BridgeApiContract.errorInternal,
                message: 'async handler exception: $error',
              ),
            );
            await sendViaTransport(errorResponse.toJsonString());
          }
        });
        return <String>[];
    }
  }

  // MARK: - Event

  // v1 事件帧 sessionId 恒为空串 ""（广播唯一形态，docs/03 §3.3 / C55）——
  // 无 sessionId 形参，与 Android / iOS / HarmonyOS 四端对齐。
  String _buildEvent({
    required String method,
    required dynamic payload,
  }) {
    return BridgeMessage(
      id: _nextId(),
      sessionId: '',
      kind: BridgeMessageKind.event,
      method: method,
      ts: DateTime.now().millisecondsSinceEpoch,
      payload: payload,
    ).toJsonString();
  }

  Future<bool> postEvent({
    required String method,
    required dynamic payload,
  }) async {
    // 先判空再构帧——与其余三端同形（Android/iOS/Harmony 均于 transport 空时
    // 短路返回，不为注定丢弃的帧支付构帧 + 序列化开销），计数语义同 sendViaTransport。
    if (_transport == null) {
      _sendFailureCount += 1;
      return false;
    }
    return sendViaTransport(_buildEvent(method: method, payload: payload));
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
