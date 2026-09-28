import { describe, it, expect } from '@ohos/hypium';
import {
  BridgeError,
  BridgeHandlerResult,
  BridgeMessage,
  BridgeMessageKind,
  CoreBridge,
  JsBridge,
  OriginNormalizer,
  PageContextProvider,
  PolicyDecision,
  SessionService,
  TrustedPageContext,
  LifecycleExtension,
  Result,
  ResponseEmitter
} from '@xesam/js_bridge_core';

export default function conformanceCoreBaselineTest(): void {
  describe('Harmony core conformance baseline', () => {
    it('C01_requestBeforeHandshake_deniedByGate', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.resetPageInstance();

      const responses = await fixture.deliver(requestJson('r1', 'echo', ''));

      expect(errorCode(responses[0])).assertEqual('E_NOT_READY'); // v1: 握手门禁从 E_POLICY_DENY 分立
    });

    it('C02_handshake_returnsSessionPayload', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.resetPageInstance();

      const response = parse((await fixture.deliver(requestJson('h1', 'bridge.handshake', '')))[0]);
      const payload = response['payload'] as Record<string, Object>;

      expect(response['ok'] as boolean).assertTrue();
      expect((payload['sessionId'] as string).length > 0).assertTrue();
      expect(payload['origin'] as string).assertEqual('file://');
      expect(payload['accepted'] as boolean).assertTrue();
    });

    it('C03_methodNotAllowed_denied', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'notAllowed', sessionId));

      expect(errorCode(responses[0])).assertEqual('E_METHOD_NOT_ALLOWED');
    });

    it('C04_originNotAllowed_denied', 0, async () => {
      const fixture = new Fixture(new Set<string>(['https://trusted.example']));
      fixture.bridge.resetPageInstance();

      const responses = await fixture.deliver(requestJson('h1', 'bridge.handshake', ''));

      expect(errorCode(responses[0])).assertEqual('E_ORIGIN_DENY');
    });

    it('C04b_originPrefixButNotExact_denied', 0, async () => {
      const fixture = new Fixture(new Set<string>(['https://trusted.example']));
      fixture.bridge.resetPageInstance();

      // origin 是白名单条目的前缀延伸，不是精确匹配 → 拒绝
      const responses = await fixture.deliver(requestJson('h1', 'bridge.handshake', ''), 'https://trusted.example.evil');

      expect(errorCode(responses[0])).assertEqual('E_ORIGIN_DENY');
    });

    it('C05_validHandshakeThenValidRequest_success', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const response = parse((await fixture.deliver(requestJson('r1', 'echo', sessionId, { 'k': 'v' })))[0]);

      expect(response['ok'] as boolean).assertTrue();
      expect(response['method'] as string).assertEqual('echo');
    });

    it('C06_missingSessionAfterReady_denied', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();
      await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'echo', ''));

      expect(errorCode(responses[0])).assertEqual('E_SESSION_INVALID');
    });

    it('C07_sessionOriginMismatch_denied', 0, async () => {
      const fixture = new Fixture(new Set<string>(['file://', 'https://trusted.example']));
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'echo', sessionId), 'https://trusted.example');

      expect(errorCode(responses[0])).assertEqual('E_SESSION_INVALID');
    });

    it('C08_sessionPageMismatch_denied', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const responses = await fixture.bridge.processIncomingResponsesForContext(
        requestJson('r1', 'echo', sessionId),
        new TrustedPageContext('file://', 'forced-page-mismatch')
      );

      expect(errorCode(responses[0])).assertEqual('E_SESSION_INVALID');
    });

    it('C10_methodNotFound_denied', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'missing'])
      );
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'missing', sessionId));

      expect(errorCode(responses[0])).assertEqual('E_METHOD_NOT_FOUND');
    });

    it('C11_handlerThrows_normalizedToInternal', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => {
          throw new Error('boom');
        });
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'echo', sessionId));

      expect(errorCode(responses[0])).assertEqual('E_INTERNAL');
    });

    it('C12_extraPolicyDeny_takesEffect', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge = new JsBridge({
        securityConfig: {
          allowedOrigins: new Set<string>(['file://']),
          methodWhitelist: new Set<string>(['bridge.handshake', 'echo']),
          extraPolicies: [
            (request: BridgeMessage) => request.method === 'echo'
              ? new BridgeError('E_TEST_DENY', 'blocked')
              : null
          ]
        },
        transport: (messageJson: string) => fixture.transport.send(messageJson)
      });
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'echo', sessionId));

      expect(errorCode(responses[0])).assertEqual('E_TEST_DENY');
    });

    it('C13_streamingResponse_emitsDoneFalseThenDoneTrue', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'stream']),
        new FilePageContextProvider('file://')
      );
      const tick1: Record<string, Object> = { 'tick': 1 };
      const tick2: Record<string, Object> = { 'tick': 2 };
      // 多帧只能由 Async Handler 表达（Simple 恒为单帧、done 恒为 true）
      fixture.bridge.registerAsyncHandler('stream',
        async (context: TrustedPageContext, payload: Object | null, emitter: ResponseEmitter | null): Promise<void> => {
          if (emitter === null) {
            return;
          }
          await emitter(Result.success<Object, BridgeError>(tick1), false);
          await emitter(Result.success<Object, BridgeError>(tick2), true);
        });
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      // async handler 的帧经 emitter -> transport 路径发出，不经 deliver 的返回值
      const handler = fixture.bridge.bindTransport();
      await handler(requestJson('r1', 'stream', sessionId, {}, true));
      // dispatch 启动即返（C62）：handler 帧经 microtask 发出，先 pump 落定再 harvest
      await pump();

      const frames: Record<string, Object>[] = [];
      for (const sent of fixture.transport.sentMessages) {
        const message = parse(sent);
        if ((message['reqId'] as string) === 'r1') {
          frames.push(message);
        }
      }
      // keep=true 的流式请求：两帧按序到达，首帧 done=false、末帧 done=true
      expect(frames.length).assertEqual(2);
      expect(frames[0]['keep'] as boolean).assertTrue();
      expect(frames[0]['done'] as boolean).assertFalse();
      expect((frames[0]['payload'] as Record<string, Object>)['tick'] as number).assertEqual(1);
      expect(frames[1]['keep'] as boolean).assertTrue();
      expect(frames[1]['done'] as boolean).assertTrue();
      expect((frames[1]['payload'] as Record<string, Object>)['tick'] as number).assertEqual(2);
    });

    it('C17_sendFailure_observableAndPostEventReturnsFalse', 0, async () => {
      const fixture = new Fixture();
      fixture.transport.sendEnabled = false;
      fixture.bridge.resetPageInstance();
      await fixture.handshake();

      const statePayload: Record<string, Object> = { 'state': 'ready' };
      const sent = await fixture.bridge.postEvent('runtime.state', statePayload);

      expect(sent).assertFalse();
    });

    it('C18_resetPageInstanceRotatesContext_oldSessionInvalid', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();
      const oldSessionId = await fixture.handshake();

      fixture.bridge.resetPageInstance();
      await fixture.handshake();
      const responses = await fixture.deliver(requestJson('r1', 'echo', oldSessionId));

      expect(errorCode(responses[0])).assertEqual('E_SESSION_INVALID');
    });

    it('C28_lifecycleEventsBeforeReady_queuedAndFlushedInOrder', 0, async () => {
      const fixture = new Fixture();
      const lifecycle = new LifecycleExtension(fixture.bridge);
      fixture.bridge.resetPageInstance();

      await lifecycle.onHostEvent('created');
      await lifecycle.onHostEvent('started');
      await lifecycle.onHostEvent('resumed');
      expect(lifecycleEvents(fixture).length).assertEqual(0);

      await fixture.handshake();
      await pump();

      const events = lifecycleEvents(fixture);
      expect(events.length).assertEqual(3);
      expect(events[0]['state'] as string).assertEqual('created');
      expect(events[1]['state'] as string).assertEqual('started');
      expect(events[2]['state'] as string).assertEqual('resumed');
      expect(events[0]['seq'] as number).assertEqual(1);
      expect(events[1]['seq'] as number).assertEqual(2);
      expect(events[2]['seq'] as number).assertEqual(3);
    });

    it('C29_lifecycleQueueOverflow_dropsOldestKeepsSeq', 0, async () => {
      const fixture = new Fixture();
      const lifecycle = new LifecycleExtension(fixture.bridge, 2);
      fixture.bridge.resetPageInstance();

      await lifecycle.onHostEvent('created');
      await lifecycle.onHostEvent('started');
      await lifecycle.onHostEvent('resumed');

      await fixture.handshake();
      await pump();

      const events = lifecycleEvents(fixture);
      expect(events.length).assertEqual(2);
      expect(events[0]['state'] as string).assertEqual('started');
      expect(events[0]['seq'] as number).assertEqual(2);
      expect(events[1]['state'] as string).assertEqual('resumed');
      expect(events[1]['seq'] as number).assertEqual(3);
    });

    it('C30_lifecycleAfterReady_sentImmediatelyWithExactPayload', 0, async () => {
      const fixture = new Fixture();
      const lifecycle = new LifecycleExtension(fixture.bridge);
      fixture.bridge.resetPageInstance();
      await fixture.handshake();

      await lifecycle.onHostEvent('resumed');

      const events = lifecycleEvents(fixture);
      expect(events.length).assertEqual(1);
      expect(events[0]['state'] as string).assertEqual('resumed');
      expect(events[0]['seq'] as number).assertEqual(1);
      expect(Object.keys(events[0]).length).assertEqual(2);
    });

    it('C33_emptyMethod_deniedAsInvalidMessage', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.resetPageInstance();

      const responses = await fixture.deliver(requestJson('r1', '', ''));

      expect(errorCode(responses[0])).assertEqual('E_INVALID_MESSAGE');
    });

    it('C34_missingKind_silentlyDropped', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.resetPageInstance();

      const responses = await fixture.deliver('{"id":"r34","sessionId":"","method":"echo","payload":{}}');

      expect(responses.length).assertEqual(0);
    });

    it('C35_handshakeNotInWhitelist_autoAllowed', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['echo'])
      );
      fixture.bridge.resetPageInstance();

      const responses = await fixture.deliver(requestJson('h1', 'bridge.handshake', ''));

      // 协议方法由框架装配期自动并入放行集，白名单未含 bridge.handshake 时握手仍成功
      const response = parse(responses[0]);
      expect(response['ok'] as boolean).assertTrue();
      const payload = response['payload'] as Record<string, Object>;
      expect((payload['sessionId'] as string).length > 0).assertTrue();
    });

    it('C36_unknownSessionId_denied', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();
      await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'echo', 'bogus-session'));

      expect(errorCode(responses[0])).assertEqual('E_SESSION_INVALID');
    });

    it('C37_cancelScope_echoesPayloadScopeIdWithAccepted', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'bridge.cancelScope'])
      );
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(
        requestJson('c1', 'bridge.cancelScope', sessionId, { 'scopeId': 's-1' })
      );

      const response = parse(responses[0]);
      const payload = response['payload'] as Record<string, Object>;
      expect(response['ok'] as boolean).assertTrue();
      expect(payload['scopeId'] as string).assertEqual('s-1');
      expect(payload['accepted'] as boolean).assertTrue();
    });

    it('C38_missingOptionalFields_defaultsApplied', 0, async () => {
      const transport = new FakeBridgeTransport();
      const bridge = new JsBridge({
        securityConfig: null,
        transport: (messageJson: string) => transport.send(messageJson)
      });
      bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      bridge.resetPageInstance();

      const responses = await bridge.processIncomingResponses(
        '{"id":"r38","kind":"request","method":"echo"}',
        'file://'
      );

      expect(parse(responses[0])['ok'] as boolean).assertTrue();
    });

    it('C43_asyncHandler_multipleResponsesViaEmitter', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'echo']),
        new FilePageContextProvider('file://')
      );
      const frame1: Record<string, Object> = { 'frame': 1 };
      const frame2: Record<string, Object> = { 'frame': 2 };
      const frame3: Record<string, Object> = { 'frame': 3 };
      fixture.bridge.registerAsyncHandler('echo',
        async (context: TrustedPageContext, payload: Object | null, emitter: ResponseEmitter | null): Promise<void> => {
          if (emitter === null) {
            return;
          }
          await emitter(Result.success<Object, BridgeError>(frame1), false);
          await emitter(Result.success<Object, BridgeError>(frame2), false);
          await emitter(Result.success<Object, BridgeError>(frame3), true);
        });
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      // async handler 的帧经 emitter -> transport 路径发出，不经 deliver 的返回值
      const handler = fixture.bridge.bindTransport();
      await handler(requestJson('r43', 'echo', sessionId));
      await pump();

      const frames: Record<string, Object>[] = [];
      for (const sent of fixture.transport.sentMessages) {
        const message = parse(sent);
        if ((message['reqId'] as string) === 'r43') {
          frames.push(message);
        }
      }
      expect(frames.length).assertEqual(3);
      // 前两帧 done=false
      expect(frames[0]['done'] as boolean).assertFalse();
      expect((frames[0]['payload'] as Record<string, Object>)['frame'] as number).assertEqual(1);
      expect(frames[1]['done'] as boolean).assertFalse();
      expect((frames[1]['payload'] as Record<string, Object>)['frame'] as number).assertEqual(2);
      // 末帧 done=true
      expect(frames[2]['done'] as boolean).assertTrue();
      expect((frames[2]['payload'] as Record<string, Object>)['frame'] as number).assertEqual(3);
    });

    it('C48_protocolMethods_autoMergedIntoWhitelist', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['echo']) // 不含任何协议方法
      );
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();
      expect(sessionId.length > 0).assertTrue();

      // 协议方法 bridge.cancelScope 自动放行并回显 scopeId
      const cancelResponses = await fixture.deliver(
        requestJson('c1', 'bridge.cancelScope', sessionId, { 'scopeId': 's-1' })
      );
      const cancelResponse = parse(cancelResponses[0]);
      const cancelPayload = cancelResponse['payload'] as Record<string, Object>;
      expect(cancelResponse['ok'] as boolean).assertTrue();
      expect(cancelPayload['scopeId'] as string).assertEqual('s-1');

      // 白名单外业务方法仍被拒绝
      const forbiddenResponses = await fixture.deliver(requestJson('r1', 'forbidden', sessionId));
      expect(errorCode(forbiddenResponses[0])).assertEqual('E_METHOD_NOT_ALLOWED');

      // 白名单内业务方法正常成功
      const echoResponses = await fixture.deliver(requestJson('r2', 'echo', sessionId));
      expect(parse(echoResponses[0])['ok'] as boolean).assertTrue();
    });

    it('C49_duplicateRegistration_lastWins', 0, async () => {
      // 单一注册表：同一 method 重复注册时后者覆盖前者（无隐式优先级、无并存条目）
      const transport = new FakeBridgeTransport();
      const bridge = new JsBridge({
        securityConfig: null,
        transport: (messageJson: string) => transport.send(messageJson),
        pageContextProvider: new FilePageContextProvider('file://')
      });

      let firstInvoked: boolean = false;
      const h1Payload: Record<string, Object> = { 'src': 'h1' };
      const h2Payload: Record<string, Object> = { 'src': 'h2' };
      bridge.registerSimpleHandler('dup',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => {
          firstInvoked = true;
          return BridgeHandlerResult.success(h1Payload);
        });
      bridge.registerSimpleHandler('dup',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => {
          return BridgeHandlerResult.success(h2Payload);
        });
      bridge.resetPageInstance();

      const responses = await bridge.processIncomingResponses(requestJson('r49', 'dup', ''), 'file://');

      // 仅一帧响应（Simple 恒为单帧），payload 来自后注册的 handler，先注册者从未被调用
      expect(responses.length).assertEqual(1);
      const response = parse(responses[0]);
      expect(response['ok'] as boolean).assertTrue();
      expect(response['method'] as string).assertEqual('dup');
      expect(response['done'] as boolean).assertTrue();
      expect((response['payload'] as Record<string, Object>)['src'] as string).assertEqual('h2');
      expect(firstInvoked).assertFalse();

      // 跨态覆盖：Async 覆盖 Simple 后只剩 Async 的帧序列，无 Simple 残留帧
      const h3Payload: Record<string, Object> = { 'src': 'h3' };
      bridge.registerAsyncHandler('dup',
        async (context: TrustedPageContext, payload: Object | null, emitter: ResponseEmitter | null): Promise<void> => {
          if (emitter === null) {
            return;
          }
          await emitter(Result.success<Object, BridgeError>(h3Payload), false);
          await emitter(Result.success<Object, BridgeError>(h3Payload), true);
        });

      const handler = bridge.bindTransport();
      await handler(requestJson('r49b', 'dup', ''));
      await pump();

      const frames: Record<string, Object>[] = [];
      for (const sent of transport.sentMessages) {
        const message = parse(sent);
        if ((message['reqId'] as string) === 'r49b') {
          frames.push(message);
        }
      }
      expect(frames.length).assertEqual(2);
      expect((frames[0]['payload'] as Record<string, Object>)['src'] as string).assertEqual('h3');
      expect(frames[0]['done'] as boolean).assertFalse();
      expect(frames[1]['done'] as boolean).assertTrue();
    });

    it('C51_invalidRequiredFieldTypes_silentlyDropped', 0, async () => {
      // docs/03 §3.4：必填字段类型非法 → 静默丢弃（禁止宽容转换），四条消息均无任何响应
      const fixture = new Fixture();
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const malformedId = '{"id":123,"sessionId":"","kind":"request","method":"echo","payload":{}}';
      const malformedKind = '{"id":"r51a","sessionId":"","kind":123,"method":"echo","payload":{}}';
      const malformedMethod = '{"id":"r51b","sessionId":"","kind":"request","method":123,"payload":{}}';
      const malformedSessionId = '{"id":"r51c","sessionId":123,"kind":"request","method":"echo","payload":{}}';
      const malformed: string[] = [malformedId, malformedKind, malformedMethod, malformedSessionId];
      for (const raw of malformed) {
        expect((await fixture.deliver(raw)).length).assertEqual(0);
      }

      // 后续正常请求不受影响
      const responses = await fixture.deliver(requestJson('rok', 'echo', sessionId));
      expect(parse(responses[0])['ok'] as boolean).assertTrue();
    });

    it('C52_successNullTerminationFrame_emittedNotSwallowed', 0, async () => {
      // docs/03 §6：无数据成功的终止帧必须照常发出（ok=true、payload=null、done=true），禁止 null 守卫吞帧
      const transport = new FakeBridgeTransport();
      const bridge = new JsBridge({
        securityConfig: null,
        transport: (messageJson: string) => transport.send(messageJson),
        pageContextProvider: new FilePageContextProvider('file://')
      });
      bridge.registerSimpleHandler('noData',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(null));
      bridge.registerAsyncHandler('noDataStream',
        async (context: TrustedPageContext, payload: Object | null, emitter: ResponseEmitter | null): Promise<void> => {
          if (emitter === null) {
            return;
          }
          await emitter(Result.success<Object, BridgeError>(null), true);
        });
      bridge.resetPageInstance();

      // Simple 形态：返回 success(null) → 恰好 1 帧 ok=true、payload=null、done=true
      const responses = await bridge.processIncomingResponses(requestJson('r52', 'noData', ''), 'file://');
      expect(responses.length).assertEqual(1);
      const response = parse(responses[0]);
      expect(response['ok'] as boolean).assertTrue();
      expect(response['payload'] === null).assertTrue();
      expect(response['done'] as boolean).assertTrue();

      // Async + emitter 形态：Result.success(null) 终止帧须照发，
      // 不得被 emitter 适配器的 null 守卫静默吞掉（曾因此挂死 JS 端至超时）
      const handler = bridge.bindTransport();
      await handler(requestJson('r52b', 'noDataStream', ''));
      await pump();

      let frameCount = 0;
      let terminationFrame: Record<string, Object> | null = null;
      for (const sent of transport.sentMessages) {
        const message = parse(sent);
        if ((message['reqId'] as string) === 'r52b') {
          frameCount += 1;
          terminationFrame = message;
        }
      }
      expect(frameCount).assertEqual(1);
      expect(terminationFrame !== null).assertTrue();
      expect(terminationFrame!['ok'] as boolean).assertTrue();
      expect(terminationFrame!['payload'] === null).assertTrue();
      expect(terminationFrame!['done'] as boolean).assertTrue();
    });

    it('C53_extraPolicyDenyWithoutError_fallbackPolicyDeny', 0, async () => {
      // docs/03 §9 细则 3：deny 但缺 error 时以 E_POLICY_DENY 兜底，禁止静默放行到 dispatch
      const fixture = new Fixture();
      fixture.bridge = new JsBridge({
        securityConfig: {
          allowedOrigins: new Set<string>(['file://']),
          methodWhitelist: new Set<string>(['bridge.handshake', 'echo']),
          extraPolicies: [
            (request: BridgeMessage): PolicyDecision | null =>
              request.method === 'echo' ? PolicyDecision.deny(null) : null
          ]
        },
        transport: (messageJson: string) => fixture.transport.send(messageJson)
      });
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'echo', sessionId));
      expect(parse(responses[0])['ok'] as boolean).assertFalse();
      expect(errorCode(responses[0])).assertEqual('E_POLICY_DENY');
    });

    it('C54_originNormalization_protocolContract', 0, () => {
      // docs/03 §9 细则 5：默认端口（443/80）省略、非默认端口保留、URL 缺失 → 空串
      expect(OriginNormalizer.normalize('https://host:443')).assertEqual('https://host');
      expect(OriginNormalizer.normalize('http://host:80')).assertEqual('http://host');
      expect(OriginNormalizer.normalize('https://host:8443')).assertEqual('https://host:8443');
      expect(OriginNormalizer.normalize('http://host:8080')).assertEqual('http://host:8080');
      expect(OriginNormalizer.normalize('')).assertEqual('');
      // scheme 与 host 小写
      expect(OriginNormalizer.normalize('HTTPS://Host:8443')).assertEqual('https://host:8443');
      expect(OriginNormalizer.normalize('http://Host:80/Path?Q=1')).assertEqual('http://host');
      // 本地内容协议保留 scheme 语义；无 host 的其他非 file scheme → 空串（fail-closed）
      expect(OriginNormalizer.normalize('file:///path')).assertEqual('file://');
      expect(OriginNormalizer.normalize('about:blank')).assertEqual('');
    });

    it('C54_originNormalizer_vectorSuite', 0, () => {
      // 四端共享的 origin 归一化全量向量，正本为 docs/origin-normalizer-vectors.json，
      // 由 scripts/check_origin_vectors.sh 强制四端 C54 测试内嵌同一向量集——修改必须四端同改
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

    it('C55_postEventWithoutSessionId_emptyStringBroadcast', 0, async () => {
      // docs/03 §3.3：v1 事件投放唯一形态为广播——事件帧 sessionId 恒为空串 ""，
      // 即便存在活跃 session 也不得默认定向。postEvent 为两参 API（method, payload），
      // 无定向投送入口——四端一致。
      const transport = new FakeBridgeTransport();
      const bridge = new JsBridge({
        securityConfig: null,
        transport: (messageJson: string) => transport.send(messageJson)
      });
      bridge.resetPageInstance(); // 无配置 → 立即 ready
      await bridge.processIncomingResponses(requestJson('h1', 'bridge.handshake', ''), 'file://'); // 握手建立 session

      const payload: Record<string, Object> = { 'state': 'custom' };
      const sent = await bridge.postEvent('runtime.state', payload);
      expect(sent).assertTrue();

      const message = parse(transport.sentMessages[0]);
      expect(message['kind'] as string).assertEqual('event');
      expect(message['method'] as string).assertEqual('runtime.state');
      expect(message['sessionId'] as string).assertEqual('');
    });

    it('C56_issueSweepsExpiredRecords_storageNotRetained', 0, () => {
      // docs/03 §10：签发时顺带清扫过期记录。时钟不可注入，
      // 与 SessionServiceTest 既有过期用例一致以负 TTL 使记录立即过期；
      // 各 session 用不同 pageInstanceId，避免触发 C61 刷新语义
      const service = new SessionService();
      service.issue(new TrustedPageContext('file://', 'page-56a'), 60000); // 未过期条目不受清扫影响
      const expired = service.issue(new TrustedPageContext('file://', 'page-56b'), -1);
      expect(service.recordCount()).assertEqual(2);

      // 再次签发（握手高频场景）：issue 顺带清扫，过期记录自存储移除
      const active = service.issue(new TrustedPageContext('file://', 'page-56c'), 60000);
      const found = service.find(active.sessionId);
      expect(found !== null).assertTrue();
      expect(found!.sessionId).assertEqual(active.sessionId);
      expect(service.recordCount()).assertEqual(2); // 过期记录已被移除而非仅靠 find 惰性删除
      // 查询过期 session 失败（E_SESSION_INVALID 语义）
      expect(service.find(expired.sessionId)).assertNull();
    });

    it('C60_sessionTtlZero_neverExpires', 0, () => {
      // docs/03 §10 三态：ttlMs=0 → -1 哨兵，永不过期（此前误实现为立即过期）；
      // 各 session 用不同 pageInstanceId，避免触发 C61 刷新语义
      const service = new SessionService();
      const forever = service.issue(new TrustedPageContext('file://', 'page-60a'), 0);
      const normal = service.issue(new TrustedPageContext('file://', 'page-60b'), 60000);

      // 再次签发触发的全表清扫不得移除永不过期记录
      service.issue(new TrustedPageContext('file://', 'page-60c'), 60000);
      expect(service.recordCount()).assertEqual(3);
      expect(service.find(forever.sessionId) !== null).assertTrue();
      expect(service.find(normal.sessionId) !== null).assertTrue();
    });

    it('C61_repeatedHandshakeRefreshes_invalidatesPriorSession', 0, () => {
      // docs/03 §7.1 幂等性：同 pageInstanceId 重复握手应"刷新"而非并存
      const service = new SessionService();
      const ctx = new TrustedPageContext('file://', 'page-61');
      const sessionA = service.issue(ctx, 60000);
      expect(service.find(sessionA.sessionId) !== null).assertTrue();

      const sessionB = service.issue(ctx, 60000);
      expect(service.find(sessionA.sessionId)).assertNull(); // 旧 session 已被刷新失效
      expect(service.find(sessionB.sessionId) !== null).assertTrue();
      expect(service.recordCount()).assertEqual(1); // 同页至多存活 1 条
    });

    it('C62_dispatchLaunchesAsyncWithoutBlocking_pipelineKeepsProcessing', 0, async () => {
      // docs/09 C62：dispatch 对 Async handler 启动即返——busy handler 发射首帧后挂起，
      // 期间 ping（Simple）请求仍可被完整处理（busy 挂起不得阻塞入站管线）。
      // HarmonyOS 曾为四端中唯一的内联 await 实现（长流式 handler 挂死整条 bindTransport 闭环），
      // 本用例即该语义对齐后的回归锚点
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'busy', 'ping']),
        new FilePageContextProvider('file://')
      );
      let releaseBusy: () => void = (): void => {};
      const busyGate: Promise<void> = new Promise<void>((resolve: () => void) => {
        releaseBusy = resolve;
      });
      // ArkTS 禁止未类型化对象字面量（arkts-no-untyped-obj-literals）：先声明带类型的 Record
      const busyTick1: Record<string, Object> = { 'tick': 1 };
      const busyTick2: Record<string, Object> = { 'tick': 2 };
      const pongPayload: Record<string, Object> = { 'pong': true };
      fixture.bridge.registerAsyncHandler('busy',
        async (context: TrustedPageContext, payload: Object | null, emitter: ResponseEmitter | null): Promise<void> => {
          if (emitter === null) {
            return;
          }
          await emitter(Result.success<Object, BridgeError>(busyTick1), false);
          await busyGate; // 挂起不收尾
          await emitter(Result.success<Object, BridgeError>(busyTick2), true);
        });
      fixture.bridge.registerSimpleHandler('ping',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult =>
          BridgeHandlerResult.success(pongPayload));
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const handler = fixture.bridge.bindTransport();
      await handler(requestJson('r62a', 'busy', sessionId, {}, true));
      await pump(); // busy 首帧经 microtask 发出

      // busy 仍挂起时发起 ping：dispatch 不得被未完成的流式 handler 阻塞
      await handler(requestJson('r62b', 'ping', sessionId));
      await pump();

      const busyFrames: Record<string, Object>[] = [];
      let pingResponse: Record<string, Object> | null = null;
      for (const sent of fixture.transport.sentMessages) {
        const message = parse(sent);
        if ((message['reqId'] as string) === 'r62a') {
          busyFrames.push(message);
        } else if ((message['reqId'] as string) === 'r62b') {
          pingResponse = message;
        }
      }
      expect(busyFrames.length).assertEqual(1); // busy 仅有首帧，无终帧逃逸
      expect(busyFrames[0]['done'] as boolean).assertFalse();
      expect(pingResponse !== null).assertTrue(); // busy 挂起期间 ping 已被完整处理
      expect(pingResponse!['done'] as boolean).assertTrue();
      expect((pingResponse!['payload'] as Record<string, Object>)['pong'] as boolean).assertTrue();

      releaseBusy();
      await pump();
    });

    // C64：docs/09 —— Tier-1 kind 路由守卫：standalone CoreBridge 对非 request 信封
    // （response/event 是 Native→JS 方向）不派发——同名 handler 不得被误命中，
    // 不产生任何响应帧。Tier-2 路径由 RequestShapePolicy 先行拒绝（既有用例覆盖）。
    it('C64_dispatchIgnoresNonRequestEnvelopes_tier1kindGuard', 0, async () => {
      const transport = new FakeBridgeTransport();
      const core = new CoreBridge((messageJson: string): boolean => transport.send(messageJson));
      // ArkTS 禁止未类型化对象字面量（arkts-no-untyped-obj-literals）：先声明带类型的 Record
      const leakPayload: Record<string, Object> = { 'leaked': true };
      const emptyPayload: Record<string, Object> = {};
      let handlerInvoked = false;
      core.registerSimpleHandler('leak.test',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => {
          handlerInvoked = true;
          return BridgeHandlerResult.success(leakPayload);
        });
      const context = new TrustedPageContext('file://', 'page-64');

      // kind=response / kind=event 信封：命中注册表同名 method 也不得派发
      const responseKind = new BridgeMessage('r64a', '', BridgeMessageKind.RESPONSE, 'leak.test', 1, 0, false,
        null, 'x', true, false, null, null);
      const eventKind = new BridgeMessage('r64b', '', BridgeMessageKind.EVENT, 'leak.test', 1, 0, false,
        emptyPayload, null, null, null, null, null);
      const droppedA: string[] = await core.dispatch(responseKind, context);
      const droppedB: string[] = await core.dispatch(eventKind, context);
      expect(droppedA.length).assertEqual(0);
      expect(droppedB.length).assertEqual(0);
      expect(handlerInvoked).assertFalse();
      expect(transport.sentMessages.length).assertEqual(0);

      // 对照组：kind=request 正常派发（守卫不得误伤正常路径）
      const requestKind = new BridgeMessage('r64c', '', BridgeMessageKind.REQUEST, 'leak.test', 1, 0, false,
        emptyPayload, null, null, null, null, null);
      const served: string[] = await core.dispatch(requestKind, context);
      expect(handlerInvoked).assertTrue();
      expect(served.length).assertEqual(1);
    });

    // C65：docs/09 —— 通配 {"*"} 是"对应策略节点不进链"而非"装配后放行一切"：
    // 以真实 JsBridge 装配验证（此前 Origin/MethodGate 的通配排除分支仅为"代码为真、无用例锁定"——
    // 策略链单测 C45/C46 手拼链无法拦截装配层回归）。白名单外方法 + 未白名单 origin 的请求
    // 仍能到达 handler；SessionPolicy 仍在链，换 origin 复用 session 必被拒。
    it('C65_wildcardSets_skipOriginAndMethodGate_realAssembly', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['*']),
        new Set<string>(['*'])
      );
      fixture.bridge.registerSimpleHandler('not.in.whitelist',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => BridgeHandlerResult.success(payload));
      fixture.bridge.resetPageInstance();

      // 握手：origin 为未白名单的 'https://arbitrary.example'，Origin 节点未进链 → 不拦截
      const handshakeResponse = parse(
        (await fixture.deliver(requestJson('h65', 'bridge.handshake', ''), 'https://arbitrary.example'))[0]
      );
      expect(handshakeResponse['ok'] as boolean).assertTrue();
      const sessionId = (handshakeResponse['payload'] as Record<string, Object>)['sessionId'] as string;
      expect(sessionId.length > 0).assertTrue();

      // 同 origin：Origin/MethodGate 均未进链 → 白名单外业务方法 ok=true 且 reqId 回显
      // （非通配配置下同输入为 E_ORIGIN_DENY / E_METHOD_NOT_ALLOWED，见 C04/C03）
      const served = parse(
        (await fixture.deliver(requestJson('r65a', 'not.in.whitelist', sessionId), 'https://arbitrary.example'))[0]
      );
      expect(served['ok'] as boolean).assertTrue();
      expect(served['reqId'] as string).assertEqual('r65a');

      // 换 origin 复用 session：SessionPolicy 仍在链 → ok=false、E_SESSION_INVALID
      // （通配只豁免对应维度，不影响 session origin 匹配语义）
      const deniedRaw =
        (await fixture.deliver(requestJson('r65b', 'not.in.whitelist', sessionId), 'https://other.example'))[0];
      const denied = parse(deniedRaw);
      expect(denied['ok'] as boolean).assertFalse();
      expect(((denied['error'] as Record<string, Object>)['code']) as string).assertEqual('E_SESSION_INVALID');
    });

    // 构造期守门对称断言（与 Android/Flutter/iOS 三端构造校验用例同义，四端义务不携带 C 编号）：
    // SecurityConfig 存在时 allowedOrigins / methodWhitelist 任一为 null 均须构造期抛错
    it('config_withoutAllowedOrigins_rejectedAtConstruction', 0, () => {
      let threw = false;
      try {
        new JsBridge({
          securityConfig: {
            allowedOrigins: null,
            methodWhitelist: new Set<string>(['*'])
          }
        });
      } catch (e) {
        threw = true;
        expect(e instanceof Error).assertTrue();
        expect((e as Error).message.includes('allowedOrigins')).assertTrue();
      }
      expect(threw).assertTrue();
    });

    it('config_withoutMethodWhitelist_rejectedAtConstruction', 0, () => {
      let threw = false;
      try {
        new JsBridge({
          securityConfig: {
            allowedOrigins: new Set<string>(['*']),
            methodWhitelist: null
          }
        });
      } catch (e) {
        threw = true;
        expect(e instanceof Error).assertTrue();
        expect((e as Error).message.includes('methodWhitelist')).assertTrue();
      }
      expect(threw).assertTrue();
    });
  });

  describe('bindTransport', () => {
    it('bindTransport_sendsResponsesViaTransport', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'echo']),
        new FilePageContextProvider('file://')
      );
      fixture.bridge.registerSimpleHandler('echo',
        (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => {
          return BridgeHandlerResult.success(payload);
        });
      fixture.bridge.resetPageInstance();
      const sessionId = await fixture.handshake();

      const handler = fixture.bridge.bindTransport();
      await handler(requestJson('r1', 'echo', sessionId, { 'v': 42 }));

      expect(fixture.transport.sentMessages.length).assertEqual(1);
      const response = parse(fixture.transport.sentMessages[0]);
      expect(response['ok'] as boolean).assertTrue();
      expect((response['payload'] as Record<string, Object>)['v'] as number).assertEqual(42);
    });

    it('sendViaTransport_nullTransport_returnsFalse', 0, async () => {
      const core = new CoreBridge();
      const result = await core.sendViaTransport('{}');
      expect(result).assertFalse();
    });
  });
}

