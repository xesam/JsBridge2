import { BridgeError } from './BridgeError';

export enum BridgeMessageKind {
  REQUEST = 'request',
  RESPONSE = 'response',
  EVENT = 'event'
}

export class BridgeMessage {
  readonly id: string;
  readonly sessionId: string;
  readonly kind: BridgeMessageKind;
  readonly method: string;
  readonly ts: number;
  readonly timeoutMs: number;
  readonly keep: boolean;
  readonly payload: Object | null;
  readonly reqId: string | null;
  readonly done: boolean | null;
  readonly ok: boolean | null;
  readonly error: BridgeError | null;
  readonly scopeId: string | null;

  constructor(
    id: string,
    sessionId: string,
    kind: BridgeMessageKind,
    method: string,
    ts: number,
    timeoutMs: number = 0,
    keep: boolean = false,
    payload: Object | null = null,
    reqId: string | null = null,
    done: boolean | null = null,
    ok: boolean | null = null,
    error: BridgeError | null = null,
    scopeId: string | null = null
  ) {
    this.id = id;
    this.sessionId = sessionId;
    this.kind = kind;
    this.method = method;
    this.ts = ts;
    this.timeoutMs = timeoutMs;
    this.keep = keep;
    this.payload = payload;
    this.reqId = reqId;
    this.done = done;
    this.ok = ok;
    this.error = error;
    this.scopeId = scopeId;
  }

  static fromJsonString(raw: string): BridgeMessage {
    const json = JSON.parse(raw) as Record<string, Object>;
    return new BridgeMessage(
      requiredString(json['id'], 'id'),
      optionalSessionId(json['sessionId']),
      parseKindStrict(json['kind']),
      requiredString(json['method'], 'method'),
      numberValue(json['ts']),
      numberValue(json['timeoutMs']),
      json['keep'] === true,
      objectOrNull(json['payload']),
      nullableString(json['reqId']),
      nullableBoolean(json['done']),
      nullableBoolean(json['ok']),
      parseError(json['error']),
      nullableString(json['scopeId'])
    );
  }

  toJsonString(): string {
    return JSON.stringify(this.toJson());
  }

  toJson(): Record<string, Object | null> {
    return {
      'id': this.id,
      'sessionId': this.sessionId,
      'kind': this.kind,
      'method': this.method,
      'ts': this.ts,
      'timeoutMs': this.timeoutMs,
      'keep': this.keep,
      'payload': this.payload,
      'reqId': this.reqId,
      'done': this.done,
      'ok': this.ok,
      'error': this.error === null ? null : this.error.toJson(),
      'scopeId': this.scopeId
    };
  }
}

function parseKindStrict(raw: Object | undefined): BridgeMessageKind {
  if (raw === 'request') {
    return BridgeMessageKind.REQUEST;
  }
  if (raw === 'response') {
    return BridgeMessageKind.RESPONSE;
  }
  if (raw === 'event') {
    return BridgeMessageKind.EVENT;
  }
  throw new Error(`BridgeMessage: invalid kind: ${raw}`);
}

function requiredString(raw: Object | undefined, field: string): string {
  if (typeof raw !== 'string') {
    throw new Error(`BridgeMessage: field ${field} must be a string`);
  }
  return raw;
}

function optionalSessionId(raw: Object | undefined): string {
  if (raw === undefined) {
    return '';
  }
  if (typeof raw !== 'string') {
    throw new Error('BridgeMessage: field sessionId must be a string');
  }
  return raw;
}

function parseError(raw: Object | undefined): BridgeError | null {
  if (raw === undefined || raw === null || typeof raw !== 'object') {
    return null;
  }
  const json = raw as Record<string, Object>;
  return new BridgeError(
    stringValue(json['code'], 'E_INTERNAL'),
    stringValue(json['message'], 'unknown error'),
    json['retryable'] === true,
    objectRecord(json['details'])
  );
}

function stringValue(raw: Object | undefined, fallback: string = ''): string {
  return typeof raw === 'string' ? raw : fallback;
}

function nullableString(raw: Object | undefined): string | null {
  return typeof raw === 'string' ? raw : null;
}

function nullableBoolean(raw: Object | undefined): boolean | null {
  return typeof raw === 'boolean' ? raw : null;
}

function numberValue(raw: Object | undefined): number {
  return typeof raw === 'number' ? raw : 0;
}

function objectOrNull(raw: Object | undefined): Object | null {
  if (raw === undefined) {
    return null;
  }
  return raw;
}

function objectRecord(raw: Object | undefined): Record<string, Object> {
  if (raw === undefined || raw === null || typeof raw !== 'object') {
    return {};
  }
  return raw as Record<string, Object>;
}
