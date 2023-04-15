package io.github.xesam.android.bridge.api.contract;

public final class BridgeApiContract {
    public static final String METHOD_HANDSHAKE = "bridge.handshake";
    public static final String METHOD_LIFECYCLE = "runtime.state";
    public static final String METHOD_CANCEL_SCOPE = "bridge.cancelScope";

    /**
     * 协议错误码基线，四端一致。任何业务错误码都应取自此处，禁止在策略/handler 中使用内联字面量。
     */
    public static final String ERR_INVALID_MESSAGE = "E_INVALID_MESSAGE";
    public static final String ERR_POLICY_DENY = "E_POLICY_DENY";
    public static final String ERR_ORIGIN_DENY = "E_ORIGIN_DENY";
    public static final String ERR_METHOD_NOT_ALLOWED = "E_METHOD_NOT_ALLOWED";
    public static final String ERR_SESSION_INVALID = "E_SESSION_INVALID";
    public static final String ERR_CAPABILITY_DENY = "E_CAPABILITY_DENY";
    public static final String ERR_METHOD_NOT_FOUND = "E_METHOD_NOT_FOUND";
    public static final String ERR_INTERNAL = "E_INTERNAL";

    private BridgeApiContract() {
    }
}