class Fixture {
  bridge: JsBridge;
  readonly transport: FakeBridgeTransport = new FakeBridgeTransport();

  constructor(
    allowedOrigins: Set<string> = new Set<string>(['file://']),
    methodWhitelist: Set<string> = new Set<string>(['bridge.handshake', 'echo']),
    pageContextProvider?: PageContextProvider
  ) {
    this.bridge = new JsBridge({
      securityConfig: {
        allowedOrigins,
        methodWhitelist
      },
      transport: (messageJson: string) => this.transport.send(messageJson),
      pageContextProvider: pageContextProvider
    });
  }

  async handshake(): Promise<string> {
    const response = parse((await this.deliver(requestJson('h1', 'bridge.handshake', '')))[0]);
    const payload = response['payload'] as Record<string, Object>;
    return payload['sessionId'] as string;
  }

  deliver(messageJson: string, origin: string = 'file://'): Promise<string[]> {
    return this.bridge.processIncomingResponses(messageJson, origin);
  }
}

class FilePageContextProvider implements PageContextProvider {
  private readonly origin: string;
  constructor(origin: string) { this.origin = origin; }
  createContext(_message: BridgeMessage, pageInstanceId: string): TrustedPageContext {
    return new TrustedPageContext(this.origin, pageInstanceId);
  }
}

