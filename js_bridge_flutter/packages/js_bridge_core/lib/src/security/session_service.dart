import 'dart:math';

import 'session_record.dart';
import '../api/trusted_page_context.dart';

class SessionService {
  /// [clock] 默认取系统时间；测试可注入假时钟以越过 TTL（验收锚点 C56）。
  SessionService({int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Map<String, SessionRecord> _records = <String, SessionRecord>{};
  final int Function() _clock;
  final Random _random = Random();

  /// 当前存储的 session 记录数（含已过期未清扫条目；issue 时全表清扫，find 时仅惰性移除被命中的单条过期记录）。仅供测试与可观测性使用。
  int get sessionCount => _records.length;

  SessionRecord issue({
    required TrustedPageContext context,
    required int ttlMs,
  }) {
    final int nowMs = _clock();
    // 过期清扫（docs/03 §10，验收锚点 C56）：签发时顺带清除全表已过期记录，
    // 防止长期运行进程中不再被查询的过期条目无界累积。
    _sweepExpired(nowMs);
    // 刷新语义（docs/03 §10，验收锚点 C61）：同 pageInstanceId 既有 session 立即失效
    //（重复握手刷新而非并存），异常页面循环握手不会造成同页 session 无界累积
    _records.removeWhere(
      (String key, SessionRecord record) =>
          record.context.pageInstanceId == context.pageInstanceId,
    );
    // docs/03 §10 三态（C60）：ttl > 0 有限期；ttl == 0 永不过期（-1 哨兵）；ttl < 0 测试驱动用立即过期
    final SessionRecord record = SessionRecord(
      sessionId: _nextSessionId(nowMs),
      context: context,
      expiresAtMs: ttlMs > 0 ? nowMs + ttlMs : (ttlMs == 0 ? -1 : nowMs),
    );
    _records[record.sessionId] = record;
    return record;
  }

  SessionRecord? find(String sessionId) {
    final SessionRecord? record = _records[sessionId];
    if (record == null) {
      return null;
    }
    if (record.isExpired(_clock())) {
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

  void _sweepExpired(int nowMs) {
    _records.removeWhere((_, SessionRecord record) => record.isExpired(nowMs));
  }

  String _nextSessionId(int nowMs) {
    return '$nowMs-${_random.nextInt(1 << 32).toRadixString(16)}';
  }
}
