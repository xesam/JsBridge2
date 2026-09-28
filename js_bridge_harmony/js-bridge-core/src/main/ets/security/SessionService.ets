import { SessionRecord } from './SessionRecord';
import { TrustedPageContext } from '../api/TrustedPageContext';

export class SessionService {
  private readonly records: Map<string, SessionRecord> = new Map<string, SessionRecord>();

  issue(context: TrustedPageContext, ttlMs: number): SessionRecord {
    const nowMs = Date.now();
    // 签发时顺带清扫过期记录（docs/03 §10 / C56）：
    // 过期而不再被查询的条目在此移除，握手高频场景下存储不随过期条目无界增长；
    // 同时移除同 pageInstanceId 的既有记录——重复握手刷新而非并存（C61）
    const outdatedIds: string[] = [];
    this.records.forEach((record: SessionRecord, key: string) => {
      const pageRefreshed: boolean = record.context.pageInstanceId === context.pageInstanceId;
      if (record.isExpired(nowMs) || pageRefreshed) {
        outdatedIds.push(key);
      }
    });
    outdatedIds.forEach((key: string) => {
      this.records.delete(key);
    });
    const record = new SessionRecord(
      `${nowMs}-${Math.floor(Math.random() * 0xffffffff).toString(16)}`,
      context,
      // docs/03 §10 三态（C60）：ttl > 0 有限期；ttl == 0 永不过期（-1 哨兵）；ttl < 0 测试驱动用立即过期
      ttlMs > 0 ? nowMs + ttlMs : (ttlMs === 0 ? -1 : nowMs)
    );
    this.records.set(record.sessionId, record);
    return record;
  }

  /// 测试可观测：当前存储的 session 条目数。
  /// 验收 C56 用以区分"签发时顺带清扫"与 find() 的惰性删除。
  recordCount(): number {
    return this.records.size;
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
