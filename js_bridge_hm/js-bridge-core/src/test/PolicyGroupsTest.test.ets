import { describe, it, expect } from '@ohos/hypium';
import {
  BridgeError,
  BridgeMessage,
  BridgeMessageKind,
  PolicyInput,
  RequestShapePolicy,
  HandshakeGatePolicy,
  AccessControlPolicy,
  SessionRecord,
  TrustedPageContext
} from '../../Index';

export default function policyGroupsTest(): void {
  describe('PolicyGroupsTest', () => {
    it('requestShape_rejectsNonRequest', 0, () => {
      const decision = new RequestShapePolicy().evaluate(new PolicyInput(
        eventMessage('timerLog'),
        context('file://'),
        false,
        null
      ));

      expect(decision).assertNotNull();
      expect(decision!.code).assertEqual('E_INVALID_MESSAGE');
    });

    it('requestShape_rejectsEmptyMethod', 0, () => {
      const msg = new BridgeMessage('r1', '', BridgeMessageKind.REQUEST, '', Date.now(), 0, false, {});
      const decision = new RequestShapePolicy().evaluate(new PolicyInput(
        msg,
        context('file://'),
        false,
        null
      ));

      expect(decision).assertNotNull();
      expect(decision!.code).assertEqual('E_INVALID_MESSAGE');
    });

    it('handshakeGate_rejectsCallBeforeHandshake', 0, () => {
      const decision = new HandshakeGatePolicy().evaluate(new PolicyInput(
        requestMessage('getUser', 's1'),
        context('file://'),
        false,
        null
      ));

      expect(decision).assertNotNull();
      expect(decision!.code).assertEqual('E_POLICY_DENY');
    });

    it('handshakeGate_allowsHandshakeEvenWhenNotReady', 0, () => {
      const decision = new HandshakeGatePolicy().evaluate(new PolicyInput(
        requestMessage('bridge.handshake', ''),
        context('file://'),
        false,
        null
      ));

      expect(decision).assertNull();
    });

    it('accessControl_rejectsOriginAndMethod', 0, () => {
      const policy = new AccessControlPolicy(
        new Set<string>(['https://trusted.example']),
        new Set<string>(['bridge.handshake', 'getUser'])
      );

      const decision = policy.evaluate(new PolicyInput(
        requestMessage('timerLog', 's1'),
        context('file://'),
        true,
        null
      ));

      expect(decision).assertNotNull();
      expect(decision!.code).assertEqual('E_ORIGIN_DENY');
    });

    it('accessControl_rejectsSessionMismatch', 0, () => {
      const policy = new AccessControlPolicy(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'getUser'])
      );

      const session = new SessionRecord(
        's1',
        new TrustedPageContext('file://', 'page-a'),
        new Set<string>(['getUser']),
        Date.now() + 60000
      );

      const decision = policy.evaluate(new PolicyInput(
        requestMessage('getUser', 's1'),
        new TrustedPageContext('file://', 'page-b'),
        true,
        session
      ));

      expect(decision).assertNotNull();
      expect(decision!.code).assertEqual('E_SESSION_INVALID');
    });

    it('accessControl_rejectsCapabilityDenied', 0, () => {
      const policy = new AccessControlPolicy(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'timerLog'])
      );

      const session = new SessionRecord(
        's1',
        new TrustedPageContext('file://', 'page-a'),
        new Set<string>(['getUser']),
        Date.now() + 60000
      );

      const decision = policy.evaluate(new PolicyInput(
        requestMessage('timerLog', 's1'),
        new TrustedPageContext('file://', 'page-a'),
        true,
        session
      ));

      expect(decision).assertNotNull();
      expect(decision!.code).assertEqual('E_CAPABILITY_DENY');
    });

    it('accessControl_allowsValidRequest', 0, () => {
      const policy = new AccessControlPolicy(
        new Set<string>(['file://']),
        new Set<string>(['bridge.handshake', 'getUser'])
      );

      const session = new SessionRecord(
        's1',
        new TrustedPageContext('file://', 'page-a'),
        new Set<string>(['getUser']),
        Date.now() + 60000
      );

      const decision = policy.evaluate(new PolicyInput(
        requestMessage('getUser', 's1'),
        new TrustedPageContext('file://', 'page-a'),
        true,
        session
      ));

      expect(decision).assertNull();
    });
  });
}

function requestMessage(method: string, sessionId: string): BridgeMessage {
  return new BridgeMessage('r1', sessionId, BridgeMessageKind.REQUEST, method, Date.now(), 0, false, {});
}

function eventMessage(method: string): BridgeMessage {
  return new BridgeMessage('e1', '', BridgeMessageKind.EVENT, method, Date.now(), 0, false, {});
}

function context(origin: string): TrustedPageContext {
  return new TrustedPageContext(origin, 'page-a');
}
