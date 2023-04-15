import { describe, it, expect } from '@ohos/hypium';
import { SessionService, SessionRecord, TrustedPageContext } from '../../Index';

export default function sessionServiceTest(): void {
  describe('SessionServiceTest', () => {
    it('issue_createsRecordWithCapabilities', 0, () => {
      const service = new SessionService();
      const ctx = new TrustedPageContext('file://', 'page-1');
      const record = service.issue(ctx, new Set<string>(['a', 'b']), 60000);

      expect(record.sessionId.length > 0).assertTrue();
      expect(record.capabilities.has('a')).assertTrue();
      expect(record.capabilities.has('b')).assertTrue();
    });

    it('find_returnsNullForUnknown', 0, () => {
      const service = new SessionService();
      expect(service.find('nonexistent')).assertNull();
    });

    it('find_returnsRecordForValidSession', 0, () => {
      const service = new SessionService();
      const ctx = new TrustedPageContext('file://', 'page-1');
      const record = service.issue(ctx, new Set<string>(['x']), 60000);

      const found = service.find(record.sessionId);
      expect(found).assertNotNull();
      expect(found!.sessionId).assertEqual(record.sessionId);
    });

    it('find_returnsNullForExpiredSession', 0, () => {
      const service = new SessionService();
      const ctx = new TrustedPageContext('file://', 'page-1');
      const record = service.issue(ctx, new Set<string>(['x']), -1);

      const found = service.find(record.sessionId);
      expect(found).assertNull();
    });

    it('clearByPageInstance_removesMatchingSessions', 0, () => {
      const service = new SessionService();
      const ctxA = new TrustedPageContext('file://', 'page-a');
      const ctxB = new TrustedPageContext('file://', 'page-b');
      const recA = service.issue(ctxA, new Set<string>(['x']), 60000);
      const recB = service.issue(ctxB, new Set<string>(['y']), 60000);

      service.clearByPageInstance('page-a');

      expect(service.find(recA.sessionId)).assertNull();
      expect(service.find(recB.sessionId)).assertNotNull();
    });

    it('clearAll_removesAllSessions', 0, () => {
      const service = new SessionService();
      const ctx = new TrustedPageContext('file://', 'page-1');
      const rec1 = service.issue(ctx, new Set<string>(['x']), 60000);
      const rec2 = service.issue(ctx, new Set<string>(['y']), 60000);

      service.clearAll();

      expect(service.find(rec1.sessionId)).assertNull();
      expect(service.find(rec2.sessionId)).assertNull();
    });
  });
}
