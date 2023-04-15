import 'dart:async';
import 'dart:math';

import 'api/bridge_api_contract.dart';
import 'api/bridge_error.dart';
import 'api/bridge_message.dart';
import 'api/trusted_page_context.dart';
import 'core/core_bridge.dart';
import 'security/policy_engine.dart';
import 'security/session_record.dart';
import 'security/session_service.dart';

/// 内核派生 TrustedPageContext 的注入点（与 Android/iOS/HM 一致）。
abstract class PageContextProvider {
  TrustedPageContext createContext(BridgeMessage message, String pageInstanceId);
}

/// 安全分级配置，作为 Level 0/1/2 心智模型的类型载体（与其余三端对齐）。
class SecurityConfig {
  SecurityConfig({
    Set<String>? allowedOrigins,
    this.methodWhitelist = const <String>{},
    this.defaultCapabilities = const <String>{},
    this.extraPolicies = const <ExtraPolicy>[],
    this.policyVersion = '1',
    this.sessionTtlMs = 15 * 60 * 1000,
    this.requireHandshake = false,
    this.requireAccessControl = false,
  }) : allowedOrigins = allowedOrigins ?? <String>{'*'};

  factory SecurityConfig.secure() =>
      SecurityConfig().withHandshakeGate().withAccessControl();

  Set<String> allowedOrigins;
  Set<String> methodWhitelist;
  Set<String> defaultCapabilities;
  List<ExtraPolicy> extraPolicies;
  String policyVersion;
  int sessionTtlMs;
  bool requireHandshake;
  bool requireAccessControl;

  SecurityConfig withHandshakeGate() {
    requireHandshake = true;
    return this;
  }

  SecurityConfig withAccessControl() {
    requireAccessControl = true;
    return this;
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
  String get name => 'ExtraPolicy';

  @override
  BridgeError? evaluate(PolicyInput input) {
    return _policy(input.message, input.context);
  }
}

/// Tier 2 — 会话/策略/握手层，叠加在 CoreBridge 之上。
class JsBridge {
  JsBridge({
    required SecurityConfig securityConfig,
    PageContextProvider? pageContextProvider,
    BridgeTransport? transport,
    this.maxReadyListeners = 32,
  })  : allowedOrigins = securityConfig.allowedOrigins,
        methodWhitelist = securityConfig.methodWhitelist,
        defaultCapabilities = securityConfig.defaultCapabilities,
        policyVersion = securityConfig.policyVersion,
        sessionTtlMs = securityConfig.sessionTtlMs,
        extraPolicies = securityConfig.extraPolicies,
        requireHandshake = securityConfig.requireHandshake,
        requireAccessControl = securityConfig.requireAccessControl,
        _pageContextProvider = pageContextProvider,
        _core = CoreBridge(transport: transport) {
    if (requireAccessControl && allowedOrigins.contains('*')) {
      throw ArgumentError(
        'JsBridge: AccessControlPolicy enabled but allowedOrigins is '
        'wildcard "*". Explicitly set allowedOrigins to obtain real origin protection; '
        'use Level 1 (withHandshakeGate only) if origin checks are not required.',
      );
    }
  }

  final Set<String> allowedOrigins;
  final Set<String> methodWhitelist;
  final Set<String> defaultCapabilities;
  final String policyVersion;
  final int sessionTtlMs;
  final List<ExtraPolicy> extraPolicies;
  final bool requireHandshake;
  final bool requireAccessControl;
  final int maxReadyListeners;
  PageContextProvider? _pageContextProvider;
  final CoreBridge _core;

  final SessionService _sessionService = SessionService();
  final Random _random = Random();
  bool _ready = false;
  String _pageInstanceId = _nextIdStatic();
  SessionRecord? _currentSession;
  final List<void Function()> _readyListeners = <void Function()>[];

  late final PolicyEngine _policyEngine = _buildPolicyEngine();

  PolicyEngine _buildPolicyEngine() {
    final List<PolicyRule> rules = <PolicyRule>[const RequestShapePolicy()];
    if (requireHandshake) {
      rules.add(const HandshakeGatePolicy());
    }
    if (requireAccessControl) {
      rules.add(AccessControlPolicy(
        allowedOrigins: allowedOrigins,
        methodWhitelist: methodWhitelist,
      ));
    }
    for (final ExtraPolicy ep in extraPolicies) {
      rules.add(_ExtraPolicyAdapter(ep));
    }
    return PolicyEngine(rules);
  }

  bool get isReady => _ready;
  SessionRecord? get currentSession => _currentSession;
  int get sendFailureCount => _core.sendFailureCount;

