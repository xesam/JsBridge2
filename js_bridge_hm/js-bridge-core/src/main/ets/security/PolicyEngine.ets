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
  name: string;
  evaluate(input: PolicyInput): BridgeError | null;
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
  name: string = 'RequestShapePolicy';

  evaluate(input: PolicyInput): BridgeError | null {
    if (input.message.kind !== BridgeMessageKind.REQUEST || input.message.method.length === 0) {
      return new BridgeError(BridgeApiContract.ERR_INVALID_MESSAGE, 'only non-empty request messages are accepted');
    }
    return null;
  }
}

export class HandshakeGatePolicy implements PolicyRule {
  name: string = 'HandshakeGatePolicy';

  evaluate(input: PolicyInput): BridgeError | null {
    if (!input.ready && input.message.method !== BridgeApiContract.METHOD_HANDSHAKE) {
      return new BridgeError(BridgeApiContract.ERR_POLICY_DENY, 'bridge not ready');
    }
    return null;
  }
}

export class AccessControlPolicy implements PolicyRule {
  name: string = 'AccessControlPolicy';
  private allowedOrigins: Set<string>;
  private methodWhitelist: Set<string>;

  constructor(
    allowedOrigins: Set<string>,
    methodWhitelist: Set<string>
  ) {
    this.allowedOrigins = allowedOrigins;
    this.methodWhitelist = methodWhitelist;
  }

  evaluate(input: PolicyInput): BridgeError | null {
    if (!this.allowedOrigins.has('*') && !this.allowedOrigins.has(input.context.origin)) {
      return new BridgeError(BridgeApiContract.ERR_ORIGIN_DENY, 'origin denied');
    }

    if (!this.methodWhitelist.has(input.message.method)) {
      return new BridgeError(BridgeApiContract.ERR_METHOD_NOT_ALLOWED, 'method not allowed');
    }

    if (input.message.method !== BridgeApiContract.METHOD_HANDSHAKE) {
      if (input.sessionRecord === null) {
        return new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, 'session not found');
      }
      if (input.sessionRecord.context.origin !== input.context.origin) {
        return new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, 'session origin mismatch');
      }
      if (input.sessionRecord.context.pageInstanceId !== input.context.pageInstanceId) {
        return new BridgeError(BridgeApiContract.ERR_SESSION_INVALID, 'session page mismatch');
      }
      if (!input.sessionRecord.capabilities.has(input.message.method)) {
        return new BridgeError(BridgeApiContract.ERR_CAPABILITY_DENY, 'capability denied');
      }
    }

    return null;
  }
}
