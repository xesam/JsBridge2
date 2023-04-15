import { describe, it, expect } from '@ohos/hypium';
import {
  BridgeError,
  BridgeHandlerResult,
  BridgeMessage,
  CoreBridge,
  JsBridge,
  PageContextProvider,
  TrustedPageContext,
  LifecycleExtension
} from '../../Index';

export default function conformanceCoreBaselineTest(): void {
  describe('Harmony core conformance baseline', () => {
    it('C01_requestBeforeHandshake_deniedByGate', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.resetForNewPage();

      const responses = await fixture.deliver(requestJson('r1', 'echo', ''));

      expect(errorCode(responses[0])).assertEqual('E_POLICY_DENY');
    });

    it('C02_handshake_returnsSessionPayload', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.resetForNewPage();

      const response = parse((await fixture.deliver(requestJson('h1', 'bridge.handshake', '')))[0]);
      const payload = response['payload'] as Record<string, Object>;

      expect(response['ok'] as boolean).assertTrue();
      expect((payload['sessionId'] as string).length > 0).assertTrue();
      expect(payload['origin'] as string).assertEqual('file://');
      expect(payload['accepted'] as boolean).assertTrue();
    });

    it('C03_methodNotAllowed_denied', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.resetForNewPage();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'notAllowed', sessionId));

      expect(errorCode(responses[0])).assertEqual('E_METHOD_NOT_ALLOWED');
    });

    it('C04_originNotAllowed_denied', 0, async () => {
      const fixture = new Fixture(new Set<string>(['https://trusted.example']));
      fixture.bridge.resetForNewPage();

      const responses = await fixture.deliver(requestJson('h1', 'bridge.handshake', ''));

      expect(errorCode(responses[0])).assertEqual('E_ORIGIN_DENY');
    });

    it('C05_validHandshakeThenValidRequest_success', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerHandler('echo', (payload) => BridgeHandlerResult.success(payload));
      fixture.bridge.resetForNewPage();
      const sessionId = await fixture.handshake();

      const response = parse((await fixture.deliver(requestJson('r1', 'echo', sessionId, { 'k': 'v' })))[0]);

      expect(response['ok'] as boolean).assertTrue();
      expect(response['method'] as string).assertEqual('echo');
    });

    it('C06_missingSessionAfterReady_denied', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerHandler('echo', (payload) => BridgeHandlerResult.success(payload));
      fixture.bridge.resetForNewPage();
      await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'echo', ''));

      expect(errorCode(responses[0])).assertEqual('E_SESSION_INVALID');
    });

    it('C07_sessionOriginMismatch_denied', 0, async () => {
      const fixture = new Fixture(new Set<string>(['file://', 'https://trusted.example']));
      fixture.bridge.registerHandler('echo', (payload) => BridgeHandlerResult.success(payload));
      fixture.bridge.resetForNewPage();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'echo', sessionId), 'https://trusted.example');

      expect(errorCode(responses[0])).assertEqual('E_SESSION_INVALID');
    });

    it('C08_sessionPageMismatch_denied', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerHandler('echo', (payload) => BridgeHandlerResult.success(payload));
      fixture.bridge.resetForNewPage();
      const sessionId = await fixture.handshake();

      const responses = await fixture.bridge.processIncomingResponsesForContext(
        requestJson('r1', 'echo', sessionId),
        new TrustedPageContext('file://', 'forced-page-mismatch')
      );

      expect(errorCode(responses[0])).assertEqual('E_SESSION_INVALID');
    });

    it('C09_capabilityDenied_denied', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'admin']),
        new Set<string>(['echo'])
      );
      fixture.bridge.resetForNewPage();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'admin', sessionId));

      expect(errorCode(responses[0])).assertEqual('E_CAPABILITY_DENY');
    });

    it('C10_methodNotFound_denied', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'missing']),
        new Set<string>(['missing'])
      );
      fixture.bridge.resetForNewPage();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'missing', sessionId));

      expect(errorCode(responses[0])).assertEqual('E_METHOD_NOT_FOUND');
    });

    it('C11_handlerThrows_normalizedToInternal', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerHandler('echo', () => {
        throw new Error('boom');
      });
      fixture.bridge.resetForNewPage();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'echo', sessionId));

      expect(errorCode(responses[0])).assertEqual('E_INTERNAL');
    });

    it('C12_extraPolicyDeny_takesEffect', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge = new JsBridge({
        allowedOrigins: new Set<string>(['file://']),
        methodWhitelist: new Set<string>(['bridge.handshake', 'echo']),
        defaultCapabilities: new Set<string>(['echo']),
        extraPolicies: [
          (request: BridgeMessage) => request.method === 'echo'
            ? new BridgeError('E_TEST_DENY', 'blocked')
            : null
        ],
        transport: fixture.transport.send.bind(fixture.transport)
      });
      fixture.bridge.registerHandler('echo', (payload) => BridgeHandlerResult.success(payload));
      fixture.bridge.resetForNewPage();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'echo', sessionId));

      expect(errorCode(responses[0])).assertEqual('E_TEST_DENY');
    });

    it('C13_streamingResponse_emitsDoneFalseThenDoneTrue', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'stream']),
        new Set<string>(['stream'])
      );
      fixture.bridge.registerStreamingHandler('stream', () => [
        BridgeHandlerResult.success({ 'tick': 1 }, false),
        BridgeHandlerResult.success({ 'tick': 2 }, true)
      ]);
      fixture.bridge.resetForNewPage();
      const sessionId = await fixture.handshake();

      const responses = await fixture.deliver(requestJson('r1', 'stream', sessionId));

      expect(responses.length).assertEqual(2);
      expect(parse(responses[0])['done'] as boolean).assertFalse();
      expect(parse(responses[1])['done'] as boolean).assertTrue();
    });

    it('C17_sendFailure_observableAndPostEventReturnsFalse', 0, async () => {
      const fixture = new Fixture();
      fixture.transport.sendEnabled = false;
      fixture.bridge.resetForNewPage();
      await fixture.handshake();

      const sent = await fixture.bridge.postEvent('runtime.state', { 'state': 'ready' });

      expect(sent).assertFalse();
      expect(fixture.bridge.sendFailureCount()).assertEqual(1);
    });

    it('C18_resetForNewPageRotatesContext_oldSessionInvalid', 0, async () => {
      const fixture = new Fixture();
      fixture.bridge.registerHandler('echo', (payload) => BridgeHandlerResult.success(payload));
      fixture.bridge.resetForNewPage();
      const oldSessionId = await fixture.handshake();

      fixture.bridge.resetForNewPage();
      await fixture.handshake();
      const responses = await fixture.deliver(requestJson('r1', 'echo', oldSessionId));

      expect(errorCode(responses[0])).assertEqual('E_SESSION_INVALID');
    });

    it('C28_lifecycleEventsBeforeReady_queuedAndFlushedInOrder', 0, async () => {
      const fixture = new Fixture();
      const lifecycle = new LifecycleExtension(fixture.bridge);
      fixture.bridge.resetForNewPage();

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
      fixture.bridge.resetForNewPage();

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
      fixture.bridge.resetForNewPage();
      await fixture.handshake();

      await lifecycle.onHostEvent('resumed');

      const events = lifecycleEvents(fixture);
      expect(events.length).assertEqual(1);
      expect(events[0]['state'] as string).assertEqual('resumed');
      expect(events[0]['seq'] as number).assertEqual(1);
      expect(Object.keys(events[0]).length).assertEqual(2);
    });
  });

  describe('bindTransport', () => {
    it('bindTransport_sendsResponsesViaTransport', 0, async () => {
      const fixture = new Fixture(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'echo']),
        new Set<string>(['echo']),
        new FilePageContextProvider('file://')
      );
      fixture.bridge.registerHandler('echo', (payload: Object | null): BridgeHandlerResult => {
        return BridgeHandlerResult.success(payload);
      });
      fixture.bridge.resetForNewPage();
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
      expect(core.sendFailureCount()).assertEqual(1);
    });
  });
}

class Fixture {
  bridge: JsBridge;
  readonly transport: FakeBridgeTransport = new FakeBridgeTransport();

  constructor(
    allowedOrigins: Set<string> = new Set<string>(['file://']),
    methodWhitelist: Set<string> = new Set<string>(['bridge.handshake', 'echo']),
    defaultCapabilities: Set<string> = new Set<string>(['echo']),
    pageContextProvider?: PageContextProvider
  ) {
    this.bridge = new JsBridge({
      allowedOrigins,
      methodWhitelist,
      defaultCapabilities,
      transport: this.transport.send.bind(this.transport),
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
  payload: Record<string, Object> = {}
): string {
  return JSON.stringify({
    'id': id,
    'sessionId': sessionId,
    'kind': 'request',
    'method': method,
    'ts': 1,
    'timeoutMs': 1000,
    'keep': false,
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
