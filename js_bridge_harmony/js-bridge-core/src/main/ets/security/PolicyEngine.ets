import { BridgeError } from '../api/BridgeError';
import { BridgeApiContract } from '../api/BridgeApiContract';
import { BridgeMessage, BridgeMessageKind } from '../api/BridgeMessage';
import { TrustedPageContext } from '../api/TrustedPageContext';
import { SessionRecord } from './SessionRecord';

export class PolicyInput {
  message: BridgeMessage;
  context: TrustedPageContext;
  ready: boolean;
  sessionRecord: SessionRecord | null;

  constructor(
    message: BridgeMessage,
    context: TrustedPageContext,
    ready: boolean,
    sessionRecord: SessionRecord | null
  ) {
    this.message = message;
    this.context = context;
    this.ready = ready;
    this.sessionRecord = sessionRecord;
  }
}

export interface PolicyRule {
  evaluate(input: PolicyInput): BridgeError | null;
}

/// 策略决策：extraPolicies 可显式返回，表达"拒绝"这一决策本身。
/// deny 可不携带 error——缺 error 时由框架以 E_POLICY_DENY 兜底，
/// 禁止静默放行到 dispatch（docs/03 §9 细则 3，验收锚点 C53）。
/// 与 Android PolicyDecision / iOS PolicyDecision 的语义对齐。
export class PolicyDecision {
  readonly allowed: boolean;
  readonly error: BridgeError | null;

  private constructor(allowed: boolean, error: BridgeError | null) {
    this.allowed = allowed;
    this.error = error;
  }

  static deny(error: BridgeError | null): PolicyDecision {
    return new PolicyDecision(false, error);
  }
}

export class PolicyEngine {
  private readonly rules: PolicyRule[];

  constructor(rules: PolicyRule[]) {
    this.rules = rules.slice();
  }

  evaluate(input: PolicyInput): BridgeError | null {
    for (const rule of this.rules) {
      const err = rule.evaluate(input);
      if (err !== null) {
        return err;
      }
    }
    return null;
  }
}

export class RequestShapePolicy implements PolicyRule {
  evaluate(input: PolicyInput): BridgeError | null {
    if (input.message.kind !== BridgeMessageKind.REQUEST || input.message.method.length === 0) {
      return new BridgeError(BridgeApiContract.ERR_INVALID_MESSAGE, 'only non-empty request messages are accepted');
    }
    return null;
  }
}

export class HandshakeGatePolicy implements PolicyRule {
  evaluate(input: PolicyInput): BridgeError | null {
    if (!input.ready && input.message.method !== BridgeApiContract.METHOD_HANDSHAKE) {
      return new BridgeError(BridgeApiContract.ERR_NOT_READY, 'bridge session not ready');
    }
    return null;
  }
}

export class OriginPolicy implements PolicyRule {
  private allowedOrigins: Set<string>;

  constructor(allowedOrigins: Set<string>) {
    this.allowedOrigins = allowedOrigins;
  }

  evaluate(input: PolicyInput): BridgeError | null {
    if (!this.allowedOrigins.has(input.context.origin)) {
      return new BridgeError(BridgeApiContract.ERR_ORIGIN_DENY, 'origin denied');
    }
    return null;
  }
}

export class MethodGatePolicy implements PolicyRule {
  private methodWhitelist: Set<string>;

  constructor(methodWhitelist: Set<string>) {
    this.methodWhitelist = methodWhitelist;
  }

  evaluate(input: PolicyInput): BridgeError | null {
    if (!this.methodWhitelist.has(input.message.method)) {
      return new BridgeError(BridgeApiContract.ERR_METHOD_NOT_ALLOWED, 'method not allowed');
    }
    return null;
  }
}

export class SessionPolicy implements PolicyRule {
  evaluate(input: PolicyInput): BridgeError | null {
    if (input.message.method === BridgeApiContract.METHOD_HANDSHAKE) {
      return null;
    }
    if (input.sessionRecord === null) {
      return new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, 'session not found');
    }
    if (input.sessionRecord.context.origin !== input.context.origin) {
      return new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, 'session origin mismatch');
    }
    if (input.sessionRecord.context.pageInstanceId !== input.context.pageInstanceId) {
      return new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, 'session page mismatch');
    }
    return null;
  }
}
