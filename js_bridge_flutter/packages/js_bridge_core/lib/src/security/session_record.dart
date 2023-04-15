import '../api/trusted_page_context.dart';

class SessionRecord {
  SessionRecord({
    required this.sessionId,
    required this.context,
    required this.capabilities,
    required this.expiresAtMs,
  });

  final String sessionId;
  final TrustedPageContext context;
  final Set<String> capabilities;
  final int expiresAtMs;

  bool isExpired(int nowMs) => expiresAtMs <= nowMs;
}
