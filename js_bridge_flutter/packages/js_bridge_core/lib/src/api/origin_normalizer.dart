/// `TrustedPageContext.origin` 的唯一合法形态归一化（docs/03 §9 细则 5，验收锚点 C54）。
///
/// 四端共用同一规则，宿主 PageContextProvider 必须经由此函数从 WebView URL 派生 origin；
/// OriginPolicy 比较的是归一化后的字符串。全量校验向量见
/// `docs/origin-normalizer-vectors.json`。
///
/// 刻意**不使用 `dart:core` 的 `Uri` 解析**：`uri.host` 会剥掉 IPv6 字面量方括号、
/// 未知 scheme 无端口时 `uri.port` 返回 0、`hasAuthority` 对非层级形态的口径与其他端
/// 不一致——四端共用同一套手写字符串算法以消除解析器人格差异。
class OriginNormalizer {
  OriginNormalizer._();

  /// 归一化 WebView URL 为 origin 字符串。
  ///
  /// 输入为 null / 空串 / scheme 词法非法 / 非层级形态 / 端口段非法时返回空串 `""`
  /// （空串 origin 永远不会命中任何白名单，fail-closed）。
  static String normalize(String? rawUrl) {
    if (rawUrl == null) {
      return '';
    }
    final url = rawUrl.trim();
    if (url.isEmpty) {
      return '';
    }
    final colonIndex = url.indexOf(':');
    if (colonIndex <= 0 || !_isValidScheme(url.substring(0, colonIndex))) {
      return '';
    }
    final scheme = url.substring(0, colonIndex).toLowerCase();
    final rest = url.substring(colonIndex + 1);

    // 本地内容协议保留 scheme 语义（任意 file URL 一律归一化为 'file://'）
    if (scheme == 'file') {
      return 'file://';
    }
    // 非层级形态（about: / data: / mailto: 等无 // 形态）→ 空串 fail-closed
    if (!rest.startsWith('//')) {
      return '';
    }
    final authority = _authorityOf(rest.substring(2));
    if (authority.isEmpty) {
      // 空 authority（content:// / asset:// / flutter-asset:///… 等无 host 形态）
      // → 保留 scheme 语义，是否放行由宿主白名单决定
      return '$scheme://';
    }
    // 端口分隔冒号须在最后一个 ']' 之后（IPv6 字面量内部冒号不作端口分隔）
    final bracketEnd = authority.lastIndexOf(']');
    final portColon = authority.lastIndexOf(':');
    String host;
    String? portText;
    if (portColon >= 0 && (bracketEnd < 0 || portColon > bracketEnd)) {
      host = authority.substring(0, portColon);
      portText = authority.substring(portColon + 1);
    } else {
      host = authority;
    }
    if (host.isEmpty) {
      return '';
    }
    final hostLower = host.toLowerCase();
    if (portText == null) {
      return '$scheme://$hostLower';
    }
    if (!_isDigits(portText)) {
      // 端口段非法（非纯数字 / 超长）→ 无法给出可信 origin，空串 fail-closed
      return '';
    }
    final port = int.parse(portText);
    if (port <= 0 || port > 65535) {
      // 端口值非法（0 / 超 TCP 上限）→ 空串 fail-closed，畸形端口不得回退成可命中的 origin
      return '';
    }
    final isDefaultPort = (scheme == 'https' && port == 443) || (scheme == 'http' && port == 80);
    if (isDefaultPort) {
      return '$scheme://$hostLower';
    }
    return '$scheme://$hostLower:$port';
  }

  /// authority 段：首个 '/'、'?'、'#' 之前；剥离 userinfo（最后一个 '@' 之前）。
  static String _authorityOf(String rest) {
    var end = rest.length;
    for (var i = 0; i < rest.length; i++) {
      final c = rest[i];
      if (c == '/' || c == '?' || c == '#') {
        end = i;
        break;
      }
    }
    var authority = rest.substring(0, end);
    final at = authority.lastIndexOf('@');
    if (at >= 0) {
      authority = authority.substring(at + 1);
    }
    return authority;
  }

  /// RFC 3986 scheme 词法的 ASCII 子集（四端统一）：
  /// 首字符 ASCII 字母，其余为 ASCII 字母/数字/+/-/.。
  static bool _isValidScheme(String raw) {
    if (raw.isEmpty || !_isAsciiLetter(raw[0])) {
      return false;
    }
    for (var i = 1; i < raw.length; i++) {
      final c = raw[i];
      if (!_isAsciiLetter(c) && !_isAsciiDigit(c) && c != '+' && c != '-' && c != '.') {
        return false;
      }
    }
    return true;
  }

  static bool _isDigits(String raw) {
    if (raw.isEmpty || raw.length > 5) {
      return false;
    }
    for (var i = 0; i < raw.length; i++) {
      if (!_isAsciiDigit(raw[i])) {
        return false;
      }
    }
    return true;
  }

  static bool _isAsciiLetter(String c) =>
      (c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
      (c.compareTo('A') >= 0 && c.compareTo('Z') <= 0);

  static bool _isAsciiDigit(String c) => c.compareTo('0') >= 0 && c.compareTo('9') <= 0;
}