class FakeBridgeTransport {
  sendEnabled: boolean = true;
  readonly sentMessages: string[] = [];

  send(messageJson: string): boolean {
    if (!this.sendEnabled) {
      return false;
    }
    this.sentMessages.push(messageJson);
    return true;
  }
}

function requestJson(
  id: string,
  method: string,
  sessionId: string,
  payload: Record<string, Object> = {},
  keep: boolean = false
): string {
  return JSON.stringify({
    'id': id,
    'sessionId': sessionId,
    'kind': 'request',
    'method': method,
    'ts': 1,
    'timeoutMs': 1000,
    'keep': keep,
    'payload': payload
  });
}

function parse(raw: string): Record<string, Object> {
  return JSON.parse(raw) as Record<string, Object>;
}

function errorCode(raw: string): string {
  const json = parse(raw);
  const error = json['error'] as Record<string, Object>;
  return error['code'] as string;
}

/** C54 向量套件的单条断言（docs/origin-normalizer-vectors.json 正本，四端同构）。 */
function v(input: string, expected: string): void {
  expect(OriginNormalizer.normalize(input)).assertEqual(expected);
}

function lifecycleEvents(fixture: Fixture): Record<string, Object>[] {
  const events: Record<string, Object>[] = [];
  for (const sent of fixture.transport.sentMessages) {
    const message = parse(sent);
    if (message['kind'] as string === 'event'
      && message['method'] as string === 'runtime.state') {
      events.push(message['payload'] as Record<string, Object>);
    }
  }
  return events;
}

function pump(): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, 0));
}
