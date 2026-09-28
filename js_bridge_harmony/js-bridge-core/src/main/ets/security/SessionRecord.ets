import { TrustedPageContext } from '../api/TrustedPageContext';

export class SessionRecord {
  readonly sessionId: string;
  readonly context: TrustedPageContext;
  readonly expiresAtMs: number;

  constructor(
    sessionId: string,
    context: TrustedPageContext,
    expiresAtMs: number
  ) {
    this.sessionId = sessionId;
    this.context = context;
    this.expiresAtMs = expiresAtMs;
  }

  isExpired(nowMs: number): boolean {
    // expiresAtMs == -1 为"永不过期"哨兵（docs/03 §10：ttlMs == 0 永不失效，C60）
    return this.expiresAtMs > 0 && this.expiresAtMs <= nowMs;
  }
}
