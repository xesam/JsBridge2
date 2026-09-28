package io.github.xesam.android.bridge.api;

import java.util.Locale;

/**
 * origin 序列化归一化（docs/03 §9 细则 5 / conformance C54，四端共用同一规则）：
 *
 * <ul>
 *   <li>{@code scheme} 与 {@code host} 小写；</li>
 *   <li>默认端口（{@code https:443} / {@code http:80}）必须省略——
 *       {@code https://host:443} 归一化为 {@code https://host}；</li>
 *   <li>非默认端口保留——{@code https://host:8443} 保持原样；</li>
 *   <li>URL 缺失（null / 空串）或非法 scheme 词法时 origin 为 {@code ""}；空串 origin
 *       永远不会命中任何白名单——fail-closed；</li>
 *   <li>本地内容协议保留 scheme 语义：{@code file:} 一律归一化为 {@code file://}；
 *       空 authority 的层级形态（{@code content://} / {@code asset://} /
 *       {@code flutter-asset:///…}）归一化为 {@code scheme://}——是否放行由宿主白名单决定；</li>
 *   <li>端口段须为纯 ASCII 数字（至多 5 位）且整数值在 1..65535，否则整体 fail-closed
 *       为 {@code ""}；端口按整数值与默认端口比较，命中则省略
 *       （{@code https://host:0443} → {@code https://host}）。</li>
 * </ul>
 *
 * <p>纯 Java、无 Android 依赖，可在 JVM 单测直测（宿主 provider 必须经由此类派生
 * {@code TrustedPageContext.origin}）。
 */
public final class OriginNormalizer {

    private OriginNormalizer() {
    }

    /** URL → 归一化 origin；URL 缺失或无法构成 authority 时返回空串。 */
    public static String normalize(String rawUrl) {
        if (rawUrl == null) {
            return "";
        }
        String url = rawUrl.trim();
        if (url.isEmpty()) {
            return "";
        }
        int colonIndex = url.indexOf(':');
        if (colonIndex <= 0 || !isValidScheme(url.substring(0, colonIndex))) {
            return "";
        }
        String scheme = url.substring(0, colonIndex).toLowerCase(Locale.ROOT);
        String rest = url.substring(colonIndex + 1);

        // 本地内容协议保留 scheme 语义（docs/03 §9 细则 5），是否放行归宿主白名单
        if ("file".equals(scheme)) {
            return "file://";
        }
        // 无层级形态（如 about:blank）：无 authority，无法构成 origin → 空串 fail-closed
        if (!rest.startsWith("//")) {
            return "";
        }
        String authority = authorityOf(rest.substring(2));
        if (authority.isEmpty()) {
            // 空 authority（content://、asset://、flutter-asset:///… 等本地内容协议形态）
            // → 保留 scheme 语义（docs/03 §9 细则 5），是否放行由宿主白名单决定
            return scheme + "://";
        }
        // 端口段判定：冒号须在最后一个 ']' 之后（IPv6 字面量如 [::1]:8443 内部冒号不当作端口分隔）
        int bracketEnd = authority.lastIndexOf(']');
        int portColon = authority.lastIndexOf(':');
        String host;
        String portText = null;
        if (portColon > bracketEnd) {
            host = authority.substring(0, portColon);
            portText = authority.substring(portColon + 1);
        } else {
            host = authority;
        }
        if (host.isEmpty()) {
            return "";
        }
        String hostLower = host.toLowerCase(Locale.ROOT);
        if (portText == null) {
            return scheme + "://" + hostLower;
        }
        char[] portChars = portText.toCharArray();
        // 端口段必须是纯 ASCII 数字（Integer.parseInt 会静默接受 "+80" 等带符号形态）
        if (portChars.length == 0 || portChars.length > 5 || !isDigits(portChars)) {
            // 端口段非法的畸形 URL → 空串 fail-closed，不参与白名单命中
            return "";
        }
        int port = Integer.parseInt(portText);
        if (port <= 0 || port > 65535) {
            // 端口值非法（0 / 超 TCP 端口上限）→ 空串 fail-closed：
            // 畸形端口不得回退成可命中的 origin（http://host:0 ≠ http://host）
            return "";
        }
        if (isDefaultPort(scheme, port)) {
            return scheme + "://" + hostLower;
        }
        return scheme + "://" + hostLower + ":" + port;
    }

    /** authority 段：首个 '/'、'?'、'#' 之前；剥离 userinfo（最后一个 '@' 之前）。 */
    private static String authorityOf(String rest) {
        int end = rest.length();
        for (int i = 0; i < rest.length(); i++) {
            char c = rest.charAt(i);
            if (c == '/' || c == '?' || c == '#') {
                end = i;
                break;
            }
        }
        String authority = rest.substring(0, end);
        int at = authority.lastIndexOf('@');
        if (at >= 0) {
            authority = authority.substring(at + 1);
        }
        return authority;
    }

    private static boolean isDefaultPort(String scheme, int port) {
        if ("https".equals(scheme)) {
            return port == 443;
        }
        if ("http".equals(scheme)) {
            return port == 80;
        }
        return false;
    }

    /**
     * RFC 3986 scheme 词法的 ASCII 子集（四端统一，收窄于 Unicode 全集以对齐 Dart/ArkTS）：
     * 首字符 ASCII 字母，其余为 ASCII 字母/数字/+/-/.。
     */
    private static boolean isValidScheme(String raw) {
        if (raw.isEmpty() || !isAsciiLetter(raw.charAt(0))) {
            return false;
        }
        for (int i = 1; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (!isAsciiLetter(c) && !isAsciiDigit(c) && c != '+' && c != '-' && c != '.') {
                return false;
            }
        }
        return true;
    }

    private static boolean isDigits(char[] chars) {
        for (char c : chars) {
            if (!isAsciiDigit(c)) {
                return false;
            }
        }
        return true;
    }

    private static boolean isAsciiLetter(char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }

    private static boolean isAsciiDigit(char c) {
        return c >= '0' && c <= '9';
    }
}
