package io.github.xesam.android.bridge;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.logging.Logger;

import io.github.xesam.android.bridge.api.contract.BridgeApiContract;
import io.github.xesam.android.bridge.api.model.BridgeError;
import io.github.xesam.android.bridge.api.model.BridgeMessage;
import io.github.xesam.android.bridge.api.model.TrustedPageContext;
import io.github.xesam.android.bridge.core.CoreBridge;
import io.github.xesam.android.bridge.core.message.MessageHandlerCallback;
import io.github.xesam.android.bridge.core.message.NativeMessageHandler;
import io.github.xesam.android.bridge.core.message.SimpleNativeMessageHandler;
import io.github.xesam.android.bridge.core.transport.BridgeTransport;
import io.github.xesam.android.bridge.security.context.PageContextProvider;
import io.github.xesam.android.bridge.security.policy.AccessControlPolicy;
import io.github.xesam.android.bridge.security.policy.HandshakeGatePolicy;
import io.github.xesam.android.bridge.security.policy.PolicyDecision;
import io.github.xesam.android.bridge.security.policy.PolicyEngine;
import io.github.xesam.android.bridge.security.policy.PolicyInput;
import io.github.xesam.android.bridge.security.policy.PolicyRule;
import io.github.xesam.android.bridge.security.policy.RequestShapePolicy;
import io.github.xesam.android.bridge.security.session.DefaultSessionService;
import io.github.xesam.android.bridge.security.session.HandshakeResult;
import io.github.xesam.android.bridge.security.session.InMemoryCapabilitySessionStore;
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

    public static final class KernelConfig {
        private int maxReadyListeners = 32;

        public KernelConfig maxReadyListeners(int maxReadyListeners) {
            this.maxReadyListeners = Math.max(1, maxReadyListeners);
            return this;
        }
    }

    public static final class SecurityConfig {
        private Set<String> methodWhitelist = new HashSet<>();
        private Set<String> allowedOrigins = new HashSet<>(Collections.singleton("*"));
        private Set<String> defaultCapabilities = new HashSet<>();
        private List<PolicyRule> extraPolicies = new ArrayList<>();
        private long sessionTtlMs = 15 * 60 * 1000L;
        private String policyVersion = "1";
        private boolean requireHandshake = false;
        private boolean requireAccessControl = false;

        public SecurityConfig methodWhitelist(Set<String> methodWhitelist) {
            this.methodWhitelist = new HashSet<>(methodWhitelist);
            return this;
        }

        public SecurityConfig allowedOrigins(Set<String> allowedOrigins) {
            this.allowedOrigins = new HashSet<>(allowedOrigins);
            return this;
        }

        public SecurityConfig defaultCapabilities(Set<String> defaultCapabilities) {
            this.defaultCapabilities = new HashSet<>(defaultCapabilities);
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

        public SecurityConfig withHandshakeGate() {
            this.requireHandshake = true;
            return this;
        }

        public SecurityConfig withAccessControl() {
            this.requireAccessControl = true;
            return this;
        }

        public static SecurityConfig secure() {
            return new SecurityConfig().withHandshakeGate().withAccessControl();
        }
    }

    private final CoreBridge core;
    private final PageContextProvider pageContextProvider;
    private final KernelConfig kernelConfig;
    private final SecurityConfig securityConfig;
    private final Map<String, NativeMessageHandler> contextHandlers = new ConcurrentHashMap<>();
    private final SessionService sessionService;
    private final List<ReadyListener> readyListeners = new CopyOnWriteArrayList<>();
    private final Object stateLock = new Object();

    private final PolicyEngine policyEngine;
    private volatile boolean ready;
    private String pageInstanceId = "";

    public JsBridge(
            BridgeTransport bridgeTransport,
            PageContextProvider pageContextProvider,
            KernelConfig kernelConfig,
            SecurityConfig securityConfig) {
        this.core = new CoreBridge(bridgeTransport);
        this.pageContextProvider = Objects.requireNonNull(pageContextProvider, "pageContextProvider == null");
        this.kernelConfig = Objects.requireNonNull(kernelConfig, "kernelConfig == null");
        this.securityConfig = Objects.requireNonNull(securityConfig, "securityConfig == null");
        if (this.securityConfig.requireAccessControl && this.securityConfig.allowedOrigins.contains("*")) {
            throw new IllegalArgumentException(
                    "JsBridge: AccessControlPolicy enabled but allowedOrigins is wildcard \"*\". "
                            + "Explicitly set allowedOrigins to obtain real origin protection; "
                            + "use Level 1 (withHandshakeGate only) if origin checks are not required.");
        }
        this.sessionService = new DefaultSessionService(
                new InMemoryCapabilitySessionStore(),
                this.securityConfig.defaultCapabilities,
                this.securityConfig.sessionTtlMs,
                this.securityConfig.policyVersion);
        List<PolicyRule> rules = new ArrayList<>();
        rules.add(new RequestShapePolicy());
        if (this.securityConfig.requireHandshake) {
            rules.add(new HandshakeGatePolicy());
        }
        if (this.securityConfig.requireAccessControl) {
            rules.add(new AccessControlPolicy(this.securityConfig.allowedOrigins, this.securityConfig.methodWhitelist));
        }
        rules.addAll(this.securityConfig.extraPolicies);
        this.policyEngine = new PolicyEngine(rules);
    }

    public void attachTransport(BridgeTransport transport) {
        core.attachTransport(transport);
    }

    public int getSendFailureCount() {
        return core.getSendFailureCount();
    }

    public void registerNativeHandler(String method, SimpleNativeMessageHandler handler) {
        core.registerHandler(method, handler);
    }

    public void registerNativeHandlerWithContext(String method, NativeMessageHandler handler) {
        Objects.requireNonNull(handler, "handler == null");
        contextHandlers.put(method, handler);
    }

    public void addReadyListener(ReadyListener listener) {
        synchronized (stateLock) {
            if (readyListeners.size() >= kernelConfig.maxReadyListeners) {
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

    public void resetForNewPage() {
        String previousPageInstanceId;
        synchronized (stateLock) {
            ready = !securityConfig.requireHandshake;
            previousPageInstanceId = pageInstanceId;
            pageInstanceId = java.util.UUID.randomUUID().toString();
        }
        sessionService.clearByPageInstance(previousPageInstanceId);
    }

    public void destroy() {
        sessionService.clearAll();
        core.destroy();
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
        NativeMessageHandler ctxHandler = contextHandlers.get(message.getMethod());
        if (ctxHandler != null) {
            try {
                ctxHandler.handle(
                        trustedPageContext,
                        message.getPayload() == null ? new JSONObject() : message.getPayload(),
                        new MessageHandlerCallback() {
                            @Override
                            public void success(Object res) {
                                core.respondSuccess(message, res, true);
                            }

                            @Override
                            public void success(Object res, boolean done) {
                                core.respondSuccess(message, res, done);
                            }

                            @Override
                            public void fail(Object error) {
                                core.respondFail(message, BridgeError.normalize(error));
                            }
                        });
            } catch (Throwable throwable) {
                core.respondFail(message, BridgeError.normalize(throwable));
            }
            return;
        }
        core.dispatch(message);
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
