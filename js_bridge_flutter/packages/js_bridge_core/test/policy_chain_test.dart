import 'package:js_bridge_core/js_bridge_core.dart';
import 'package:js_bridge_core/src/security/policy_engine.dart';
import 'package:js_bridge_core/src/security/session_record.dart';
import 'package:test/test.dart';

/// C45/C46：策略链求值顺序与安全级别切换
///
/// 对应 Android `PolicyGroupsTest` 的 c45_/c46_ 用例与 iOS `PolicyChainTests`。
void main() {
  group('Policy chain conformance', () {
    // ===== C45: 策略链固定求值顺序与短路行为 =====

    test('C45_policyChain_evaluatesInFixedOrder_requestShapeFirst', () {
      // 第一层 RequestShapePolicy 拒绝 -> 短路，后续策略不执行
      final PolicyEngine engine = PolicyEngine(<PolicyRule>[
        const RequestShapePolicy(),
      ]);

      final BridgeError? err = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.event, 'timerLog', ''),
          context: const TrustedPageContext(origin: 'file://', pageInstanceId: 'page-a'),
          ready: false,
          sessionRecord: null,
        ),
      );

      expect(err, isNotNull);
      expect(err!.code, 'E_INVALID_MESSAGE');
    });

    test('C45_policyChain_shortCircuitsOnFirstDenial', () {
      // 链：RequestShape -> HandshakeGate -> Origin
      // 预期：HandshakeGate 拒绝后短路，Origin 不执行
      final PolicyEngine engine = PolicyEngine(<PolicyRule>[
        const RequestShapePolicy(),
        const HandshakeGatePolicy(),
        const OriginPolicy(allowedOrigins: <String>{'https://trusted.example'}),
      ]);

      final BridgeError? err = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.request, 'getUser', 's1'),
          context: const TrustedPageContext(origin: 'file://', pageInstanceId: 'page-a'),
          ready: false,
          sessionRecord: null,
        ),
      );

      expect(err, isNotNull);
      // 短路在 HandshakeGate，错误码是 E_NOT_READY 而非 E_ORIGIN_DENY
      expect(err!.code, 'E_NOT_READY');
    });

    test('C45_policyChain_continuesWhenAllAllow', () {
      final PolicyEngine engine = PolicyEngine(<PolicyRule>[
        const RequestShapePolicy(),
      ]);

      final BridgeError? err = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.request, 'bridge.handshake', ''),
          context: const TrustedPageContext(origin: 'file://', pageInstanceId: 'page-a'),
          ready: false,
          sessionRecord: null,
        ),
      );

      expect(err, isNull);
    });

    test('C45_policyChain_stopsAtFirstDenialInVariableLengthChain', () {
      // 链长度为 3，第 2 个策略拒绝 -> 第 3 不执行
      // 用 Origin + MethodGate 验证：origin 拒绝时不应触发 method 判定
      final PolicyEngine engine = PolicyEngine(<PolicyRule>[
        const RequestShapePolicy(),
        const OriginPolicy(allowedOrigins: <String>{'https://trusted.example'}),
        const MethodGatePolicy(methodWhitelist: <String>{'bridge.handshake'}),
      ]);

      final BridgeError? err = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.request, 'notAllowed', 's1'),
          context: const TrustedPageContext(origin: 'file://', pageInstanceId: 'page-a'),
          ready: true,
          sessionRecord: null,
        ),
      );

      expect(err, isNotNull);
      expect(err!.code, 'E_ORIGIN_DENY');
    });

    // ===== C46: 安全级别切换 - 不同配置下的策略链组成 =====

    test('C46_nullConfig_onlyRequestShapePolicy', () {
      // 无配置：仅 RequestShapePolicy。非 request 拒绝，合法 request 通过。
      final PolicyEngine engine = PolicyEngine(<PolicyRule>[
        const RequestShapePolicy(),
      ]);
      const TrustedPageContext ctx =
          TrustedPageContext(origin: 'file://', pageInstanceId: 'page-a');

      final BridgeError? invalid = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.event, 'timerLog', ''),
          context: ctx,
          ready: false,
          sessionRecord: null,
        ),
      );
      expect(invalid, isNotNull);
      expect(invalid!.code, 'E_INVALID_MESSAGE');

      final BridgeError? valid = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.request, 'getUser', ''),
          context: ctx,
          ready: false,
          sessionRecord: null,
        ),
      );
      expect(valid, isNull);
    });

    test('C46_wildcardConfig_requiresHandshakeButNoOriginMethodCheck', () {
      // 有配置（维度 {"*"}）：RequestShape + HandshakeGate + Session
      final PolicyEngine engine = PolicyEngine(<PolicyRule>[
        const RequestShapePolicy(),
        const HandshakeGatePolicy(),
        const SessionPolicy(),
      ]);
      const TrustedPageContext ctx =
          TrustedPageContext(origin: 'file://', pageInstanceId: 'page-a');

      // 未 ready -> HandshakeGate 拒绝
      final BridgeError? beforeHandshake = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.request, 'anyMethod', 's1'),
          context: ctx,
          ready: false,
          sessionRecord: null,
        ),
      );
      expect(beforeHandshake, isNotNull);
      expect(beforeHandshake!.code, 'E_NOT_READY');

      // ready 但无 session -> SessionPolicy 拒绝
      final BridgeError? noSession = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.request, 'anyMethod', 's1'),
          context: ctx,
          ready: true,
          sessionRecord: null,
        ),
      );
      expect(noSession, isNotNull);
      expect(noSession!.code, 'E_SESSION_INVALID');
    });

    test('C46_fullConfig_fullPolicyChainWithOriginAndMethodCheck', () {
      // 完整配置：完整链
      final PolicyEngine engine = PolicyEngine(<PolicyRule>[
        const RequestShapePolicy(),
        const HandshakeGatePolicy(),
        const OriginPolicy(allowedOrigins: <String>{'https://trusted.example'}),
        const MethodGatePolicy(
          methodWhitelist: <String>{'bridge.handshake', 'getUser'},
        ),
        const SessionPolicy(),
      ]);

      final SessionRecord validSession = SessionRecord(
        sessionId: 's1',
        context: const TrustedPageContext(
          origin: 'https://trusted.example',
          pageInstanceId: 'page-a',
        ),
        expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
      );

      // origin 不在白名单 -> E_ORIGIN_DENY
      final BridgeError? badOrigin = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.request, 'getUser', 's1'),
          context: const TrustedPageContext(
            origin: 'https://untrusted.com',
            pageInstanceId: 'page-a',
          ),
          ready: true,
          sessionRecord: validSession,
        ),
      );
      expect(badOrigin, isNotNull);
      expect(badOrigin!.code, 'E_ORIGIN_DENY');

      // method 不在白名单 -> E_METHOD_NOT_ALLOWED
      final BridgeError? badMethod = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.request, 'deleteUser', 's1'),
          context: const TrustedPageContext(
            origin: 'https://trusted.example',
            pageInstanceId: 'page-a',
          ),
          ready: true,
          sessionRecord: validSession,
        ),
      );
      expect(badMethod, isNotNull);
      expect(badMethod!.code, 'E_METHOD_NOT_ALLOWED');

      // 全部满足 -> 通过
      final BridgeError? ok = engine.evaluate(
        PolicyInput(
          message: message(BridgeMessageKind.request, 'getUser', 's1'),
          context: const TrustedPageContext(
            origin: 'https://trusted.example',
            pageInstanceId: 'page-a',
          ),
          ready: true,
          sessionRecord: validSession,
        ),
      );
      expect(ok, isNull);
    });
  });
}

BridgeMessage message(BridgeMessageKind kind, String method, String sessionId) {
  return BridgeMessage(
    id: 'r1',
    sessionId: sessionId,
    kind: kind,
    method: method,
    ts: 1,
  );
}
