import 'dart:async';
import 'dart:math';

import 'api/bridge_api_contract.dart';
import 'package:meta/meta.dart';

import 'api/bridge_error.dart';
import 'api/bridge_message.dart';
import 'api/origin_normalizer.dart';
import 'api/trusted_page_context.dart';
import 'core/core_bridge.dart';
import 'security/policy_engine.dart';
import 'security/session_record.dart';
import 'security/session_service.dart';

/// 内核派生 TrustedPageContext 的注入点（与 Android/iOS/HarmonyOS 一致）。
abstract class PageContextProvider {
  TrustedPageContext createContext(BridgeMessage message, String pageInstanceId);
}

/// 安全配置，提供统一的低层控制字段（与 Android/iOS/HarmonyOS 对齐）。
///
/// [allowedOrigins] 和 [methodWhitelist]：
///   - {"*"}  = 显式不限制，对应节点不进策略链
///   - 具体值 = 启用该维度白名单校验
///   - SecurityConfig 对象存在时两者必填（null 在构造期抛出 ArgumentError）
/// [methodWhitelist] 语义详见 [BridgeApiContract.protocolMethods] 文档。
class SecurityConfig {
  static const int defaultSessionTtlMs = 15 * 60 * 1000;
  static const String defaultPolicyVersion = 'v1';

  SecurityConfig({
    this.allowedOrigins,
    this.methodWhitelist,
    this.extraPolicies = const <ExtraPolicy>[],
    this.policyVersion = defaultPolicyVersion,
    this.sessionTtlMs = defaultSessionTtlMs,
  });

  final Set<String>? allowedOrigins;
  final Set<String>? methodWhitelist;
  final List<ExtraPolicy> extraPolicies;
  final String policyVersion;
  final int sessionTtlMs;

  void validate() {
    if (allowedOrigins == null) {
      throw ArgumentError(
        'SecurityConfig: allowedOrigins is required. '
        'Use {"*"} to allow all origins, '
        'or supply specific origins.',
      );
    }
    if (methodWhitelist == null) {
      throw ArgumentError(
        'SecurityConfig: methodWhitelist is required. '
        'Use {"*"} to allow all methods, '
        'or supply specific methods.',
      );
    }
  }
}

typedef ExtraPolicy = BridgeError? Function(
  BridgeMessage request,
  TrustedPageContext context,
);

class _ExtraPolicyAdapter implements PolicyRule {
  const _ExtraPolicyAdapter(this._policy);
  final ExtraPolicy _policy;

  @override
  BridgeError? evaluate(PolicyInput input) {
    return _policy(input.message, input.context);
  }
}

/// Tier 2 — 会话/策略/握手层，叠加在 CoreBridge 之上。
class JsBridge {
  static const int _maxReadyListeners = 32;

  JsBridge({
    SecurityConfig? securityConfig,
    PageContextProvider? pageContextProvider,
    BridgeTransport? transport,
  })  : _securityConfig = securityConfig,
        policyVersion = securityConfig?.policyVersion ??
            SecurityConfig.defaultPolicyVersion,
        sessionTtlMs = securityConfig?.sessionTtlMs ??
            SecurityConfig.defaultSessionTtlMs,
        _pageContextProvider = pageContextProvider,
        _core = CoreBridge(transport: transport) {
    securityConfig?.validate();
    // 装配期（构造时刻）即构建并冻结策略链：防御性拷贝快照生效于此，
    // 宿主此后 mutate 传入的 Set 不得影响已装配策略。
    _policyEngine = _buildPolicyEngine();
  }

  final SecurityConfig? _securityConfig;
  final String policyVersion;
  final int sessionTtlMs;
  PageContextProvider? _pageContextProvider;
  final CoreBridge _core;

  final SessionService _sessionService = SessionService();
  final Random _random = Random();
  bool _ready = false;
  String _pageInstanceId = _nextIdStatic();
  final List<void Function()> _readyListeners = <void Function()>[];
  bool _readyNotificationPending = false;

  late final PolicyEngine _policyEngine;

  PolicyEngine _buildPolicyEngine() {
    final List<PolicyRule> rules = <PolicyRule>[const RequestShapePolicy()];
    final SecurityConfig? config = _securityConfig;
    if (config != null) {
      rules.add(const HandshakeGatePolicy());
      // allowedOrigins 非 {"*"} 时才进链；装配期防御性拷贝，
      // 宿主构造后 mutate 传入 Set 不得静默改变已装配策略（与 MethodGatePolicy 对称）
      final Set<String>? origins = config.allowedOrigins;
      if (origins != null && !origins.contains('*')) {
        rules.add(OriginPolicy(allowedOrigins: Set<String>.of(origins)));
      }
      // methodWhitelist 非 {"*"} 时才进链；协议方法由框架自动并入放行集
      // （语义详见 BridgeApiContract.protocolMethods 文档）
      final Set<String>? methods = config.methodWhitelist;
      if (methods != null && !methods.contains('*')) {
        rules.add(MethodGatePolicy(
          methodWhitelist: <String>{...methods, ...BridgeApiContract.protocolMethods},
        ));
      }
      rules.add(const SessionPolicy());
      for (final ExtraPolicy ep in config.extraPolicies) {
        rules.add(_ExtraPolicyAdapter(ep));
      }
    }
    return PolicyEngine(rules);
  }

