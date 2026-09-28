import '../api/trusted_page_context.dart';

class SessionRecord {
  SessionRecord({
    required this.sessionId,
    required this.context,
    required this.expiresAtMs,
  });

  final String sessionId;
  final TrustedPageContext context;

  /// 过期时间戳（毫秒）；-1 表示永不过期（docs/03 §10：sessionTtlMs == 0 表示永不过期，C60）。
  final int expiresAtMs;

  bool isExpired(int nowMs) => expiresAtMs >= 0 && expiresAtMs <= nowMs;
}
