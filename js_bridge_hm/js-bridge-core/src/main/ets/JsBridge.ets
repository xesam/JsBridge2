import { BridgeApiContract } from '../api/BridgeApiContract';
import { BridgeError } from '../api/BridgeError';
import { BridgeMessage } from '../api/BridgeMessage';
import { TrustedPageContext } from '../api/TrustedPageContext';
import { CoreBridge, BridgeTransport, BridgeHandlerResult } from '../core/CoreBridge';
import { SessionRecord } from '../security/SessionRecord';
import { SessionService } from '../security/SessionService';
import { PageContextProvider } from '../security/PageContextProvider';
import {
  PolicyEngine,
  PolicyInput,
  PolicyRule,
  RequestShapePolicy,
  HandshakeGatePolicy,
  AccessControlPolicy
} from '../security/PolicyEngine';

export type ExtraPolicy = (request: BridgeMessage, context: TrustedPageContext) => BridgeError | null;
export type SimpleBridgeHandler = (payload: Object | null) => BridgeHandlerResult | Promise<BridgeHandlerResult>;
export type BridgeHandler = (context: TrustedPageContext, payload: Object | null) => BridgeHandlerResult | Promise<BridgeHandlerResult>;
export type SimpleStreamingBridgeHandler = (
  payload: Object | null,
  emit?: (result: BridgeHandlerResult) => Promise<boolean>
) => BridgeHandlerResult[] | Promise<BridgeHandlerResult[]>;
export type StreamingBridgeHandler = (
  context: TrustedPageContext,
  payload: Object | null,
  emit?: (result: BridgeHandlerResult) => Promise<boolean>
) => BridgeHandlerResult[] | Promise<BridgeHandlerResult[]>;

export interface JsBridgeOptions {
  allowedOrigins: Set<string>;
  methodWhitelist: Set<string>;
  defaultCapabilities: Set<string>;
  policyVersion?: string;
  sessionTtlMs?: number;
  extraPolicies?: ExtraPolicy[];
  transport?: BridgeTransport;
  requireHandshake?: boolean;
  requireAccessControl?: boolean;
  pageContextProvider?: PageContextProvider;
  maxReadyListeners?: number;
}

interface HandshakePayload {
  sessionId: string;
  capabilities: string[];
  sessionTtlMs: number;
  policyVersion: string;
  origin: string;
  accepted: boolean;
}

class ExtraPolicyAdapter implements PolicyRule {
  name: string = 'ExtraPolicyAdapter';
  private readonly fn: ExtraPolicy;

  constructor(fn: ExtraPolicy) {
    this.fn = fn;
  }

  evaluate(input: PolicyInput): BridgeError | null {
    return this.fn(input.message, input.context);
  }
}

/// Tier 2 — 会话/策略/握手层，叠加在 CoreBridge 之上。
export class JsBridge {
  readonly allowedOrigins: Set<string>;
  readonly methodWhitelist: Set<string>;
  readonly defaultCapabilities: Set<string>;
  readonly policyVersion: string;
  readonly sessionTtlMs: number;
  readonly extraPolicies: ExtraPolicy[];
  readonly requireHandshake: boolean;
  readonly requireAccessControl: boolean;
  readonly maxReadyListeners: number;

  private readonly core: CoreBridge;
  private readonly sessionService: SessionService = new SessionService();
  private readonly pageContextProvider: PageContextProvider | null;
  private ready: boolean = false;
  private pageInstanceId: string = nextId();
  private activeSession: SessionRecord | null = null;
  private readonly policyEngine: PolicyEngine;
  private readonly readyListeners: Array<() => void> = [];

  constructor(options: JsBridgeOptions) {
    this.allowedOrigins = options.allowedOrigins;
    this.methodWhitelist = options.methodWhitelist;
    this.defaultCapabilities = options.defaultCapabilities;
    this.policyVersion = options.policyVersion ?? '1';
    this.sessionTtlMs = options.sessionTtlMs ?? 15 * 60 * 1000;
    this.extraPolicies = options.extraPolicies ?? [];
    this.requireHandshake = options.requireHandshake ?? false;
    this.requireAccessControl = options.requireAccessControl ?? false;
    this.pageContextProvider = options.pageContextProvider ?? null;
    this.maxReadyListeners = options.maxReadyListeners ?? 32;
    this.core = new CoreBridge(options.transport);

    if (this.requireAccessControl && this.allowedOrigins.has('*')) {
      throw new Error(
        'JsBridge: AccessControlPolicy enabled but allowedOrigins is wildcard "*". '
        + 'Explicitly set allowedOrigins to obtain real origin protection; '
        + 'use Level 1 (requireHandshake only) if origin checks are not required.'
      );
    }

    const rules: PolicyRule[] = [new RequestShapePolicy()];
    if (this.requireHandshake) {
      rules.push(new HandshakeGatePolicy());
    }
    if (this.requireAccessControl) {
      rules.push(new AccessControlPolicy(this.allowedOrigins, this.methodWhitelist));
    }
    for (const ep of this.extraPolicies) {
      rules.push(new ExtraPolicyAdapter(ep));
    }
    this.policyEngine = new PolicyEngine(rules);
  }