  bool get isReady => _ready;

  void addReadyListener(void Function() listener) {
    if (_readyListeners.length >= _maxReadyListeners) {
      throw StateError('JsBridge: ready listener limit reached');
    }
    _readyListeners.add(listener);
  }

  void attachTransport(BridgeTransport? transport) {
    _core.attachTransport(transport);
  }

  /// 绑定入站消息处理闭环，返回一个可传给 JavaScriptChannel.onMessageReceived 的回调。
  /// 调用前须先 attachTransport 并注入 PageContextProvider，否则 fail-fast 抛 StateError
  /// （配置错误应在装配期暴露，而非运行期每条消息静默丢响应或抛 ArgumentError 逃逸为 zone error）。
  /// 每次调用返回新的 handler 闭包，内部捕获最新的 transport。
  /// 次序保证：握手响应先于 ready listener 副作用（如 lifecycle 补发）写入 transport。
  Future<void> Function(String) bindTransport() {
    if (!_core.hasTransport) {
      throw StateError(
        'JsBridge: bindTransport() requires a transport to be attached first; '
        'pass one via the constructor or call attachTransport(...) '
        'before bindTransport().',
      );
    }
    if (_pageContextProvider == null) {
      throw StateError(
        'JsBridge: bindTransport() requires a PageContextProvider; '
        'inject one via the constructor or attachPageContextProvider(...) '
        'before bindTransport().',
      );
    }
    return (String messageJson) async {
      try {
        final List<String> responses = await _processIncomingUnchecked(messageJson);
        for (final String response in responses) {
          await _core.sendViaTransport(response);
        }
      } catch (_) {
        // 兜底：单条消息处理异常不逃逸为 zone error（fail-fast 已保证装配期检查，
        // 此处仅防御运行期意外，与畸形消息静默丢弃口径一致）。
      }
      _flushReadyNotification();
    };
  }

  /// 触发已就绪但尚未通知的 ready listeners（幂等；每轮握手只通知一次）。
  void _flushReadyNotification() {
    if (!_readyNotificationPending) {
      return;
    }
    _readyNotificationPending = false;
    for (final void Function() listener in _readyListeners) {
      listener();
    }
  }

  void attachPageContextProvider(PageContextProvider provider) {
    _pageContextProvider = provider;
  }

  void resetPageInstance() {
    _ready = (_securityConfig == null);  // null = 立即 ready；非 null = 等待握手
    _readyNotificationPending = false;
    _sessionService.clearByPageInstance(_pageInstanceId);
    _pageInstanceId = _nextId();
  }

  void destroy() {
    _sessionService.clearAll();
    _core.destroy();
    // 复用防泄漏：宿主复用同一实例重新 bindTransport()/resetPageInstance() 时，
    // 旧 listener 不得再被回调（四端同步语义）
    _readyListeners.clear();
  }

  void registerSimpleHandler(String method, SimpleHandler handler) {
    _core.registerSimpleHandler(method, handler);
  }

  void registerAsyncHandler(String method, AsyncHandler handler) {
    _core.registerAsyncHandler(method, handler);
  }

  // Message Processing

  /// 手动处理入站消息并返回响应串数组（由调用方自行发送）。
  ///
  /// 次序语义（与 iOS/HarmonyOS 的同名入口一致，跨端契约）：本方法在本轮处理
  /// 完成时**立即**触发已就绪的 ready listeners（可能同步产生 lifecycle 事件帧），
  /// 此时握手响应串刚要返回给调用方——事件帧可能先于握手响应帧抵达 JS。严格的
  /// "握手响应先于 ready 副作用"次序只在 [bindTransport] 闭环内保证（响应先写入
  /// transport 再 flush）；JS 侧 lifecycle 扩展按 docs/03 §7.2 对未 ready 事件排队
  /// 补发，故此乱序在端到端语义上被掩盖。需要严格次序的宿主应使用 [bindTransport]。
  Future<List<String>> processIncomingResponses({
    required String messageJson,
  }) async {
    final List<String> responses = await _processIncomingUnchecked(messageJson);
    _flushReadyNotification();
    return responses;
  }

