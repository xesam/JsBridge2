import 'dart:math';

import 'session_record.dart';
import '../api/trusted_page_context.dart';

class SessionService {
  final Map<String, SessionRecord> _records = <String, SessionRecord>{};
  final Random _random = Random();

  SessionRecord issue({
    required TrustedPageContext context,
    required Set<String> capabilities,
    required int ttlMs,
  }) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final record = SessionRecord(
      sessionId: _nextSessionId(nowMs),
      context: context,
      capabilities: Set<String>.from(capabilities),
      expiresAtMs: nowMs + ttlMs,
    );
    _records[record.sessionId] = record;
    return record;
  }

  SessionRecord? find(String sessionId) {
    final record = _records[sessionId];
    if (record == null) {
      return null;
    }
    if (record.isExpired(DateTime.now().millisecondsSinceEpoch)) {
      _records.remove(sessionId);
      return null;
    }
    return record;
  }

  void clearByPageInstance(String pageInstanceId) {
    _records.removeWhere(
      (_, SessionRecord value) => value.context.pageInstanceId == pageInstanceId,
    );
  }

  void clearAll() {
    _records.clear();
  }

  String _nextSessionId(int nowMs) {
    return '$nowMs-${_random.nextInt(1 << 32).toRadixString(16)}';
  }
}