  static secure(options: JsBridgeOptions): JsBridge {
    const secureOptions: JsBridgeOptions = {
      allowedOrigins: options.allowedOrigins,
      methodWhitelist: options.methodWhitelist,
      defaultCapabilities: options.defaultCapabilities,
      policyVersion: options.policyVersion,
      sessionTtlMs: options.sessionTtlMs,
      extraPolicies: options.extraPolicies,
      transport: options.transport,
      requireHandshake: true,
      requireAccessControl: true,
      pageContextProvider: options.pageContextProvider,
      maxReadyListeners: options.maxReadyListeners
    };
    return new JsBridge(secureOptions);
  }

  isReady(): boolean {
    return this.ready;
  }

  addReadyListener(listener: () => void): void {
    if (this.readyListeners.length >= this.maxReadyListeners) {
      throw new Error('JsBridge: ready listener limit reached');
    }
    this.readyListeners.push(listener);
  }

  currentSession(): SessionRecord | null {
    return this.activeSession;
  }

  sendFailureCount(): number {
    return this.core.sendFailureCount();
  }

  attachTransport(transport: BridgeTransport | null): void {
    this.core.attachTransport(transport);
  }

  /// 绑定入站消息处理闭环，返回一个可传给 NativeBridgeProxy 的处理函数。
  /// 调用前须先注入 transport + PageContextProvider。
  /// 幂等：每次调用返回新的 handler，内部引用最新的 transport。
  bindTransport(): (messageJson: string) => Promise<void> {
    return async (messageJson: string) => {
      const responses = await this.processIncomingResponsesFromProvider(messageJson);
      for (const response of responses) {
        await this.core.sendViaTransport(response);
      }
    };
  }

  destroy(): void {
    this.sessionService.clearAll();
    this.core.destroy();
  }

  resetForNewPage(): void {
    this.ready = !this.requireHandshake;
    this.activeSession = null;
    this.sessionService.clearByPageInstance(this.pageInstanceId);
    this.pageInstanceId = nextId();
  }

  registerHandler(method: string, handler: SimpleBridgeHandler): void {
    this.core.registerHandler(method, handler);
  }

  registerHandlerWithContext(method: string, handler: BridgeHandler): void {
    this.core.registerHandlerWithContext(method, handler);
  }

  registerStreamingHandler(method: string, handler: SimpleStreamingBridgeHandler): void {
    this.core.registerStreamingHandler(method, handler);
  }

  registerStreamingHandlerWithContext(method: string, handler: StreamingBridgeHandler): void {
    this.core.registerStreamingHandlerWithContext(method, handler);
  }

  processIncomingResponses(messageJson: string, origin: string): Promise<string[]> {
    return this.processIncomingResponsesForContext(
      messageJson,
      new TrustedPageContext(origin, this.pageInstanceId)
    );
  }

  processIncomingResponsesFromProvider(messageJson: string): Promise<string[]> {
    if (this.pageContextProvider === null) {
      throw new Error('JsBridge: pageContextProvider not configured');
    }
    let request: BridgeMessage;
    try {
      request = BridgeMessage.fromJsonString(messageJson);
    } catch (e) {
      return Promise.resolve([]);
    }
    return this.processIncomingResponsesForContext(messageJson, this.pageContextProvider.createContext(request, this.pageInstanceId));
  }

  async processIncomingResponsesForContext(messageJson: string, context: TrustedPageContext): Promise<string[]> {
    let request: BridgeMessage;
    try {
      request = BridgeMessage.fromJsonString(messageJson);
    } catch (e) {
      return [];
    }

    const deny = this.policyEngine.evaluate(new PolicyInput(request, context, this.ready, this.activeSession));
    if (deny !== null) {
      return [this.core.failResponse(request, deny).toJsonString()];
    }

    if (request.method === BridgeApiContract.METHOD_HANDSHAKE) {
      const record = this.sessionService.issue(context, this.defaultCapabilities, this.sessionTtlMs);
      this.ready = true;
      this.activeSession = record;
      const payload: HandshakePayload = {
        sessionId: record.sessionId,
        capabilities: Array.from(record.capabilities).sort(),
        sessionTtlMs: this.sessionTtlMs,
        policyVersion: this.policyVersion,
        origin: context.origin,
        accepted: true
      };
      const responses = [this.core.successResponse(request, payload, true).toJsonString()];
      for (const listener of this.readyListeners) {
        listener();
      }
      return responses;
    }

    if (request.method === BridgeApiContract.METHOD_CANCEL_SCOPE) {
      const payload: Record<string, Object> = {
        scopeId: request.payload ? (request.payload as Record<string, Object>)['scopeId'] ?? '' : '',
        accepted: true
      };
      return [this.core.successResponse(request, payload, true).toJsonString()];
    }

    return this.core.dispatch(request, context);
  }

  async postEvent(method: string, payload: Object | null, sessionId: string | null = null): Promise<boolean> {
    if (!this.ready) {
      return false;
    }
    const activeSessionId = this.activeSession === null ? '' : this.activeSession.sessionId;
    return this.core.postEvent(method, payload, sessionId ?? activeSessionId);
  }
}

function nextId(): string {
  return `${Date.now()}-${Math.floor(Math.random() * 0xffffffff).toString(16)}`;
}