  /// 测试注入面：以显式 origin 构造 TrustedPageContext。
  /// origin 在入口经 [OriginNormalizer.normalize] 归一化（与 provider 路径同一
  /// 约束——fail-closed，非层级形态归一化为空串永不命中白名单）。
  /// 生产宿主走 bindTransport() 闭环 + PageContextProvider，勿用本入口。
  @visibleForTesting
  Future<List<String>> processIncomingResponsesWithOrigin({
    required String messageJson,
    required String origin,
  }) async {
    final BridgeMessage request;
    try {
      request = BridgeMessage.fromJsonString(messageJson);
    } catch (_) {
      return <String>[];
    }
    final List<String> responses = await _processIncomingResponsesForContextCore(
      request: request,
      context: TrustedPageContext(
        origin: OriginNormalizer.normalize(origin),
        pageInstanceId: _pageInstanceId,
      ),
    );
    _flushReadyNotification();
    return responses;
  }

  Future<List<String>> _processIncomingUnchecked(String messageJson) async {
    final PageContextProvider? provider = _pageContextProvider;
    if (provider == null) {
      throw ArgumentError(
        'processIncomingResponses(messageJson:) requires a PageContextProvider; '
        'inject one via the constructor or attachPageContextProvider(...).',
      );
    }
    final BridgeMessage request;
    try {
      request = BridgeMessage.fromJsonString(messageJson);
    } catch (_) {
      return <String>[];
    }
    final TrustedPageContext context =
        provider.createContext(request, _pageInstanceId);
    return _processIncomingResponsesForContextCore(
      request: request,
      context: context,
    );
  }

  /// 测试注入面：以显式 TrustedPageContext 驱动策略链（生产宿主走
  /// bindTransport() 闭环 + PageContextProvider，勿用本入口）。
  @visibleForTesting
  Future<List<String>> processIncomingResponsesForContext({
    required String messageJson,
    required TrustedPageContext context,
  }) async {
    // 入站只解析一次：解析失败静默丢弃（畸形消息不进策略链，docs/03 §3.4）
    final BridgeMessage request;
    try {
      request = BridgeMessage.fromJsonString(messageJson);
    } catch (_) {
      return <String>[];
    }
    final List<String> responses = await _processIncomingResponsesForContextCore(
      request: request,
      context: context,
    );
    _flushReadyNotification();
    return responses;
  }

  Future<List<String>> _processIncomingResponsesForContextCore({
    required BridgeMessage request,
    required TrustedPageContext context,
  }) async {
    final SessionRecord? session = _sessionService.find(request.sessionId);
    final BridgeError? deny = _policyEngine.evaluate(PolicyInput(
      message: request,
      context: context,
      ready: _ready,
      sessionRecord: session,
    ));
    if (deny != null) {
      // fail-closed（docs/03 §9 细则 3）：任何策略拒绝都必须返回错误响应，
      // deny 未携带有效错误码时以 E_POLICY_DENY 兜底，禁止静默放行到 dispatch（验收锚点 C53）。
      final BridgeError effectiveDeny = deny.code.isEmpty
          ? const BridgeError(
              code: BridgeApiContract.errorPolicyDeny,
              message: 'policy denied',
            )
          : deny;
      return <String>[_core.failResponse(request, effectiveDeny).toJsonString()];
    }

    if (request.method == BridgeApiContract.methodCancelScope) {
      final dynamic rawPayload = request.payload;
      final dynamic rawScopeId =
          rawPayload is Map ? rawPayload['scopeId'] : null;
      return <String>[
        _core
            .successResponse(
              request,
              <String, dynamic>{
                'scopeId': rawScopeId is String ? rawScopeId : '',
                'accepted': true,
              },
              done: true,
            )
            .toJsonString(),
      ];
    }

    if (request.method == BridgeApiContract.methodHandshake) {
      final SessionRecord record = _sessionService.issue(
        context: context,
        ttlMs: sessionTtlMs,
      );
      _ready = true;
      _readyNotificationPending = true;
      final List<String> handshakeResponses = <String>[
        _core
            .successResponse(
              request,
              <String, dynamic>{
                'sessionId': record.sessionId,
                'sessionTtlMs': sessionTtlMs,
                'policyVersion': policyVersion,
                'origin': context.origin,
                'accepted': true,
              },
              done: true,
            )
            .toJsonString(),
      ];
      return handshakeResponses;
    }

    return _core.dispatch(request, context);
  }

  /// 协议裁决（docs/03 §3.3 + C55）：v1 事件投放唯一形态为广播——事件帧
  /// sessionId 恒为空串 ""，禁止默认归属最近一次握手的 session（多 WebView
  /// 场景会将事件错投向最近握手的页面）。API 为两参 postEvent(method, payload)，
  /// 与 Android / iOS / HarmonyOS 四端对齐；定向投送不属于 v1 能力面，
  /// 引入须作为契约变更先登记验收用例（docs/09 §6）。
  Future<bool> postEvent({
    required String method,
    required dynamic payload,
  }) async {
    if (!_ready) return false;
    return _core.postEvent(
      method: method,
      payload: payload,
    );
  }

  String _nextId() {
    return '${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(1 << 32)}';
  }
}

String _nextIdStatic() {
  return DateTime.now().microsecondsSinceEpoch.toString();
}
