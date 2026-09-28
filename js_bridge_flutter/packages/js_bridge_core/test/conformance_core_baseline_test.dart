import 'dart:async';
import 'dart:convert';

import 'package:js_bridge_core/js_bridge_core.dart';
import 'package:js_bridge_core/src/security/session_record.dart';
import 'package:js_bridge_core/src/security/session_service.dart';
import 'package:test/test.dart';

void main() {
  group('Dart core conformance baseline', () {
    test('C01_requestBeforeHandshake_deniedByGate', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.resetPageInstance();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', ''),
      );

      expect(errorCode(responses.single), 'E_NOT_READY'); // v1: 握手门禁从 E_POLICY_DENY 分立
    });

    test('C02_handshake_returnsSessionPayload', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.resetPageInstance();

      final Map<String, dynamic> response = parse(
        (await fixture.deliver(requestJson('h1', 'bridge.handshake', ''))).single,
      );
      final Map<String, dynamic> payload =
          response['payload'] as Map<String, dynamic>;

      expect(response['ok'], isTrue);
      expect((payload['sessionId'] as String).isNotEmpty, isTrue);
      expect(payload.containsKey('sessionTtlMs'), isTrue);
      expect(payload.containsKey('policyVersion'), isTrue);
      expect(payload['origin'], 'file://');
      expect(payload['accepted'], isTrue);
    });

    test('C03_methodNotAllowed_denied', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.resetPageInstance();
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
      fixture.bridge.resetPageInstance();

      final List<String> responses = await fixture.deliver(
        requestJson('h1', 'bridge.handshake', ''),
      );

      expect(errorCode(responses.single), 'E_ORIGIN_DENY');
    });

    test('C04b_originPrefixButNotExact_denied', () async {
      final Fixture fixture = Fixture(
        allowedOrigins: <String>{'https://trusted.example'},
      );
      fixture.bridge.resetPageInstance();

      final List<String> responses = await fixture.deliver(
        requestJson('h1', 'bridge.handshake', ''),
        origin: 'https://trusted.example.evil',
      );

      expect(errorCode(responses.single), 'E_ORIGIN_DENY');
    });

    test('C05_validHandshakeThenValidRequest_success', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
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
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
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
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', sessionId),
        origin: 'https://trusted.example',
      );

      expect(errorCode(responses.single), 'E_SESSION_INVALID');
    });

    test('C08_sessionPageMismatch_denied', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
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

    test('C10_methodNotFound_denied', () async {
      final Fixture fixture = Fixture(
        methodWhitelist: <String>{'bridge.handshake', 'missing'},
      );
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'missing', sessionId),
      );

      expect(errorCode(responses.single), 'E_METHOD_NOT_FOUND');
    });

    test('C11_handlerThrows_normalizedToInternal', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) {
        throw StateError('boom');
      });
      fixture.bridge.resetPageInstance();
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
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', sessionId),
      );

      expect(errorCode(responses.single), 'E_TEST_DENY');
    });

    // C13 断言流式帧序契约（keep=true 请求、done=false → done=true），
    // 帧经 ResponseEmitter 旁路 sendViaTransport 推送，因此断言 transport 记录而非 dispatch 返回值。
    // C43 断言异步时序（帧间穿插 await），两者分工不得合并。
    test('C13_streamingResponse_emitsDoneFalseThenDoneTrue', () async {
      final Fixture fixture = Fixture(
        methodWhitelist: <String>{'bridge.handshake', 'stream'},
      );
      final Completer<void> emitted = Completer<void>();
      fixture.bridge.registerAsyncHandler('stream',
          (TrustedPageContext context, dynamic payload, ResponseEmitter? emitter) async {
        if (emitter == null) return;
        await emitter(
          const Result<dynamic, BridgeError>.success(<String, dynamic>{'tick': 1}),
          false,
        );
        await emitter(
          const Result<dynamic, BridgeError>.success(<String, dynamic>{'tick': 2}),
          true,
        );
        if (!emitted.isCompleted) {
          emitted.complete();
        }
      });
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      final List<String> immediate = await fixture.deliver(
        requestJson('r1', 'stream', sessionId, keep: true),
      );

      // async handler：dispatch 立即返回，帧由 transport 旁路推送
      expect(immediate, isEmpty);
      await emitted.future;
      await Future<void>.delayed(Duration.zero);

      final List<Map<String, dynamic>> responses = fixture.transport.sentMessages
          .map(parse)
          .where((Map<String, dynamic> m) => m['reqId'] == 'r1')
          .toList();

      expect(responses, hasLength(2));
      expect(responses.first['done'], isFalse);
      expect(responses.last['done'], isTrue);
      expect(responses.first['keep'], isTrue);
      expect(responses.last['keep'], isTrue);
      expect((responses.first['payload'] as Map<String, dynamic>)['tick'], 1);
      expect((responses.last['payload'] as Map<String, dynamic>)['tick'], 2);
    });

    test('C17_sendFailure_observableAndPostEventReturnsFalse', () async {
      final Fixture fixture = Fixture();
      fixture.transport.sendEnabled = false;
      fixture.bridge.resetPageInstance();
      await fixture.handshake();

      final bool sent = await fixture.bridge.postEvent(
        method: 'runtime.state',
        payload: <String, dynamic>{'state': 'ready'},
      );

      expect(fixture.bridge.isReady, isTrue);
      expect(sent, isFalse);
    });

    test('C18_resetPageInstanceRotatesContext_oldSessionInvalid', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
      final String oldSessionId = await fixture.handshake();

      fixture.bridge.resetPageInstance();
      await fixture.handshake();
      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', oldSessionId),
      );

      expect(errorCode(responses.single), 'E_SESSION_INVALID');
    });

    test('nullConfig_requestBeforeHandshake_succeeds', () async {
      final JsBridge bridge = JsBridge(
        securityConfig: null,
      );
      bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      bridge.resetPageInstance();

      // null 配置：no handshake gate, so echo should proceed even before handshake
      // But no session check either, so it goes to handler directly
      final List<String> responses = await bridge.processIncomingResponsesWithOrigin(
        messageJson: requestJson('r1', 'echo', ''),
        origin: 'file://',
      );

      final Map<String, dynamic> response = parse(responses.single);
      expect(response['ok'], isTrue);
    });

    test('nullConfig_nonRequestKind_stillDenied', () async {
      final JsBridge bridge = JsBridge(
        securityConfig: null,
      );
      bridge.resetPageInstance();

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

    test('nullConfig_isReady_trueAfterBindPage', () async {
      final JsBridge bridge = JsBridge(
        securityConfig: null,
      );
      bridge.resetPageInstance();

      expect(bridge.isReady, isTrue);
    });

    test('AccessControl_wildcardOrigins_rejectedAtConstruction', () {
      // SecurityConfig 对象存在但 allowedOrigins 未配置应在构造时拒绝
      expect(
        () => JsBridge(
          securityConfig: SecurityConfig(),
          transport: (String _) async => true,
        ),
        throwsArgumentError,
      );
    });

    test('AccessControl_missingMethodWhitelist_rejectedAtConstruction', () {
      // SecurityConfig 对象存在但 methodWhitelist 未配置应在构造时拒绝
      // （与 allowedOrigins 分支对称；错误消息须指明是 methodWhitelist 缺失）
      expect(
        () => JsBridge(
          securityConfig: SecurityConfig(
            allowedOrigins: <String>{'file://'},
          ),
          transport: (String _) async => true,
        ),
        throwsA(isA<ArgumentError>().having(
          (ArgumentError e) => e.message,
          'message',
          contains('methodWhitelist'),
        )),
      );
    });

    test('PageContextProvider_handshakeUsesKernelDerivedOrigin', () async {
      final FixedOriginProvider provider = FixedOriginProvider('file://');
      final JsBridge bridge = JsBridge(
        securityConfig: SecurityConfig(
          allowedOrigins: <String>{'file://'},
          methodWhitelist: <String>{'bridge.handshake', 'echo'},
        ),
        pageContextProvider: provider,
      );
      bridge.resetPageInstance();

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
        securityConfig: SecurityConfig(
          allowedOrigins: <String>{'file://'},
          methodWhitelist: <String>{'bridge.handshake', 'echo'},
        ),
        pageContextProvider: provider,
      );
      bridge.resetPageInstance();

      final List<String> responses = await bridge.processIncomingResponses(
        messageJson: requestJson('h1', 'bridge.handshake', ''),
      );

      expect(errorCode(responses.single), 'E_ORIGIN_DENY');
    });

    test('PageContextProvider_mismatchedOriginOnRequest_sessionInvalid', () async {
      final FixedOriginProvider provider = FixedOriginProvider('file://');
      final JsBridge bridge = JsBridge(
        securityConfig: SecurityConfig(
          allowedOrigins: <String>{'file://', 'https://example.com'},
          methodWhitelist: <String>{'bridge.handshake', 'echo'},
        ),
        pageContextProvider: provider,
      );
      bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      bridge.resetPageInstance();

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
      fixture.bridge.resetPageInstance();

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
      fixture.bridge.resetPageInstance();

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
      fixture.bridge.resetPageInstance();
      await fixture.handshake();

      await lifecycle.onHostEvent('resumed');

      final List<Map<String, dynamic>> events = lifecycleEvents(fixture);
      expect(events, hasLength(1));
      expect(events.single['state'], 'resumed');
      expect(events.single['seq'], 1);
      expect(events.single.keys.toSet(), <String>{'state', 'seq'});
    });

    test('C33_emptyMethod_deniedAsInvalidMessage', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.resetPageInstance();

      final List<String> responses = await fixture.deliver(requestJson('r1', '', ''));

      expect(errorCode(responses.single), 'E_INVALID_MESSAGE');
    });

    test('C34_missingKind_silentlyDropped', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.resetPageInstance();

      final List<String> responses = await fixture.deliver(
        '{"id":"r34","sessionId":"","method":"echo","payload":{}}',
      );

      expect(responses, isEmpty);
    });

    test('C35_handshakeNotInWhitelist_autoAllowed', () async {
      final Fixture fixture = Fixture(methodWhitelist: <String>{'echo'});
      fixture.bridge.resetPageInstance();

      final List<String> responses = await fixture.deliver(
        requestJson('h1', 'bridge.handshake', ''),
      );

      // 协议方法由框架装配期自动并入放行集，白名单未含 bridge.handshake 时握手仍成功
      final Map<String, dynamic> response = parse(responses.single);
      expect(response['ok'], isTrue);
      final Map<String, dynamic> payload =
          response['payload'] as Map<String, dynamic>;
      expect(payload['sessionId'] as String?, isNotEmpty);
    });

    test('C36_unknownSessionId_denied', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
      await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', 'bogus-session'),
      );

      expect(errorCode(responses.single), 'E_SESSION_INVALID');
    });

    test('C37_cancelScope_echoesPayloadScopeIdWithAccepted', () async {
      final Fixture fixture = Fixture(
        methodWhitelist: <String>{'bridge.handshake', 'bridge.cancelScope'},
      );
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('c1', 'bridge.cancelScope', sessionId,
            payload: <String, dynamic>{'scopeId': 's-1'}),
      );

      final Map<String, dynamic> response = parse(responses.single);
      final Map<String, dynamic> payload =
          response['payload'] as Map<String, dynamic>;
      expect(response['ok'], isTrue);
      expect(payload['scopeId'], 's-1');
      expect(payload['accepted'], isTrue);
    });

    test('C38_missingOptionalFields_defaultsApplied', () async {
      final FakeBridgeTransport transport = FakeBridgeTransport();
      final JsBridge bridge = JsBridge(
        securityConfig: null,
        transport: transport.send,
        pageContextProvider: FixedOriginProvider('file://'),
      );
      bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      bridge.resetPageInstance();

      final List<String> responses = await bridge.processIncomingResponsesWithOrigin(
        messageJson: '{"id":"r38","kind":"request","method":"echo"}',
        origin: 'file://',
      );

      expect(parse(responses.single)['ok'], isTrue);
    });

    test('C43_asyncHandler_multipleResponsesViaEmitter', () async {
      final Fixture fixture = Fixture(
        methodWhitelist: <String>{'bridge.handshake', 'echo', 'asyncTest'},
      );

      // 注册异步 handler
      fixture.bridge.registerAsyncHandler('asyncTest', (TrustedPageContext context, dynamic payload, ResponseEmitter? emitter) async {
        if (emitter == null) return;

        // 发送第一帧：done=false
        await emitter(const Result<dynamic, BridgeError>.success(<String, dynamic>{'frame': 1}), false);

        // 模拟异步工作
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // 发送第二帧：done=false
        await emitter(const Result<dynamic, BridgeError>.success(<String, dynamic>{'frame': 2}), false);

        // 发送最终帧：done=true
        await emitter(const Result<dynamic, BridgeError>.success(<String, dynamic>{'frame': 3}), true);
      });

      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      // 发起请求
      await fixture.deliver(requestJson('r43', 'asyncTest', sessionId));

      // 等待异步响应完成
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 验证 transport 收到的消息
      final List<Map<String, dynamic>> responses = fixture.transport.sentMessages
          .map((String json) => parse(json))
          .where((Map<String, dynamic> m) => m['reqId'] == 'r43')
          .toList();

      // 应该收到 3 帧响应
      expect(responses.length, equals(3), reason: 'Should receive 3 async responses');

      // 验证第一帧
      expect(responses[0]['done'], equals(false));
      expect(responses[0]['ok'], equals(true));
      expect((responses[0]['payload'] as Map<String, dynamic>)['frame'], equals(1));

      // 验证第二帧
      expect(responses[1]['done'], equals(false));
      expect(responses[1]['ok'], equals(true));
      expect((responses[1]['payload'] as Map<String, dynamic>)['frame'], equals(2));

      // 验证最终帧
      expect(responses[2]['done'], equals(true));
      expect(responses[2]['ok'], equals(true));
      expect((responses[2]['payload'] as Map<String, dynamic>)['frame'], equals(3));
    });

    test('C48_protocolMethods_autoMergedIntoWhitelist', () async {
      final Fixture fixture = Fixture(methodWhitelist: <String>{'echo'}); // 不含任何协议方法
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();
      expect(sessionId, isNotEmpty);

      // 协议方法 bridge.cancelScope 自动放行并回显 scopeId
      final List<String> cancelResponses = await fixture.deliver(
        requestJson('c1', 'bridge.cancelScope', sessionId,
            payload: <String, dynamic>{'scopeId': 's-1'}),
      );
      final Map<String, dynamic> cancelResponse = parse(cancelResponses.single);
      expect(cancelResponse['ok'], isTrue);
      expect((cancelResponse['payload'] as Map<String, dynamic>)['scopeId'], 's-1');

      // 白名单外业务方法仍被拒绝
      final List<String> forbiddenResponses = await fixture.deliver(
        requestJson('r1', 'forbidden', sessionId),
      );
      expect(errorCode(forbiddenResponses.single), 'E_METHOD_NOT_ALLOWED');

      // 白名单内业务方法正常成功
      final List<String> echoResponses = await fixture.deliver(
        requestJson('r2', 'echo', sessionId),
      );
      expect(parse(echoResponses.single)['ok'], isTrue);
    });

    // C49：同一 method 重复注册 → 后者覆盖前者（单一注册表，无隐式优先级）
    test('C49_duplicateRegistration_lastWins', () async {
      final FakeBridgeTransport transport = FakeBridgeTransport();
      final JsBridge bridge = JsBridge(
        securityConfig: null,
        transport: transport.send,
        pageContextProvider: FixedOriginProvider('file://'),
      );

      bool firstInvoked = false;
      bridge.registerSimpleHandler('dup',
          (TrustedPageContext context, dynamic payload) async {
        firstInvoked = true;
        return BridgeHandlerResult.success(<String, dynamic>{'src': 'h1'});
      });
      bridge.registerSimpleHandler('dup',
          (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(<String, dynamic>{'src': 'h2'});
      });
      bridge.resetPageInstance();

      final List<String> responses = await bridge.processIncomingResponsesWithOrigin(
        messageJson: requestJson('r49', 'dup', ''),
        origin: 'file://',
      );

      // 仅一帧响应，且来自后注册的 handler
      expect(responses, hasLength(1));
      final Map<String, dynamic> response = parse(responses.single);
      expect(response['ok'], isTrue);
      expect(response['method'], 'dup');
      expect(
        (response['payload'] as Map<String, dynamic>)['src'],
        'h2',
        reason: 'last registration wins',
      );
      expect(firstInvoked, isFalse, reason: 'first handler must never be invoked');
      expect(transport.sentMessages, isEmpty);
    });

    // C51：docs/03 §3.4 —— 必填字段类型非法（id/kind/method 传数字、sessionId 传数字）
    // → 静默丢弃无任何响应（禁止宽容转换），后续正常请求不受影响。
    test('C51_malformedRequiredFieldTypes_silentlyDroppedAndNextRequestUnaffected', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      final List<String> malformed = <String>[
        // id 非字符串
        jsonEncode(<String, dynamic>{
          'id': 123, 'sessionId': sessionId, 'kind': 'request', 'method': 'echo', 'ts': 1,
        }),
        // kind 非字符串
        jsonEncode(<String, dynamic>{
          'id': 'r51a', 'sessionId': sessionId, 'kind': 123, 'method': 'echo', 'ts': 1,
        }),
        // method 非字符串
        jsonEncode(<String, dynamic>{
          'id': 'r51b', 'sessionId': sessionId, 'kind': 'request', 'method': 123, 'ts': 1,
        }),
        // sessionId 非字符串
        jsonEncode(<String, dynamic>{
          'id': 'r51c', 'sessionId': 123, 'kind': 'request', 'method': 'echo', 'ts': 1,
        }),
      ];
      for (final String messageJson in malformed) {
        expect(await fixture.deliver(messageJson), isEmpty,
            reason: '必填字段类型非法必须静默丢弃，不产生任何响应');
      }

      // 后续正常请求不受影响
      final List<String> responses = await fixture.deliver(
        requestJson('r51', 'echo', sessionId),
      );
      expect(responses, hasLength(1));
      expect(parse(responses.single)['ok'], isTrue);
    });

    // C52：Simple handler 返回无数据成功（success(null)）→ 恰好 1 帧
    // ok=true、payload=null、done=true —— 不得静默吞帧。
    test('C52_simpleHandlerSuccessNull_emitsExactlyOneDoneFrame', () async {
      final FakeBridgeTransport transport = FakeBridgeTransport();
      final JsBridge bridge = JsBridge(
        securityConfig: null,
        transport: transport.send,
        pageContextProvider: FixedOriginProvider('file://'),
      );
      bridge.registerSimpleHandler('noData', (TrustedPageContext context, dynamic payload) async {
        return const BridgeHandlerResult.success(null);
      });
      bridge.resetPageInstance();

      final List<String> responses = await bridge.processIncomingResponsesWithOrigin(
        messageJson: requestJson('r52', 'noData', ''),
        origin: 'file://',
      );

      expect(responses, hasLength(1), reason: 'null payload 终止帧不得被静默吞掉');
      final Map<String, dynamic> response = parse(responses.single);
      expect(response['ok'], isTrue);
      expect(response['payload'], isNull);
      expect(response['done'], isTrue);
      expect(response['reqId'], 'r52');
    });

    // C53：docs/03 §9 细则 3 fail-closed —— 策略 deny 但不携带 error 时以 E_POLICY_DENY 兜底，
    // 禁止静默放行到 dispatch。Flutter 端 ExtraPolicy 形态为"deny 即返回 error"，
    // 以空错误码 BridgeError 构造"拒绝但缺 error"形态。
    test('C53_policyDenyWithoutError_fallsBackToPolicyDenyAndNeverDispatches', () async {
      bool handlerInvoked = false;
      final Fixture fixture = Fixture(
        extraPolicies: <ExtraPolicy>[
          (BridgeMessage request, TrustedPageContext context) {
            if (request.method == 'echo') {
              return const BridgeError(code: '', message: ''); // deny 且缺 error
            }
            return null;
          },
        ],
      );
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        handlerInvoked = true;
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      final List<String> responses = await fixture.deliver(
        requestJson('r53', 'echo', sessionId),
      );

      final Map<String, dynamic> response = parse(responses.single);
      expect(response['ok'], isFalse);
      expect((response['error'] as Map<String, dynamic>)['code'], 'E_POLICY_DENY');
      expect(handlerInvoked, isFalse, reason: 'deny 不得静默放行到 dispatch');
    });

    // C54：docs/03 §9 细则 5 origin 序列化归一化 —— scheme/host 小写；
    // 默认端口（443/80）省略；非默认端口保留；无 URL → ""（fail-closed）。
    test('C54_originNormalization_defaultPortOmittedNonDefaultKeptMissingEmpty', () {
      expect(OriginNormalizer.normalize('https://host:443'), 'https://host');
      expect(OriginNormalizer.normalize('http://host:80'), 'http://host');
      expect(OriginNormalizer.normalize('https://host:8443'), 'https://host:8443');
      expect(OriginNormalizer.normalize('http://host:8080'), 'http://host:8080');
      // scheme 与 host 小写
      expect(OriginNormalizer.normalize('HTTPS://Host:443'), 'https://host');
      // 无 URL → 空串（永远不会命中任何白名单）
      expect(OriginNormalizer.normalize(null), '');
      expect(OriginNormalizer.normalize(''), '');
      // 无法解析 / 无 scheme → 空串（fail-closed）
      expect(OriginNormalizer.normalize('::::'), '');
      expect(OriginNormalizer.normalize('host/path'), '');
      // 本地内容协议保留 scheme 语义（宿主决定是否放行）
      expect(OriginNormalizer.normalize('file:///sdcard/index.html'), 'file://');
      expect(
        OriginNormalizer.normalize('flutter-asset:///assets/web/index.html'),
        'flutter-asset://',
      );
      // 非层级形态（scheme 后无 //）→ 空串 fail-closed（四端一致，C54 向量套件覆盖）
      expect(OriginNormalizer.normalize('about:blank'), '');
    });

    // C54：四端共享的 origin 归一化全量向量，正本为 docs/origin-normalizer-vectors.json，
    // 由 scripts/check_origin_vectors.sh 强制四端 C54 测试内嵌同一向量集——修改必须四端同改
    test('C54_originNormalizer_vectorSuite', () {
      void v(String input, String expected) {
        expect(OriginNormalizer.normalize(input), expected, reason: 'normalize($input)');
      }
      // ORIGIN_VECTORS:BEGIN
      v('', '');
      v('   ', '');
      v('host/path', '');
      v('::::', '');
      v('123://host', '');
      v('a b://host', '');
      v('ab+cd-.://host', 'ab+cd-.://host');
      v('about:blank', '');
      v('data:text/html,x', '');
      v('mailto:a@b', '');
      v('javascript:alert(1)', '');
      v('file:///sdcard/index.html', 'file://');
      v('file://media/path', 'file://');
      v('FILE:///x.html', 'file://');
      v('content:///settings', 'content://');
      v('flutter-asset:///assets/web/index.html', 'flutter-asset://');
      v('asset://', 'asset://');
      v('https://', 'https://');
      v('https://example.com', 'https://example.com');
      v('HTTPS://EXAMPLE.com/Path?x=1#f', 'https://example.com');
      v('https://host:443', 'https://host');
      v('http://host:80', 'http://host');
      v('https://host:0443', 'https://host');
      v('http://host:080', 'http://host');
      v('https://host:8443', 'https://host:8443');
      v('http://host:8080/a/b?c#d', 'http://host:8080');
      v('http://u:p@host:8080', 'http://host:8080');
      v('http://host:65535', 'http://host:65535');
      v('http://host:99999', '');
      v('custom://host:8080', 'custom://host:8080');
      v('custom://host', 'custom://host');
      v('ftp://host:21', 'ftp://host:21');
      v('https://:8080', '');
      v('http://host:abc', '');
      v('http://host:0', '');
      v('http://host:00', '');
      v('http://host:-80', '');
      v('http://host:', '');
      v('http://::', '');
      v('http://[::1]', 'http://[::1]');
      v('http://[::1]:8443', 'http://[::1]:8443');
      v('http://[2001:DB8::1]:443', 'http://[2001:db8::1]:443');
      v('http://[::1]:0', '');
      // ORIGIN_VECTORS:END
    });

    // C55：docs/03 §3.3 —— v1 事件投放唯一形态为广播：事件帧 sessionId 恒为空串 ""，
    // 禁止默认归属最近一次握手的 session（多 WebView 场景会错投向最近握手的页面）。
    // postEvent 为两参 API（method, payload），无定向投送入口——四端一致。
    test('C55_postEventWithoutSessionId_broadcastsEmptySessionId', () async {
      final FakeBridgeTransport transport = FakeBridgeTransport();
      final JsBridge bridge = JsBridge(
        securityConfig: null,
        transport: transport.send,
        pageContextProvider: FixedOriginProvider('file://'),
      );
      bridge.resetPageInstance();
      // 无配置（null）：握手仍签发 session，作为"最近一次握手的 session"存在
      final String sessionId = (parse(
        (await bridge.processIncomingResponses(
          messageJson: requestJson('h1', 'bridge.handshake', ''),
        )).single,
      )['payload'] as Map<String, dynamic>)['sessionId'] as String;
      expect(sessionId, isNotEmpty);

      final bool sent = await bridge.postEvent(
        method: 'runtime.state',
        payload: <String, dynamic>{'state': 'ready'},
      );

      expect(sent, isTrue);
      final Map<String, dynamic> event = parse(transport.sentMessages.last);
      expect(event['kind'], 'event');
      expect(event['sessionId'], '', reason: '默认必须是空串广播，而非最近握手 session');
    });

    // C56：docs/03 §10 —— 签发（issue）时顺带清扫存储中已过期的 session 记录，
    // 防止长期运行进程中不再被查询的过期条目无界累积。
    test('C56_issueSweepsExpiredRecords_staleSessionsRemovedOnNextIssue', () {
      int nowMs = 100000;
      final SessionService service = SessionService(clock: () => nowMs);
      const TrustedPageContext context =
          TrustedPageContext(origin: 'file://', pageInstanceId: 'p56');

      // 签发 session A（TTL 短）
      final SessionRecord sessionA = service.issue(context: context, ttlMs: 100);
      expect(service.sessionCount, 1);

      // 越过 A 的 TTL 后再次签发 B：签发时顺带清扫全表过期条目
      nowMs += 200;
      final SessionRecord sessionB = service.issue(context: context, ttlMs: 60000);
      expect(service.sessionCount, 1, reason: '过期的 A 应在签发 B 时被清扫移除');
      expect(service.find(sessionA.sessionId), isNull, reason: 'E_SESSION_INVALID 语义');
      expect(service.find(sessionB.sessionId), isNotNull);
    });

    // C60：docs/03 §10 三态——ttlMs=0 表示永不过期（-1 哨兵）。
    test('C60_sessionTtlZero_neverExpires', () {
      int nowMs = 200000;
      final SessionService service = SessionService(clock: () => nowMs);

      final SessionRecord sessionA = service.issue(
        context:
            const TrustedPageContext(origin: 'file://', pageInstanceId: 'p60a'),
        ttlMs: 0,
      );
      nowMs += 86400000; // 推进一天
      expect(service.find(sessionA.sessionId), isNotNull, reason: 'ttl=0 的 session 永不失效');

      // 不同 pageInstanceId 签发 B，A 不受刷新语义影响（C61 只刷新同页）
      final SessionRecord sessionB = service.issue(
        context:
            const TrustedPageContext(origin: 'file://', pageInstanceId: 'p60b'),
        ttlMs: 0,
      );
      expect(service.sessionCount, 2, reason: '签发清扫不得移除永不过期记录');
      expect(service.find(sessionA.sessionId), isNotNull);
      expect(service.find(sessionB.sessionId), isNotNull);
    });

    // C61：docs/03 §7.1 幂等性——同 pageInstanceId 重复握手应"刷新"而非并存。
    test('C61_repeatedHandshakeRefreshes_priorSessionInvalidated', () {
      final SessionService service = SessionService(clock: () => 300000);
      const TrustedPageContext context =
          TrustedPageContext(origin: 'file://', pageInstanceId: 'p61');

      final SessionRecord sessionA = service.issue(context: context, ttlMs: 60000);
      expect(service.find(sessionA.sessionId), isNotNull);

      final SessionRecord sessionB = service.issue(context: context, ttlMs: 60000);

      expect(service.find(sessionA.sessionId), isNull, reason: '旧 session 应被刷新失效');
      expect(service.find(sessionB.sessionId), isNotNull);
      expect(service.sessionCount, 1, reason: '同页至多存活 1 条');
    });

    // C62：docs/09 —— dispatch 对 Async handler 启动即返：busy handler 发射首帧后挂起，
    // 期间 ping（Simple）请求仍可被完整处理（busy 挂起不得阻塞入站管线）
    test('C62_dispatchLaunchesAsyncWithoutBlocking_pipelineKeepsProcessing', () async {
      final Fixture fixture = Fixture(
        methodWhitelist: <String>{'bridge.handshake', 'busy', 'ping'},
      );
      final Completer<void> firstFrameSent = Completer<void>();
      final Completer<void> releaseBusy = Completer<void>();
      fixture.bridge.registerAsyncHandler('busy',
          (TrustedPageContext context, dynamic payload, ResponseEmitter? emitter) async {
        if (emitter == null) return;
        await emitter(
          const Result<dynamic, BridgeError>.success(<String, dynamic>{'tick': 1}),
          false,
        );
        if (!firstFrameSent.isCompleted) {
          firstFrameSent.complete();
        }
        await releaseBusy.future; // 挂起不收尾
        await emitter(
          const Result<dynamic, BridgeError>.success(<String, dynamic>{'tick': 2}),
          true,
        );
      });
      fixture.bridge.registerSimpleHandler('ping',
          (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(<String, dynamic>{'pong': true});
      });
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      final List<String> busyImmediate = await fixture.deliver(
        requestJson('r62a', 'busy', sessionId, keep: true),
      );
      expect(busyImmediate, isEmpty, reason: 'dispatch 启动即返，async 无内联帧');
      await firstFrameSent.future;

      // busy 仍挂起时发起 ping：dispatch 不得被未完成的流式 handler 阻塞
      final List<String> pingResponses = await fixture.deliver(
        requestJson('r62b', 'ping', sessionId),
      );
      expect(pingResponses, hasLength(1));
      final Map<String, dynamic> ping = parse(pingResponses.single);
      expect(ping['reqId'], 'r62b');
      expect(ping['done'], isTrue, reason: 'ping 已完整落定');
      expect((ping['payload'] as Map<String, dynamic>)['pong'], isTrue);

      // busy 依旧只有首帧，无终帧逃逸
      expect(
        fixture.transport.sentMessages
            .map(parse)
            .where((Map<String, dynamic> m) => m['reqId'] == 'r62a'),
        hasLength(1),
      );

      releaseBusy.complete();
    });

    // C64：docs/09 —— Tier-1 kind 路由守卫：standalone CoreBridge 对非 request 信封
    // （response/event 是 Native→JS 方向）不派发——同名 handler 不得被误命中，
    // 不产生任何响应帧。Tier-2 路径由 RequestShapePolicy 先行拒绝（既有用例覆盖）。
    test('C64_dispatchIgnoresNonRequestEnvelopes_tier1kindGuard', () async {
      final FakeBridgeTransport transport = FakeBridgeTransport();
      final CoreBridge core = CoreBridge();
      core.attachTransport(transport.send);
      bool handlerInvoked = false;
      core.registerSimpleHandler('leak.test',
          (TrustedPageContext context, dynamic payload) async {
        handlerInvoked = true;
        return BridgeHandlerResult.success(<String, dynamic>{'leaked': true});
      });
      const TrustedPageContext context =
          TrustedPageContext(origin: 'file://', pageInstanceId: 'page-64');

      // kind=response / kind=event 信封：命中注册表同名 method 也不得派发
      final BridgeMessage responseKind = BridgeMessage(
          id: 'r64a',
          sessionId: '',
          kind: BridgeMessageKind.response,
          method: 'leak.test',
          ts: 1,
          reqId: 'x',
          done: true,
          ok: false);
      final BridgeMessage eventKind = BridgeMessage(
          id: 'r64b',
          sessionId: '',
          kind: BridgeMessageKind.event,
          method: 'leak.test',
          ts: 1,
          payload: <String, dynamic>{});
      final List<String> droppedA = await core.dispatch(responseKind, context);
      final List<String> droppedB = await core.dispatch(eventKind, context);
      expect(droppedA, isEmpty);
      expect(droppedB, isEmpty);
      expect(handlerInvoked, isFalse);
      expect(transport.sentMessages, isEmpty);

      // 对照组：kind=request 正常派发（守卫不得误伤正常路径）
      final BridgeMessage requestKind = BridgeMessage(
          id: 'r64c',
          sessionId: '',
          kind: BridgeMessageKind.request,
          method: 'leak.test',
          ts: 1,
          payload: <String, dynamic>{});
      final List<String> served = await core.dispatch(requestKind, context);
      expect(handlerInvoked, isTrue);
      expect(served, hasLength(1));
    });

    // C65：docs/09 —— 通配 {"*"} 是"对应策略节点不进链"而非"装配后放行一切"：
    // 以真实 JsBridge 装配验证（此前 Origin/MethodGate 的通配排除分支仅为"代码为真、
    // 无用例锁定"——策略链单测 C46 手拼链无法拦截装配层回归）。白名单外方法 +
    // 未白名单 origin 的请求仍能到达 handler；SessionPolicy 仍在链，
    // 换 origin 复用 session 必被拒。对照 Android `c65_wildcardSets_skipOriginAndMethodGate_realAssembly`。
    test('C65_wildcardSets_skipOriginAndMethodGate_realAssembly', () async {
      final FixedOriginProvider provider =
          FixedOriginProvider('https://arbitrary.example');
      final JsBridge bridge = JsBridge(
        securityConfig: SecurityConfig(
          allowedOrigins: <String>{'*'},
          methodWhitelist: <String>{'*'},
        ),
        transport: (String _) async => true,
        pageContextProvider: provider,
      );
      bridge.registerSimpleHandler('not.in.whitelist',
          (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      bridge.resetPageInstance();

      // 握手 → sessionId
      final String sessionId = (parse(
        (await bridge.processIncomingResponses(
          messageJson: requestJson('h1', 'bridge.handshake', ''),
        )).single,
      )['payload'] as Map<String, dynamic>)['sessionId'] as String;
      expect(sessionId, isNotEmpty);

      // 同 origin：Origin/MethodGate 均未进链 → 白名单外业务方法 ok=true 且 reqId 回显
      // （非通配配置下同输入为 E_ORIGIN_DENY / E_METHOD_NOT_ALLOWED，见 C04/C03）
      final List<String> sameOriginResponses = await bridge.processIncomingResponses(
        messageJson: requestJson('r65a', 'not.in.whitelist', sessionId),
      );
      final Map<String, dynamic> sameOrigin = parse(sameOriginResponses.single);
      expect(sameOrigin['ok'], isTrue);
      expect(sameOrigin['reqId'], 'r65a');

      // 换 origin 复用 session：SessionPolicy 仍在链 → E_SESSION_INVALID
      // （通配只豁免对应维度，不影响 session origin 匹配语义）
      provider.origin = 'https://other.example';
      final List<String> diffOriginResponses = await bridge.processIncomingResponses(
        messageJson: requestJson('r65b', 'not.in.whitelist', sessionId),
      );
      expect(errorCode(diffOriginResponses.single), 'E_SESSION_INVALID');
    });

    // 配置拷贝快照：宿主构造后 mutate 传入的 allowedOrigins Set
    // 不得静默改变已装配策略（与 MethodGatePolicy 的防御性拷贝对称）
    test('OriginPolicyConfig_mutatedAfterConstruction_policyUnaffected', () async {
      final Set<String> origins = <String>{'file://'};
      final Fixture fixture = Fixture(allowedOrigins: origins);
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      // 构造后的 mutate：防御性拷贝使策略链保持构造期快照
      origins.clear();
      origins.add('https://evil.example');

      final List<String> responses = await fixture.deliver(
        requestJson('r1', 'echo', sessionId),
      );
      expect(parse(responses.single)['ok'], isTrue);
    });
  });

  group('bindTransport', () {
    test('bindTransport_beforeAttachTransport_throwsStateError', () {
      // 配置错误应在装配期 fail-fast 暴露，而非运行期每条消息静默丢响应
      final JsBridge bridge = JsBridge(
        securityConfig: null,
        pageContextProvider: FixedOriginProvider('file://'),
      );
      bridge.resetPageInstance();

      expect(bridge.bindTransport, throwsStateError);
    });

    test('bindTransport_missingPageContextProvider_throwsStateError', () {
      // provider 未注入应在装配期 fail-fast 暴露，而非运行期每条消息抛 ArgumentError 逃逸为 zone error
      final FakeBridgeTransport transport = FakeBridgeTransport();
      final JsBridge bridge = JsBridge(
        securityConfig: null,
        transport: transport.send,
      );
      bridge.resetPageInstance();

      expect(bridge.bindTransport, throwsStateError);
    });

    test('bindTransport_returnsHandler_sendsResponsesViaTransport', () async {
      final Fixture fixture = Fixture();
      fixture.bridge.registerSimpleHandler('echo', (TrustedPageContext context, dynamic payload) async {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      final Future<void> Function(String) handler =
          fixture.bridge.bindTransport();
      await handler(requestJson('r1', 'echo', sessionId, payload: <String, dynamic>{'v': 42}));

      expect(fixture.transport.sentMessages, hasLength(1));
      final Map<String, dynamic> response = parse(fixture.transport.sentMessages.single);
      expect(response['ok'], isTrue);
      expect((response['payload'] as Map<String, dynamic>)['v'], 42);
    });

    test('sendViaTransport_nullTransport_returnsFalse', () async {
      final CoreBridge core = CoreBridge();
      final bool result = await core.sendViaTransport('{}');
      expect(result, isFalse);
    });

    test('bindTransport_multipleResponses_eachSentViaTransport', () async {
      final Fixture fixture = Fixture(
        methodWhitelist: <String>{'bridge.handshake', 'multi'},
      );
      final Completer<void> emitted = Completer<void>();
      fixture.bridge.registerAsyncHandler('multi',
          (TrustedPageContext context, dynamic payload, ResponseEmitter? emitter) async {
        if (emitter == null) return;
        await emitter(
          const Result<dynamic, BridgeError>.success(<String, dynamic>{'i': 0}),
          false,
        );
        await emitter(
          const Result<dynamic, BridgeError>.success(<String, dynamic>{'i': 1}),
          true,
        );
        if (!emitted.isCompleted) {
          emitted.complete();
        }
      });
      fixture.bridge.resetPageInstance();
      final String sessionId = await fixture.handshake();

      final Future<void> Function(String) handler =
          fixture.bridge.bindTransport();
      await handler(requestJson('r1', 'multi', sessionId));
      await emitted.future;
      await Future<void>.delayed(Duration.zero);

      expect(fixture.transport.sentMessages, hasLength(2));
      expect(parse(fixture.transport.sentMessages[0])['payload'], <String, dynamic>{'i': 0});
      expect(parse(fixture.transport.sentMessages[1])['payload'], <String, dynamic>{'i': 1});
    });
  });
}

/// origin 可变（构造后可赋值，供 session origin 漂移类用例使用），
/// 亦兼任固定 origin 的默认注入。
class FixedOriginProvider implements PageContextProvider {
  FixedOriginProvider(this.origin);
  String origin;

  @override
  TrustedPageContext createContext(BridgeMessage message, String pageInstanceId) =>
      TrustedPageContext(origin: origin, pageInstanceId: pageInstanceId);
}

class Fixture {
  Fixture({
    Set<String>? allowedOrigins,
    Set<String>? methodWhitelist,
    List<ExtraPolicy>? extraPolicies,
  }) {
    bridge = JsBridge(
      securityConfig: SecurityConfig(
        allowedOrigins: allowedOrigins ?? <String>{'file://'},
        methodWhitelist: methodWhitelist ?? <String>{'bridge.handshake', 'echo'},
        extraPolicies: extraPolicies ?? const <ExtraPolicy>[],
      ),
      transport: transport.send,
      pageContextProvider: FixedOriginProvider('file://'),
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
  bool keep = false,
}) {
  return jsonEncode(<String, dynamic>{
    'id': id,
    'sessionId': sessionId,
    'kind': 'request',
    'method': method,
    'ts': 1,
    'timeoutMs': 1000,
    'keep': keep,
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
