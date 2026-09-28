package io.github.xesam.android.bridge.api.contract;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

public final class BridgeApiContract {
    public static final String METHOD_HANDSHAKE = "bridge.handshake";
    public static final String METHOD_LIFECYCLE = "runtime.state";
    public static final String METHOD_CANCEL_SCOPE = "bridge.cancelScope";

    /**
     * 协议方法集：框架装配 MethodGatePolicy 时自动并入 methodWhitelist 放行集（docs/03 §9）。
     * methodWhitelist 语义为业务方法白名单，宿主无需显式列入协议方法（显式列入亦合法，冗余无副作用）。
     * 仅含 JS → Native request 方向协议方法（runtime.state 为 Native → JS event，不经过 MethodGatePolicy）。
     * 新增协议 request 方法时，必须同步加入本集合并四端同步（docs/03 §7 保留方法）。
     */
    public static final Set<String> PROTOCOL_METHODS = Collections.unmodifiableSet(
            new HashSet<>(Arrays.asList(METHOD_HANDSHAKE, METHOD_CANCEL_SCOPE)));

    /**
     * 协议错误码基线，四端一致。任何业务错误码都应取自此处，禁止在策略/handler 中使用内联字面量。
     */
    public static final String ERR_INVALID_MESSAGE = "E_INVALID_MESSAGE";
    public static final String ERR_POLICY_DENY = "E_POLICY_DENY";
    public static final String ERR_ORIGIN_DENY = "E_ORIGIN_DENY";
    public static final String ERR_METHOD_NOT_ALLOWED = "E_METHOD_NOT_ALLOWED";
    public static final String ERR_SESSION_INVALID = "E_SESSION_INVALID";
    public static final String ERR_METHOD_NOT_FOUND = "E_METHOD_NOT_FOUND";
    public static final String ERR_INTERNAL = "E_INTERNAL";

    /**
     * transport 层错误码（v1 裁决，docs/03 §8 传输层类）：
     * E_CHANNEL_CLOSED：信道建立失败（JS 客户端本地产生，不跨端传输）；
     * E_NOT_READY：会话未建立即调用非握手方法（JS 门控与 Native HandshakeGate 双侧同码）。
     */
    public static final String ERR_CHANNEL_CLOSED = "E_CHANNEL_CLOSED";
    public static final String ERR_NOT_READY = "E_NOT_READY";

    /**
     * 通道建立 pull 模型（docs/04 §3.1 通道建立入口契约 / docs/06 信道建立机制）：
     * 入口名与事件词汇为公共 API，v1 定死；入口收可选 JSON 参数，忽略未知字段。
     */
    public static final String CHANNEL_EVENT_TYPE = "bridge:channel";
    public static final String REQUEST_CHANNEL_ENTRY = "requestBridgeChannel";

    private BridgeApiContract() {
    }
}
