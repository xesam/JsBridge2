package io.github.xesam.android.bridge;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.logging.Logger;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.BridgeMessage;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.core.CoreBridge;
import io.github.xesam.android.bridge.core.transport.BridgeTransport;
import io.github.xesam.android.bridge.security.context.PageContextProvider;
import io.github.xesam.android.bridge.security.policy.HandshakeGatePolicy;
import io.github.xesam.android.bridge.security.policy.MethodGatePolicy;
import io.github.xesam.android.bridge.security.policy.OriginPolicy;
import io.github.xesam.android.bridge.security.policy.PolicyDecision;
import io.github.xesam.android.bridge.security.policy.PolicyEngine;
import io.github.xesam.android.bridge.security.policy.PolicyInput;
import io.github.xesam.android.bridge.security.policy.PolicyRule;
import io.github.xesam.android.bridge.security.policy.RequestShapePolicy;
import io.github.xesam.android.bridge.security.policy.SessionPolicy;
import io.github.xesam.android.bridge.security.session.DefaultSessionService;
import io.github.xesam.android.bridge.security.session.HandshakeResult;
import io.github.xesam.android.bridge.security.session.InMemorySessionStore;
import io.github.xesam.android.bridge.security.session.SessionRecord;
import io.github.xesam.android.bridge.security.session.SessionService;

/**
 * Tier 2 — 会话/策略/握手层，叠加在 {@link CoreBridge} 之上。
 * 拦截 transport 入口，插入策略链，策略通过后委托 CoreBridge 分发。
 */
public final class JsBridge {
    private static final Logger LOGGER = Logger.getLogger(JsBridge.class.getName());

    public interface ReadyListener {
        void onReady();
    }

    private static final int MAX_READY_LISTENERS = 32;

    public static final class SecurityConfig {
        public static final long DEFAULT_SESSION_TTL_MS = 15 * 60 * 1000L;
        public static final String DEFAULT_POLICY_VERSION = "v1";

        // {"*"} = 显式不限制，节点不进策略链；具体值集合 = 启用白名单校验
        // methodWhitelist 语义详见 BridgeApiContract.PROTOCOL_METHODS 文档
        private Set<String> methodWhitelist = null;
        private Set<String> allowedOrigins = null;
        private List<PolicyRule> extraPolicies = new ArrayList<>();
        private long sessionTtlMs = DEFAULT_SESSION_TTL_MS;
        private String policyVersion = DEFAULT_POLICY_VERSION;

        public SecurityConfig methodWhitelist(Set<String> methodWhitelist) {
            this.methodWhitelist = new HashSet<>(methodWhitelist);
            return this;
        }

        public SecurityConfig allowedOrigins(Set<String> allowedOrigins) {
            this.allowedOrigins = new HashSet<>(allowedOrigins);
            return this;
        }

        public SecurityConfig extraPolicies(List<PolicyRule> extraPolicies) {
            this.extraPolicies = new ArrayList<>(extraPolicies);
            return this;
        }

        public SecurityConfig sessionTtlMs(long sessionTtlMs) {
            this.sessionTtlMs = sessionTtlMs;
            return this;
        }

        public SecurityConfig policyVersion(String policyVersion) {
            this.policyVersion = policyVersion;
            return this;
        }

        void validate() {
            if (allowedOrigins == null) {
                throw new IllegalArgumentException(
                        "SecurityConfig: allowedOrigins is required. "
                                + "Use Collections.singleton(\"*\") to allow all origins, "
                                + "or supply specific origins.");
            }
            if (methodWhitelist == null) {
                throw new IllegalArgumentException(
                        "SecurityConfig: methodWhitelist is required. "
                                + "Use Collections.singleton(\"*\") to allow all methods, "
                                + "or supply specific methods.");
            }
        }
    }

    private final CoreBridge core;
    private final PageContextProvider pageContextProvider;
    private final SecurityConfig securityConfig; // nullable
    private final SessionService sessionService;
    private final List<ReadyListener> readyListeners = new CopyOnWriteArrayList<>();
    private final Object stateLock = new Object();

    private final PolicyEngine policyEngine;
    private volatile boolean ready;
    // 初值取构造期 UUID，与其他端（iOS 为构造期 UUID）一致——保证 birth pageInstanceId
    // 恒非空，clearByPageInstance 能清扫构造后、首次 resetPageInstance 前签发的 session；
    // resetPageInstance 的轮换语义不变
    private String pageInstanceId = java.util.UUID.randomUUID().toString();

    public JsBridge(
            BridgeTransport bridgeTransport,
            PageContextProvider pageContextProvider,
            SecurityConfig securityConfig) {
        this.core = new CoreBridge(bridgeTransport);
        this.pageContextProvider = Objects.requireNonNull(pageContextProvider, "pageContextProvider == null");
        this.securityConfig = securityConfig;

        if (this.securityConfig != null) {
            this.securityConfig.validate();
        }

        // 无配置场景：握手非必需，但握手请求仍可到达（策略链只有 RequestShapePolicy），
        // 保留默认 SessionService 以便签发 session。
        long sessionTtlMs = this.securityConfig != null
                ? this.securityConfig.sessionTtlMs : SecurityConfig.DEFAULT_SESSION_TTL_MS;
        String policyVersion = this.securityConfig != null
                ? this.securityConfig.policyVersion : SecurityConfig.DEFAULT_POLICY_VERSION;
        this.sessionService = new DefaultSessionService(
                new InMemorySessionStore(), sessionTtlMs, policyVersion);

        List<PolicyRule> rules = new ArrayList<>();
        rules.add(new RequestShapePolicy());

        if (this.securityConfig != null) {
            rules.add(new HandshakeGatePolicy());

            if (!this.securityConfig.allowedOrigins.contains("*")) {
                rules.add(new OriginPolicy(this.securityConfig.allowedOrigins));
            }

            // 协议方法由框架自动并入放行集（语义详见 BridgeApiContract.PROTOCOL_METHODS 文档）
            if (!this.securityConfig.methodWhitelist.contains("*")) {
                Set<String> effectiveWhitelist = new HashSet<>(this.securityConfig.methodWhitelist);
                effectiveWhitelist.addAll(BridgeApiContract.PROTOCOL_METHODS);
                rules.add(new MethodGatePolicy(effectiveWhitelist));
            }

            rules.add(new SessionPolicy());
            rules.addAll(this.securityConfig.extraPolicies);
        }

        this.policyEngine = new PolicyEngine(rules);
    }