  void addReadyListener(void Function() listener) {
    if (_readyListeners.length >= maxReadyListeners) {
      throw StateError('JsBridge: ready listener limit reached');
    }
    _readyListeners.add(listener);
  }

  void attachTransport(BridgeTransport? transport) {
    _core.attachTransport(transport);
  }

  /// 绑定入站消息处理闭环，返回一个可传给 JavaScriptChannel.onMessageReceived 的回调。
  /// 调用前须先 attachTransport。
  /// 幂等：每次调用返回新的 handler，内部引用最新的 transport。
  Future<void> Function(String) bindTransport() {
    return (String messageJson) async {
      final List<String> responses =
          await processIncomingResponses(messageJson: messageJson);
      for (final String response in responses) {
        await _core.sendViaTransport(response);
      }
    };
  }

  void attachPageContextProvider(PageContextProvider provider) {
    _pageContextProvider = provider;
  }

  void resetForNewPage() {
    _ready = !requireHandshake;
    _currentSession = null;
    _sessionService.clearByPageInstance(_pageInstanceId);
    _pageInstanceId = _nextId();
  }

  void destroy() {
    _sessionService.clearAll();
    _core.destroy();
  }

  // Handler registration — delegate to CoreBridge
  void registerHandler(String method, NativeHandler handler) {
    _core.registerHandler(method, handler);
  }

  void registerHandlerWithContext(String method, NativeHandlerContext handler) {
    _core.registerHandlerWithContext(method, handler);
  }

  void registerStreamingHandler(String method, NativeStreamingHandler handler) {
    _core.registerStreamingHandler(method, handler);
  }

  void registerStreamingHandlerWithContext(
    String method,
    NativeStreamingHandlerContext handler,
  ) {
    _core.registerStreamingHandlerWithContext(method, handler);
  }

  // Message Processing

  Future<List<String>> processIncomingResponses({
    required String messageJson,
  }) async {
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
    return processIncomingResponsesForContext(
      messageJson: messageJson,
      context: context,
    );
  }

  Future<List<String>> processIncomingResponsesWithOrigin({
    required String messageJson,
    required String origin,
  }) async {
    return processIncomingResponsesForContext(
      messageJson: messageJson,
      context: TrustedPageContext(
        origin: origin,
        pageInstanceId: _pageInstanceId,
      ),
    );
  }

  Future<List<String>> processIncomingResponsesForContext({
    required String messageJson,
    required TrustedPageContext context,
  }) async {
    final BridgeMessage request;
    try {
      request = BridgeMessage.fromJsonString(messageJson);
    } catch (_) {
      return <String>[];
    }

    final SessionRecord? session = _sessionService.find(request.sessionId);
    final BridgeError? deny = _policyEngine.evaluate(PolicyInput(
      message: request,
      context: context,
      ready: _ready,
      sessionRecord: session,
    ));
    if (deny != null) {
      return <String>[_core.failResponse(request, deny).toJsonString()];
    }

    if (request.method == BridgeApiContract.methodCancelScope) {
      final String? scopeId = request.scopeId;
      return <String>[
        _core
            .successResponse(
              request,
              <String, dynamic>{
                'scopeId': scopeId ?? '',
                'acknowledged': true,
              },
              done: true,
            )
            .toJsonString(),
      ];
    }

    if (request.method == BridgeApiContract.methodHandshake) {
      final SessionRecord record = _sessionService.issue(
        context: context,
        capabilities: defaultCapabilities,
        ttlMs: sessionTtlMs,
      );
      _ready = true;
      _currentSession = record;
      final List<String> handshakeResponses = <String>[
        _core
            .successResponse(
              request,
              <String, dynamic>{
                'sessionId': record.sessionId,
                'capabilities': record.capabilities.toList()..sort(),
                'sessionTtlMs': sessionTtlMs,
                'policyVersion': policyVersion,
                'origin': context.origin,
                'accepted': true,
              },
              done: true,
            )
            .toJsonString(),
      ];
      for (final void Function() listener in _readyListeners) {
        listener();
      }
      return handshakeResponses;
    }

    return _core.dispatch(request, context);
  }

  Future<bool> postEvent({
    required String method,
    required dynamic payload,
    String? sessionId,
  }) async {
    if (!_ready) return false;
    return _core.postEvent(
      method: method,
      payload: payload,
      sessionId: sessionId ?? _currentSession?.sessionId,
    );
  }

  String _nextId() {
    return '${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(1 << 32)}';
  }
}

String _nextIdStatic() {
  return DateTime.now().microsecondsSinceEpoch.toString();
}
