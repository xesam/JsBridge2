import 'dart:convert';

import 'package:js_bridge_core/js_bridge_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Flutter core conformance baseline', () {
    test('C01_requestBeforeHandshake_deniedByGate', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.resetForNewPage();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', ''),
      );

      expect(errorCode(responses.single), 'E_POLICY_DENY');
    });

    test('C02_handshake_returnsSessionPayload', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.resetForNewPage();

      final Map<String, dynamic> response = parse(
        (await fixture.deliver(requestJson('h1', 'bridge.handshake', ''))).single,
      );
      final Map<String, dynamic> payload =
          response['payload'] as Map<String, dynamic>;

      expect(response['ok'], isTrue);
      expect((payload['sessionId'] as String).isNotEmpty, isTrue);
      expect(payload.containsKey('capabilities'), isTrue);
      expect(payload.containsKey('sessionTtlMs'), isTrue);
      expect(payload.containsKey('policyVersion'), isTrue);
      expect(payload['origin'], 'file://');
      expect(payload['accepted'], isTrue);
    });

    test('C03_methodNotAllowed_denied', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.resetForNewPage();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'notAllowed', sessionId),
      );

      expect(errorCode(responses.single), 'E_METHOD_NOT_ALLOWED');
    });

    test('C04_originNotAllowed_denied', () async {
      final Fixture fixture = Fixture(
        allowedOrigins: <String>{'https://trusted.example'},
      );
      fixture.bridge.resetForNewPage();

      final List<String> responses = await fixture.deliver(
        requestJson('h1', 'bridge.handshake', ''),
      );

      expect(errorCode(responses.single), 'E_ORIGIN_DENY');
    });

    test('C04b_originPrefixButNotExact_denied', () async {
      final Fixture fixture = Fixture(
        allowedOrigins: <String>{'https://trusted.example'},
      );
      fixture.bridge.resetForNewPage();

      final List<String> responses = await fixture.deliver(
        requestJson('h1', 'bridge.handshake', ''),
        origin: 'https://trusted.example.evil',
      );

      expect(errorCode(responses.single), 'E_ORIGIN_DENY');
    });

    test('C05_validHandshakeThenValidRequest_success', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerHandler('echo', (dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetForNewPage();
      final String sessionId = await fixture.handshake();

      final Map<String, dynamic> response = parse(
        (await fixture.deliver(
          requestJson('r1', 'echo', sessionId, payload: <String, dynamic>{'k': 'v'}),
        )).single,
      );

      expect(response['ok'], isTrue);
      expect(response['method'], 'echo');
    });

    test('C06_missingSessionAfterReady_denied', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerHandler('echo', (dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetForNewPage();
      await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', ''),
      );

      expect(errorCode(responses.single), 'E_SESSION_INVALID');
    });

    test('C07_sessionOriginMismatch_denied', () async {
      final Fixture fixture = Fixture(
        allowedOrigins: <String>{'file://', 'https://trusted.example'},
      );
      fixture.bridge.registerHandler('echo', (dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetForNewPage();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', sessionId),
        origin: 'https://trusted.example',
      );

      expect(errorCode(responses.single), 'E_SESSION_INVALID');
    });

    test('C08_sessionPageMismatch_denied', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerHandler('echo', (dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetForNewPage();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliverForContext(
        requestJson('r1', 'echo', sessionId),
        const TrustedPageContext(
          origin: 'file://',
          pageInstanceId: 'forced-page-mismatch',
        ),
      );

      expect(errorCode(responses.single), 'E_SESSION_INVALID');
    });

    test('C09_capabilityDenied_denied', () async {
      final Fixture fixture = Fixture(
        methodWhitelist: <String>{'bridge.handshake', 'admin'},
        defaultCapabilities: <String>{'echo'},
      );
      fixture.bridge.resetForNewPage();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'admin', sessionId),
      );

      expect(errorCode(responses.single), 'E_CAPABILITY_DENY');
    });

    test('C10_methodNotFound_denied', () async {
      final Fixture fixture = Fixture(
        methodWhitelist: <String>{'bridge.handshake', 'missing'},
        defaultCapabilities: <String>{'missing'},
      );
      fixture.bridge.resetForNewPage();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'missing', sessionId),
      );

      expect(errorCode(responses.single), 'E_METHOD_NOT_FOUND');
    });

    test('C11_handlerThrows_normalizedToInternal', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerHandler('echo', (dynamic payload) {
        throw StateError('boom');
      });
      fixture.bridge.resetForNewPage();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', sessionId),
      );

      expect(errorCode(responses.single), 'E_INTERNAL');
    });

    test('C12_extraPolicyDeny_takesEffect', () async {
      final Fixture fixture = Fixture(
        extraPolicies: <ExtraPolicy>[
          (BridgeMessage request, TrustedPageContext context) {
            if (request.method == 'echo') {
              return const BridgeError(
                code: 'E_TEST_DENY',
                message: 'blocked',
              );
            }
            return null;
          },
        ],
      );
      fixture.bridge.registerHandler('echo', (dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetForNewPage();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', sessionId),
      );

      expect(errorCode(responses.single), 'E_TEST_DENY');
    });

    test('C13_streamingResponse_emitsDoneFalseThenDoneTrue', () async {
      final Fixture fixture = Fixture(
        methodWhitelist: <String>{'bridge.handshake', 'stream'},
        defaultCapabilities: <String>{'stream'},
      );
      fixture.bridge.registerStreamingHandler('stream', (dynamic payload) async {
        return const <BridgeHandlerResult>[
          BridgeHandlerResult.success(<String, dynamic>{'tick': 1}, done: false),
          BridgeHandlerResult.success(<String, dynamic>{'tick': 2}),
        ];
      });
      fixture.bridge.resetForNewPage();
      final String sessionId = await fixture.handshake();

      final List<Map<String, dynamic>> responses = (await fixture.deliver(
        requestJson('r1', 'stream', sessionId),
      )).map(parse).toList();

      expect(responses, hasLength(2));
      expect(responses.first['done'], isFalse);
      expect(responses.last['done'], isTrue);
    });

    test('C17_sendFailure_observableAndPostEventReturnsFalse', () async {
      final Fixture fixture = Fixture();
      fixture.transport.sendEnabled = false;
      fixture.bridge.resetForNewPage();
      await fixture.handshake();

      final bool sent = await fixture.bridge.postEvent(
        method: 'runtime.state',
        payload: <String, dynamic>{'state': 'ready'},
      );

      expect(fixture.bridge.isReady, isTrue);
      expect(sent, isFalse);
      expect(fixture.bridge.sendFailureCount, 1);
    });

    test('C18_resetForNewPageRotatesContext_oldSessionInvalid', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerHandler('echo', (dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetForNewPage();
      final String oldSessionId = await fixture.handshake();

      fixture.bridge.resetForNewPage();
      await fixture.handshake();
      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', oldSessionId),
      );

      expect(errorCode(responses.single), 'E_SESSION_INVALID');
    });

    test('L0_defaultConfig_requestBeforeHandshake_succeeds', () async {
      final JsBridge bridge = JsBridge(
        securityConfig: SecurityConfig(
          allowedOrigins: <String>{'file://'},
          methodWhitelist: <String>{'bridge.handshake', 'echo'},
          defaultCapabilities: <String>{'echo'},
        ),
      );
      bridge.registerHandler('echo', (dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      bridge.resetForNewPage();

      // Level 0: no handshake gate, so echo should proceed even before handshake
      // But no session check either, so it goes to handler directly
      final List<String> responses = await bridge.processIncomingResponsesWithOrigin(
        messageJson: requestJson('r1', 'echo', ''),
        origin: 'file://',
      );

      final Map<String, dynamic> response = parse(responses.single);
      expect(response['ok'], isTrue);
    });

    test('L0_defaultConfig_nonRequestKind_stillDenied', () async {
      final JsBridge bridge = JsBridge(
        securityConfig: SecurityConfig(
          allowedOrigins: <String>{'file://'},
          methodWhitelist: <String>{'bridge.handshake', 'echo'},
          defaultCapabilities: <String>{'echo'},
        ),
      );
      bridge.resetForNewPage();

      final String eventJson = jsonEncode(<String, dynamic>{
        'id': 'e1',
        'sessionId': '',
        'kind': 'event',
        'method': 'echo',
        'ts': 1,
        'timeoutMs': 1000,
        'keep': false,
        'payload': <String, dynamic>{},
      });
      final List<String> responses = await bridge.processIncomingResponsesWithOrigin(
        messageJson: eventJson,
        origin: 'file://',
      );

      expect(errorCode(responses.single), 'E_INVALID_MESSAGE');
    });

    test('L0_defaultConfig_isReady_trueAfterBindPage', () async {
      final JsBridge bridge = JsBridge(
        securityConfig: SecurityConfig(
          allowedOrigins: <String>{'file://'},
          methodWhitelist: <String>{'bridge.handshake', 'echo'},
          defaultCapabilities: <String>{'echo'},
        ),
      );
      bridge.resetForNewPage();

      expect(bridge.isReady, isTrue);
    });

    test('AccessControl_wildcardOrigins_rejectedAtConstruction', () {
      // secure() 默认 allowedOrigins 仍为通配，构造时应拒绝——升级别不应静默放行所有来源。
      expect(
        () => JsBridge(
          securityConfig: SecurityConfig.secure(),
          transport: (String _) async => true,
        ),
        throwsArgumentError,
      );
    });

    test('PageContextProvider_handshakeUsesKernelDerivedOrigin', () async {
      final FixedOriginProvider provider = FixedOriginProvider('file://');
      final JsBridge bridge = JsBridge(
        securityConfig: SecurityConfig.secure()..allowedOrigins = <String>{'file://'}
          ..methodWhitelist = <String>{'bridge.handshake', 'echo'}
          ..defaultCapabilities = <String>{'echo'},
        pageContextProvider: provider,
      );
      bridge.resetForNewPage();

      final List<String> responses = await bridge.processIncomingResponses(
        messageJson: requestJson('h1', 'bridge.handshake', ''),
      );
      final Map<String, dynamic> payload =
          parse(responses.single)['payload'] as Map<String, dynamic>;

      expect(payload['origin'], 'file://');
    });

    test('PageContextProvider_originNotAllowed_denied', () async {
      final FixedOriginProvider provider = FixedOriginProvider('https://evil.example');
      final JsBridge bridge = JsBridge(
        securityConfig: SecurityConfig.secure()..allowedOrigins = <String>{'file://'}
          ..methodWhitelist = <String>{'bridge.handshake', 'echo'}
          ..defaultCapabilities = <String>{'echo'},
        pageContextProvider: provider,
      );
      bridge.resetForNewPage();

      final List<String> responses = await bridge.processIncomingResponses(
        messageJson: requestJson('h1', 'bridge.handshake', ''),
      );

      expect(errorCode(responses.single), 'E_ORIGIN_DENY');
    });

    test('PageContextProvider_mismatchedOriginOnRequest_sessionInvalid', () async {
      final MutableOriginProvider provider = MutableOriginProvider('file://');
      final JsBridge bridge = JsBridge(
        securityConfig: SecurityConfig.secure()
          ..allowedOrigins = <String>{'file://', 'https://example.com'}
          ..methodWhitelist = <String>{'bridge.handshake', 'echo'}
          ..defaultCapabilities = <String>{'echo'},
        pageContextProvider: provider,
      );
      bridge.registerHandler('echo', (dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      bridge.resetForNewPage();

      final String sessionId = (parse(
        (await bridge.processIncomingResponses(
          messageJson: requestJson('h1', 'bridge.handshake', ''),
        )).single,
      )['payload'] as Map<String, dynamic>)['sessionId'] as String;

      provider.origin = 'https://example.com';
      final List<String> responses = await bridge.processIncomingResponses(
        messageJson: requestJson('r1', 'echo', sessionId),
      );

      expect(errorCode(responses.single), 'E_SESSION_INVALID');
    });

    test('C28_lifecycleEventsBeforeReady_queuedAndFlushedInOrder', () async {
      final Fixture fixture = Fixture();
      final LifecycleExtension lifecycle = LifecycleExtension(fixture.bridge);
      fixture.bridge.resetForNewPage();

      await lifecycle.onHostEvent('created');
      await lifecycle.onHostEvent('started');
      await lifecycle.onHostEvent('resumed');
      expect(lifecycleEvents(fixture), isEmpty);

      await fixture.handshake();
      await Future<void>.delayed(Duration.zero);

      final List<Map<String, dynamic>> events = lifecycleEvents(fixture);
      expect(events.map((Map<String, dynamic> e) => e['state']).toList(),
          <String>['created', 'started', 'resumed']);
      expect(events.map((Map<String, dynamic> e) => e['seq']).toList(),
          <int>[1, 2, 3]);
    });

    test('C29_lifecycleQueueOverflow_dropsOldestKeepsSeq', () async {
      final Fixture fixture = Fixture();
      final LifecycleExtension lifecycle =
          LifecycleExtension(fixture.bridge, maxPendingEvents: 2);
      fixture.bridge.resetForNewPage();

      await lifecycle.onHostEvent('created');
      await lifecycle.onHostEvent('started');
      await lifecycle.onHostEvent('resumed');

      await fixture.handshake();
      await Future<void>.delayed(Duration.zero);

      final List<Map<String, dynamic>> events = lifecycleEvents(fixture);
      expect(events.map((Map<String, dynamic> e) => e['state']).toList(),
          <String>['started', 'resumed']);
      expect(events.map((Map<String, dynamic> e) => e['seq']).toList(),
          <int>[2, 3]);
    });

    test('C30_lifecycleAfterReady_sentImmediatelyWithExactPayload', () async {
      final Fixture fixture = Fixture();
      final LifecycleExtension lifecycle = LifecycleExtension(fixture.bridge);
      fixture.bridge.resetForNewPage();
      await fixture.handshake();

      await lifecycle.onHostEvent('resumed');

      final List<Map<String, dynamic>> events = lifecycleEvents(fixture);
      expect(events, hasLength(1));
      expect(events.single['state'], 'resumed');
      expect(events.single['seq'], 1);
      expect(events.single.keys.toSet(), <String>{'state', 'seq'});
    });
  });
}

class FixedOriginProvider implements PageContextProvider {
  FixedOriginProvider(this.origin);
  String origin;

  @override
  TrustedPageContext createContext(BridgeMessage message, String pageInstanceId) =>
      TrustedPageContext(origin: origin, pageInstanceId: pageInstanceId);
}

class MutableOriginProvider implements PageContextProvider {
  MutableOriginProvider(this.origin);
  String origin;

  @override
  TrustedPageContext createContext(BridgeMessage message, String pageInstanceId) =>
      TrustedPageContext(origin: origin, pageInstanceId: pageInstanceId);
}

class Fixture {
  Fixture({
    Set<String>? allowedOrigins,
    Set<String>? methodWhitelist,
    Set<String>? defaultCapabilities,
    List<ExtraPolicy>? extraPolicies,
  }) {
    bridge = JsBridge(
      securityConfig: SecurityConfig.secure()
        ..allowedOrigins = allowedOrigins ?? <String>{'file://'}
        ..methodWhitelist =
            methodWhitelist ?? <String>{'bridge.handshake', 'echo'}
        ..defaultCapabilities = defaultCapabilities ?? <String>{'echo'}
        ..extraPolicies = extraPolicies ?? const <ExtraPolicy>[],
      transport: transport.send,
    );
  }

  late final JsBridge bridge;
  final FakeBridgeTransport transport = FakeBridgeTransport();

  Future<String> handshake() async {
    final Map<String, dynamic> response = parse(
      (await deliver(requestJson('h1', 'bridge.handshake', ''))).single,
    );
    final Map<String, dynamic> payload = response['payload'] as Map<String, dynamic>;
    return payload['sessionId'] as String;
  }

  Future<List<String>> deliver(String messageJson, {String origin = 'file://'}) {
    return bridge.processIncomingResponsesWithOrigin(
      messageJson: messageJson,
      origin: origin,
    );
  }

  Future<List<String>> deliverForContext(
    String messageJson,
    TrustedPageContext context,
  ) {
    return bridge.processIncomingResponsesForContext(
      messageJson: messageJson,
      context: context,
    );
  }
}

class FakeBridgeTransport {
  bool sendEnabled = true;
  final List<String> sentMessages = <String>[];

  bool send(String messageJson) {
    if (!sendEnabled) {
      return false;
    }
    sentMessages.add(messageJson);
    return true;
  }
}

String requestJson(
  String id,
  String method,
  String sessionId, {
  Map<String, dynamic> payload = const <String, dynamic>{},
}) {
  return jsonEncode(<String, dynamic>{
    'id': id,
    'sessionId': sessionId,
    'kind': 'request',
    'method': method,
    'ts': 1,
    'timeoutMs': 1000,
    'keep': false,
    'payload': payload,
  });
}

Map<String, dynamic> parse(String raw) {
  return jsonDecode(raw) as Map<String, dynamic>;
}

String errorCode(String raw) {
  final Map<String, dynamic> json = parse(raw);
  final Map<String, dynamic> error = json['error'] as Map<String, dynamic>;
  return error['code'] as String;
}

List<Map<String, dynamic>> lifecycleEvents(Fixture fixture) {
  return fixture.transport.sentMessages
      .map(parse)
      .where((Map<String, dynamic> m) =>
          m['kind'] == 'event' &&
          m['method'] == BridgeApiContract.methodLifecycle)
      .map((Map<String, dynamic> m) => m['payload'] as Map<String, dynamic>)
      .toList();
}
