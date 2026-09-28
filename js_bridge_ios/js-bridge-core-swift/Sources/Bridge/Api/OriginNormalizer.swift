import Foundation

/// origin 序列化归一化（docs/03 §9 细则 5，四端统一规则，验收锚点 C54）。
/// `TrustedPageContext.origin` 的唯一合法形态由本类型产生，宿主 provider 必须经它派生 origin，
/// OriginPolicy 比较的也是归一化后的字符串。
///
/// 四端共用同一套**手写字符串算法**（全量校验向量见 `docs/origin-normalizer-vectors.json`），
/// 刻意不依赖 `URL` / `URLComponents`——Foundation 解析器在 IPv6 方括号
/// （`url.host` 会剥掉 `[::1]` 的字面量方括号）、前导零端口、空 authority 等形态上
/// 与其他端的算法行为不一致，构成跨端漂移源。
public enum OriginNormalizer {

    /// 归一化 URL 为 origin 串（fail-closed：URL 缺失 / scheme 词法非法 / 非层级形态 /
    /// 端口段非法 → `""`；空串 origin 永远不会命中任何白名单）。
    public static func normalize(_ url: URL?) -> String {
        return normalize(rawUrl: url?.absoluteString)
    }

    /// 便捷重载：字符串 URL 归一化（语义同 `normalize(_:)`，直接走字符串算法）。
    public static func normalize(urlString: String?) -> String {
        return normalize(rawUrl: urlString)
    }

    static func normalize(rawUrl: String?) -> String {
        guard let rawUrl else { return "" }
        let url = rawUrl.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return "" }
        guard let colon = url.firstIndex(of: ":") else { return "" }
        let schemeRaw = String(url[..<colon])
        guard isValidScheme(schemeRaw) else { return "" }
        let scheme = schemeRaw.lowercased()
        let rest = String(url[url.index(after: colon)...])

        // 本地内容协议保留 scheme 语义（任意 file URL 一律归一化为 "file://"）
        if scheme == "file" {
            return "file://"
        }
        // 非层级形态（about: / data: / mailto: 等无 // 形态）→ 空串 fail-closed
        guard rest.hasPrefix("//") else { return "" }
        let authority = authorityOf(String(rest.dropFirst(2)))
        if authority.isEmpty {
            // 空 authority（content:// / asset:// / 本地内容协议无 host 形态）→ 保留 scheme 语义
            return scheme + "://"
        }
        // 端口分隔冒号须在最后一个 ']' 之后（IPv6 字面量内部冒号不作端口分隔）
        let bracketEnd = authority.lastIndex(of: "]")
        let portColon = authority.lastIndex(of: ":")
        let host: String
        let portText: String?
        if let portColon, bracketEnd.map({ portColon > $0 }) ?? true {
            host = String(authority[..<portColon])
            portText = String(authority[authority.index(after: portColon)...])
        } else {
            host = authority
            portText = nil
        }
        guard !host.isEmpty else { return "" }
        let hostLower = host.lowercased()
        guard let portText else {
            return scheme + "://" + hostLower
        }
        guard !portText.isEmpty, isDigits(portText), let port = Int(portText), port > 0, port <= 65535 else {
            // 端口段非法（非纯数字 / 0 / 超 TCP 上限）→ 空串 fail-closed。
            // Int(portText) 仍静默接受 "-80" 等负号形态，必须先做纯数字校验。
            return ""
        }
        if isDefaultPort(scheme, port) {
            return scheme + "://" + hostLower
        }
        return "\(scheme)://\(hostLower):\(port)"
    }

    /// authority 段：首个 '/'、'?'、'#' 之前；剥离 userinfo（最后一个 '@' 之前）。
    private static func authorityOf(_ rest: String) -> String {
        let cut = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = String(rest[..<cut])
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }
        return authority
    }

    private static func isDefaultPort(_ scheme: String, _ port: Int) -> Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }

    /// RFC 3986 scheme 词法的 ASCII 子集（四端统一）：首字符 ASCII 字母，其余 ASCII 字母/数字/+/-/.。
    private static func isValidScheme(_ raw: String) -> Bool {
        guard let first = raw.first, isAsciiLetter(first) else { return false }
        return raw.dropFirst().allSatisfy { c in
            isAsciiLetter(c) || isAsciiDigit(c) || c == "+" || c == "-" || c == "."
        }
    }

    private static func isDigits(_ raw: String) -> Bool {
        let chars = Array(raw)
        guard !chars.isEmpty, chars.count <= 5 else { return false }
        return chars.allSatisfy { isAsciiDigit($0) }
    }

    private static func isAsciiLetter(_ c: Character) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    private static func isAsciiDigit(_ c: Character) -> Bool {
        c >= "0" && c <= "9"
    }
}
