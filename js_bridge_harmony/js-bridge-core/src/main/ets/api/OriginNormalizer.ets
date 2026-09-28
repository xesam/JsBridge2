/// origin 序列化归一化（docs/03 §9 细则 5，四端统一规则，验收锚点 C54）。
/// `TrustedPageContext.origin` 的唯一合法形态由本类产生，宿主 provider 必须经它派生 origin，
/// OriginPolicy 比较的也是归一化后的字符串。全量校验向量见
/// `docs/origin-normalizer-vectors.json`。
export class OriginNormalizer {
  /// 归一化 URL 为 origin 串。
  ///
  /// 规则（四端同一套手写字符串算法）：
  /// - `scheme` 与 `host` 小写；host 保留 IPv6 字面量方括号；
  /// - URL 缺失（空串）→ 空串 `""`（不用 "about:blank" 等占位值——
  ///   空串 origin 永远不会命中任何白名单，fail-closed）；
  /// - scheme 词法非法（非 ASCII 字母开头、含非法字符）→ 空串，fail-closed；
  /// - 本地内容协议（`file:`）无论 authority 形态 → `file://`；
  /// - 空 authority 的层级形态（`content://` / `asset://` 等）→ `scheme://`；
  /// - 非层级形态（`about:` / `data:` 等）→ 空串，fail-closed；
  /// - 端口段须为纯数字（至多 5 位）且整数值在 1..65535，否则整体 → 空串 fail-closed；
  ///   默认端口（`https:443` / `http:80`）按整数值省略，非默认端口保留。
  static normalize(url: string): string {
    const trimmed = url.trim();
    if (trimmed.length === 0) {
      return '';
    }
    const colonIndex = trimmed.indexOf(':');
    if (colonIndex <= 0 || !isValidScheme(trimmed.substring(0, colonIndex))) {
      return '';
    }
    const scheme = trimmed.substring(0, colonIndex).toLowerCase();
    const rest = trimmed.substring(colonIndex + 1);

    // 本地内容协议保留 scheme 语义（任意 file URL 一律归一化为 "file://"）
    if (scheme === 'file') {
      return 'file://';
    }
    // 无层级形态（about: / data: 等无 // 形态）→ 空串，fail-closed
    if (!rest.startsWith('//')) {
      return '';
    }
    const authority = authorityOf(rest.substring(2));
    if (authority.length === 0) {
      // 空 authority（content:// / asset:// 等无 host 形态）→ 保留 scheme 语义
      return `${scheme}://`;
    }
    // 端口分隔冒号须在最后一个 ']' 之后（IPv6 字面量内部冒号不作端口分隔）
    const bracketEnd = authority.lastIndexOf(']');
    const portColon = authority.lastIndexOf(':');
    let host: string;
    let portText: string | null = null;
    if (portColon >= 0 && (bracketEnd < 0 || portColon > bracketEnd)) {
      host = authority.substring(0, portColon);
      portText = authority.substring(portColon + 1);
    } else {
      host = authority;
    }
    if (host.length === 0) {
      return '';
    }
    const hostLower = host.toLowerCase();
    if (portText === null) {
      return `${scheme}://${hostLower}`;
    }
    if (!isDigits(portText)) {
      // 端口段非法（非纯数字 / 超长）→ 无法给出可信 origin，空串 fail-closed
      return '';
    }
    const port: number = Number(portText);
    if (port <= 0 || port > 65535) {
      // 端口值非法（0 / 超 TCP 上限）→ 空串 fail-closed，畸形端口不得回退成可命中的 origin
      return '';
    }
    const defaultPortValue = scheme === 'https' ? 443 : (scheme === 'http' ? 80 : -1);
    if (port === defaultPortValue) {
      return `${scheme}://${hostLower}`;
    }
    return `${scheme}://${hostLower}:${port}`;
  }
}

/// authority 段：首个 '/'、'?'、'#' 之前；剥离 userinfo（最后一个 '@' 之前）。
function authorityOf(raw: string): string {
  let end = raw.length;
  for (let i = 0; i < raw.length; i++) {
    const c = raw.charAt(i);
    if (c === '/' || c === '?' || c === '#') {
      end = i;
      break;
    }
  }
  let authority = raw.substring(0, end);
  const at = authority.lastIndexOf('@');
  if (at >= 0) {
    authority = authority.substring(at + 1);
  }
  return authority;
}

/// RFC 3986 scheme 词法的 ASCII 子集（四端统一）：
/// 首字符 ASCII 字母，其余为 ASCII 字母/数字/+/-/.。
function isValidScheme(raw: string): boolean {
  if (raw.length === 0 || !isAsciiLetter(raw.charAt(0))) {
    return false;
  }
  for (let i = 1; i < raw.length; i++) {
    const c = raw.charAt(i);
    if (!isAsciiLetter(c) && !isAsciiDigit(c) && c !== '+' && c !== '-' && c !== '.') {
      return false;
    }
  }
  return true;
}

function isDigits(raw: string): boolean {
  if (raw.length === 0 || raw.length > 5) {
    return false;
  }
  for (let i = 0; i < raw.length; i++) {
    if (!isAsciiDigit(raw.charAt(i))) {
      return false;
    }
  }
  return true;
}

function isAsciiLetter(c: string): boolean {
  const code = c.charCodeAt(0);
  return (code >= 97 && code <= 122) || (code >= 65 && code <= 90);
}

function isAsciiDigit(c: string): boolean {
  const code = c.charCodeAt(0);
  return code >= 48 && code <= 57;
}