    public void attachTransport(BridgeTransport transport) {
        core.attachTransport(transport);
    }

    // MARK: Handler 注册（两态，委托 CoreBridge；单一注册表，后注册覆盖先注册）

    /**
     * 注册 Simple Handler: 单返回值，通信在返回时结束（恰好一帧，done 恒为 true）
     * @param handler 处理函数，首形参为可信页面上下文
     */
    public void registerSimpleHandler(String method, io.github.xesam.android.bridge.core.handler.SimpleHandler handler) {
        core.registerSimpleHandler(method, handler);
    }

    /**
     * 注册 Async Handler: 带 ResponseEmitter 参数，可在返回后继续推帧
     * @param handler 处理函数，首形参为可信页面上下文
     */
    public void registerAsyncHandler(String method, io.github.xesam.android.bridge.core.handler.AsyncHandler handler) {
        core.registerAsyncHandler(method, handler);
    }

    public void addReadyListener(ReadyListener listener) {
        synchronized (stateLock) {
            if (readyListeners.size() >= MAX_READY_LISTENERS) {
                throw new IllegalStateException("ready listener limit reached");
            }
            readyListeners.add(Objects.requireNonNull(listener, "listener == null"));
        }
    }

    public boolean isReady() {
        return ready;
    }

    public boolean postEvent(String method, Object payload) {
        if (!ready) {
            return false;
        }
        return core.postEvent(method, payload);
    }

    public void resetTransport() {
        core.bind(this::onIncomingMessage);
    }

    public void resetPageInstance() {
        String previousPageInstanceId;
        synchronized (stateLock) {
            ready = (securityConfig == null);
            previousPageInstanceId = pageInstanceId;
            pageInstanceId = java.util.UUID.randomUUID().toString();
        }
        sessionService.clearByPageInstance(previousPageInstanceId);
    }

    public void destroy() {
        sessionService.clearAll();
        core.destroy();
        // 复用防泄漏：宿主复用同一实例重新 resetTransport()/resetPageInstance() 时，
        // 旧 listener（常持有 Activity/shell 引用）不得再被回调（四端同步语义）
        readyListeners.clear();
    }

    private void onIncomingMessage(String messageJson) {
        BridgeMessage message = BridgeMessage.fromJson(messageJson);
        if (message == null) {
            return;
        }
        String currentPageInstanceId;
        boolean currentReady;
        synchronized (stateLock) {
            currentPageInstanceId = pageInstanceId;
            currentReady = ready;
        }
        TrustedPageContext trustedPageContext = pageContextProvider.createContext(message, currentPageInstanceId);
        SessionRecord sessionRecord = sessionService.find(message.getSessionId());
        PolicyDecision decision = policyEngine.evaluate(new PolicyInput(message, trustedPageContext, currentReady, sessionRecord));
        if (!decision.isAllowed()) {
            auditReject(decision, message, trustedPageContext);
            BridgeError error = decision.getError();
            core.respondFail(message, error != null ? error
                    : new BridgeError(BridgeApiContract.ERR_POLICY_DENY, "denied (missing error)"));
            return;
        }
        if (BridgeApiContract.METHOD_HANDSHAKE.equals(message.getMethod())) {
            handleHandshake(message, trustedPageContext);
            return;
        }
        if (BridgeApiContract.METHOD_CANCEL_SCOPE.equals(message.getMethod())) {
            handleCancelScope(message);
            return;
        }
        core.dispatch(message, trustedPageContext);
    }

    private void handleHandshake(BridgeMessage message, TrustedPageContext trustedPageContext) {
        HandshakeResult handshakeResult = sessionService.issueHandshake(trustedPageContext);
        synchronized (stateLock) {
            ready = true;
        }
        core.respondSuccess(message, handshakeResult.getPayload(), true);
        for (ReadyListener readyListener : readyListeners) {
            readyListener.onReady();
        }
    }

    private void handleCancelScope(BridgeMessage message) {
        Object rawPayload = message.getPayload();
        JSONObject payload = rawPayload instanceof JSONObject ? (JSONObject) rawPayload : new JSONObject();
        String scopeId = payload.optString("scopeId", "");
        JSONObject result = new JSONObject();
        try {
            result.put("scopeId", scopeId);
            result.put("accepted", true);
        } catch (org.json.JSONException e) {
            throw new RuntimeException(e);
        }
        core.respondSuccess(message, result, true);
    }

    private void auditReject(PolicyDecision decision, BridgeMessage message, TrustedPageContext trustedPageContext) {
        BridgeError error = decision.getError();
        LOGGER.warning("policy_deny rule=" + decision.getRule()
                + " method=" + message.getMethod()
                + " origin=" + trustedPageContext.getOrigin()
                + " pageId=" + trustedPageContext.getPageInstanceId()
                + " session=" + message.getSessionId()
                + " code=" + (error == null ? "" : error.toJsonObject().optString("code")));
    }
}
