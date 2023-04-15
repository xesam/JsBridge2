import { TrustedPageContext } from '../api/TrustedPageContext';

export class SessionRecord {
  readonly sessionId: string;
  readonly context: TrustedPageContext;
  readonly capabilities: Set<string>;
  readonly expiresAtMs: number;

  constructor(
    sessionId: string,
    context: TrustedPageContext,
    capabilities: Set<string>,
    expiresAtMs: number
  ) {
    this.sessionId = sessionId;
    this.context = context;
    this.capabilities = capabilities;
    this.expiresAtMs = expiresAtMs;
  }

  isExpired(nowMs: number): boolean {
    return this.expiresAtMs <= nowMs;
  }
}
