import { describe, it, expect } from '@ohos/hypium';
import {
  BridgeError,
  BridgeMessage,
  BridgeMessageKind,
  PolicyInput,
  PolicyEngine,
  RequestShapePolicy,
  HandshakeGatePolicy,
  OriginPolicy,
  MethodGatePolicy,
  SessionPolicy,
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

      expect(decision !== null).assertTrue();
      expect(decision!.code).assertEqual('E_INVALID_MESSAGE');
    });

    it('requestShape_rejectsEmptyMethod', 0, () => {
      const msg = new BridgeMessage('r1', '', BridgeMessageKind.REQUEST, '', Date.now(), 0, false, null);
      const decision = new RequestShapePolicy().evaluate(new PolicyInput(
        msg,
        context('file://'),
        false,
        null
      ));

      expect(decision !== null).assertTrue();
      expect(decision!.code).assertEqual('E_INVALID_MESSAGE');
    });

    it('handshakeGate_rejectsCallBeforeHandshake', 0, () => {
      const decision = new HandshakeGatePolicy().evaluate(new PolicyInput(
        requestMessage('getUser', 's1'),
        context('file://'),
        false,
        null
      ));

      expect(decision !== null).assertTrue();
      expect(decision!.code).assertEqual('E_NOT_READY'); // v1: 握手门禁从 E_POLICY_DENY 分立
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

    it('originPolicy_rejectsUnknownOrigin', 0, () => {
      const policy = new OriginPolicy(
        new Set<string>(['https://trusted.example'])
      );

      const decision = policy.evaluate(new PolicyInput(
        requestMessage('getUser', 's1'),
        context('file://'),
        true,
        null
      ));

      expect(decision !== null).assertTrue();
      expect(decision!.code).assertEqual('E_ORIGIN_DENY');
    });

    it('methodGatePolicy_rejectsUnknownMethod', 0, () => {
      const policy = new MethodGatePolicy(
        new Set<string>(['bridge.handshake', 'getUser'])
      );

      const decision = policy.evaluate(new PolicyInput(
        requestMessage('timerLog', 's1'),
        context('file://'),
        true,
        null
      ));

      expect(decision !== null).assertTrue();
      expect(decision!.code).assertEqual('E_METHOD_NOT_ALLOWED');
    });

    it('sessionPolicy_rejectsSessionMismatch', 0, () => {
      const policy = new SessionPolicy();

      const session = new SessionRecord(
        's1',
        new TrustedPageContext('file://', 'page-a'),
        Date.now() + 60000
      );

      const decision = policy.evaluate(new PolicyInput(
        requestMessage('getUser', 's1'),
        new TrustedPageContext('file://', 'page-b'),
        true,
        session
      ));

      expect(decision !== null).assertTrue();
      expect(decision!.code).assertEqual('E_SESSION_INVALID');
    });

    it('sessionPolicy_allowsValidRequest', 0, () => {
      const policy = new SessionPolicy();

      const session = new SessionRecord(
        's1',
        new TrustedPageContext('file://', 'page-a'),
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

    // ===== C45: 策略链固定求值顺序与短路行为 =====

    it('C45_policyChain_evaluatesInFixedOrder_requestShapeFirst', 0, () => {
      const engine = new PolicyEngine([new RequestShapePolicy()]);

      const decision = engine.evaluate(new PolicyInput(
        eventMessage('timerLog'), // kind=EVENT，不是 request
        context('file://'),
        false,
        null
      ));

      expect(decision !== null).assertTrue();
      expect(decision!.code).assertEqual('E_INVALID_MESSAGE');
    });

    it('C45_policyChain_shortCircuitsOnFirstDenial', 0, () => {
      // 链：RequestShape -> HandshakeGate -> Origin
      // 预期：HandshakeGate 拒绝后短路，Origin 不执行
      const engine = new PolicyEngine([
        new RequestShapePolicy(),
        new HandshakeGatePolicy(),
        new OriginPolicy(new Set<string>(['https://trusted.example']))
      ]);

      const decision = engine.evaluate(new PolicyInput(
        requestMessage('getUser', 's1'),
        context('file://'), // origin 不在白名单，但不应走到 OriginPolicy
        false, // 未 ready -> HandshakeGate 拒绝
        null
      ));

      expect(decision !== null).assertTrue();
      // 短路在 HandshakeGate，错误码是 E_NOT_READY 而非 E_ORIGIN_DENY
      expect(decision!.code).assertEqual('E_NOT_READY');
    });

    it('C45_policyChain_continuesWhenAllAllow', 0, () => {
      const engine = new PolicyEngine([new RequestShapePolicy()]);

      const decision = engine.evaluate(new PolicyInput(
        requestMessage('bridge.handshake', ''),
        context('file://'),
        false,
        null
      ));

      expect(decision).assertNull();
    });

    it('C45_policyChain_stopsAtFirstDenialInVariableLengthChain', 0, () => {
      // 链长 3，第 2 个策略（Origin）拒绝 -> MethodGate 不执行
      const engine = new PolicyEngine([
        new RequestShapePolicy(),
        new OriginPolicy(new Set<string>(['https://trusted.example'])),
        new MethodGatePolicy(new Set<string>(['bridge.handshake']))
      ]);

      const decision = engine.evaluate(new PolicyInput(
        requestMessage('notAllowed', 's1'),
        context('file://'),
        true,
        null
      ));

      expect(decision !== null).assertTrue();
      expect(decision!.code).assertEqual('E_ORIGIN_DENY');
    });

    // ===== C46: 安全级别切换 - 不同配置下的策略链组成 =====

    it('C46_nullConfig_onlyRequestShapePolicy', 0, () => {
      // 无配置（securityConfig == null）：仅 RequestShapePolicy
      const engine = new PolicyEngine([new RequestShapePolicy()]);

      // 非 request 拒绝
      const invalid = engine.evaluate(new PolicyInput(
        eventMessage('timerLog'),
        context('file://'),
        false,
        null
      ));
      expect(invalid !== null).assertTrue();
      expect(invalid!.code).assertEqual('E_INVALID_MESSAGE');

      // 合法 request 通过（链上没有其他策略）
      const valid = engine.evaluate(new PolicyInput(
        requestMessage('getUser', ''),
        context('file://'),
        false,
        null
      ));
      expect(valid).assertNull();
    });

    it('C46_wildcardConfig_requiresHandshakeButNoOriginMethodCheck', 0, () => {
      // 有配置但两个维度为 {"*"}：RequestShape + HandshakeGate + Session
      const engine = new PolicyEngine([
        new RequestShapePolicy(),
        new HandshakeGatePolicy(),
        new SessionPolicy()
      ]);

      // 未 ready -> HandshakeGate 拒绝
      const beforeHandshake = engine.evaluate(new PolicyInput(
        requestMessage('anyMethod', 's1'),
        context('file://'),
        false,
        null
      ));
      expect(beforeHandshake !== null).assertTrue();
      expect(beforeHandshake!.code).assertEqual('E_NOT_READY');

      // ready 但无 session -> SessionPolicy 拒绝
      const noSession = engine.evaluate(new PolicyInput(
        requestMessage('anyMethod', 's1'),
        context('file://'),
        true,
        null
      ));
      expect(noSession !== null).assertTrue();
      expect(noSession!.code).assertEqual('E_SESSION_INVALID');
    });

    it('C46_fullConfig_fullPolicyChainWithOriginAndMethodCheck', 0, () => {
      // 完整配置：完整链
      const engine = new PolicyEngine([
        new RequestShapePolicy(),
        new HandshakeGatePolicy(),
        new OriginPolicy(new Set<string>(['https://trusted.example'])),
        new MethodGatePolicy(new Set<string>(['bridge.handshake', 'getUser'])),
        new SessionPolicy()
      ]);

      const validSession = new SessionRecord(
        's1',
        new TrustedPageContext('https://trusted.example', 'page-a'),
        Date.now() + 60000
      );

      // origin 不在白名单 -> E_ORIGIN_DENY
      const badOrigin = engine.evaluate(new PolicyInput(
        requestMessage('getUser', 's1'),
        new TrustedPageContext('https://untrusted.com', 'page-a'),
        true,
        validSession
      ));
      expect(badOrigin !== null).assertTrue();
      expect(badOrigin!.code).assertEqual('E_ORIGIN_DENY');

      // method 不在白名单 -> E_METHOD_NOT_ALLOWED
      const badMethod = engine.evaluate(new PolicyInput(
        requestMessage('deleteUser', 's1'),
        new TrustedPageContext('https://trusted.example', 'page-a'),
        true,
        validSession
      ));
      expect(badMethod !== null).assertTrue();
      expect(badMethod!.code).assertEqual('E_METHOD_NOT_ALLOWED');

      // 全部满足 -> 通过
      const ok = engine.evaluate(new PolicyInput(
        requestMessage('getUser', 's1'),
        new TrustedPageContext('https://trusted.example', 'page-a'),
        true,
        validSession
      ));
      expect(ok).assertNull();
    });
  });
}

function requestMessage(method: string, sessionId: string): BridgeMessage {
  return new BridgeMessage('r1', sessionId, BridgeMessageKind.REQUEST, method, Date.now(), 0, false, null);
}

function eventMessage(method: string): BridgeMessage {
  return new BridgeMessage('e1', '', BridgeMessageKind.EVENT, method, Date.now(), 0, false, null);
}

function context(origin: string): TrustedPageContext {
  return new TrustedPageContext(origin, 'page-a');
}
