import { SessionRecord } from './SessionRecord';
import { TrustedPageContext } from '../api/TrustedPageContext';

export class SessionService {
  private readonly records: Map<string, SessionRecord> = new Map<string, SessionRecord>();

  issue(context: TrustedPageContext, capabilities: Set<string>, ttlMs: number): SessionRecord {
    const nowMs = Date.now();
    const record = new SessionRecord(
      `${nowMs}-${Math.floor(Math.random() * 0xffffffff).toString(16)}`,
      context,
      new Set<string>(capabilities),
      nowMs + ttlMs
    );
    this.records.set(record.sessionId, record);
    return record;
  }

  find(sessionId: string): SessionRecord | null {
    const record = this.records.get(sessionId);
    if (record === undefined) {
      return null;
    }
    if (record.isExpired(Date.now())) {
      this.records.delete(sessionId);
      return null;
    }
    return record;
  }

  clearByPageInstance(pageInstanceId: string): void {
    const keysToRemove: string[] = [];
    this.records.forEach((record: SessionRecord, key: string) => {
      if (record.context.pageInstanceId === pageInstanceId) {
        keysToRemove.push(key);
      }
    });
    keysToRemove.forEach((key: string) => this.records.delete(key));
  }

  clearAll(): void {
    this.records.clear();
  }
}
