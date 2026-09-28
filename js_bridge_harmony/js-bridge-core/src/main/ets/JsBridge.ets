import { BridgeApiContract } from './api/BridgeApiContract';
import { BridgeError } from './api/BridgeError';
import { BridgeMessage } from './api/BridgeMessage';
import { OriginNormalizer } from './api/OriginNormalizer';
import { TrustedPageContext } from './api/TrustedPageContext';
import { CoreBridge, BridgeTransport, SimpleHandler, AsyncHandler } from './core/CoreBridge';
import { SessionService } from './security/SessionService';
import { PageContextProvider } from './security/PageContextProvider';
import {
  PolicyEngine,
  PolicyDecision,
  PolicyInput,
  PolicyRule,
  RequestShapePolicy,
  HandshakeGatePolicy,
  OriginPolicy,
  MethodGatePolicy,
  SessionPolicy
} from './security/PolicyEngine';

/// 宿主自定义策略（经 SecurityConfig.extraPolicies 注入）：
/// - 返回 null = 放行
/// - 返回 BridgeError = 拒绝（携带 error）
/// - 返回 PolicyDecision = 拒绝可显式不携带 error，由框架以 E_POLICY_DENY 兜底，
///   禁止静默放行到 dispatch（docs/03 §9 细则 3，验收锚点 C53）
export type ExtraPolicy = (request: BridgeMessage, context: TrustedPageContext) => BridgeError | PolicyDecision | null;

/// 安全配置：传入即视为需要握手（握手门控 + session 校验进链）。
/// allowedOrigins / methodWhitelist 类型声明允许 null，但 JsBridge 构造函数在 config 非 null 时
/// 强制运行时校验——传 null 将抛出 Error（构造期 fail-fast，docs/03 §9）：
///   - {"*"} = 显式不限制，对应节点不进策略链
///   - 具体值 = 启用该维度白名单校验
/// methodWhitelist 语义详见 BridgeApiContract.getProtocolMethods 文档
export interface SecurityConfig {
  allowedOrigins: Set<string> | null;
  methodWhitelist: Set<string> | null;
  policyVersion?: string;
  sessionTtlMs?: number;
  extraPolicies?: ExtraPolicy[];
}

export interface JsBridgeOptions {
  // null / 省略 = 无安全检查（无需握手，仅 RequestShapePolicy 进链）
  securityConfig?: SecurityConfig | null;
  transport?: BridgeTransport;
  pageContextProvider?: PageContextProvider;
}

interface HandshakePayload {
  sessionId: string;
  sessionTtlMs: number;
  policyVersion: string;
  origin: string;
  accepted: boolean;
}

interface CancelScopePayload {
  scopeId: string;
  accepted: boolean;
}

class ExtraPolicyAdapter implements PolicyRule {
  private readonly fn: ExtraPolicy;

  constructor(fn: ExtraPolicy) {
    this.fn = fn;
  }

  evaluate(input: PolicyInput): BridgeError | null {
    const result: BridgeError | PolicyDecision | null = this.fn(input.message, input.context);
    if (result === null) {
      return null;
    }
    if (result instanceof PolicyDecision) {
      if (result.allowed) {
        return null;
      }
      // fail-closed：deny 但缺 error 时以 E_POLICY_DENY 兜底（docs/03 §9 细则 3 / C53）
      if (result.error === null) {
        return new BridgeError(BridgeApiContract.ERR_POLICY_DENY, 'policy denied (missing error)');
      }
      return result.error;
    }
    return result;
  }
}

/// Tier 2 — 会话/策略/握手层，叠加在 CoreBridge 之上。
/// options.securityConfig 为 null/省略表示无安全检查（无需握手，仅 RequestShapePolicy 进链）。
export class JsBridge {
  private static readonly MAX_READY_LISTENERS: number = 32;

  readonly policyVersion: string;
  readonly sessionTtlMs: number;

  private readonly core: CoreBridge;
  private readonly sessionService: SessionService = new SessionService();
  private readonly pageContextProvider: PageContextProvider | null;
  private readonly securityConfig: SecurityConfig | null;
  private ready: boolean = false;
  private pageInstanceId: string = nextId();
  private readonly policyEngine: PolicyEngine;
  private readonly readyListeners: Array<() => void> = [];
  private readyNotificationPending: boolean = false;
  /// 标记生产路径是否已建立（bindTransport 设置为 true）
  private trustedOriginSource: boolean = false;

  constructor(options: JsBridgeOptions) {
    const config: SecurityConfig | null = options.securityConfig ?? null;
    this.securityConfig = config;
    this.policyVersion = config?.policyVersion ?? 'v1';
    this.sessionTtlMs = config?.sessionTtlMs ?? 15 * 60 * 1000;
    this.pageContextProvider = options.pageContextProvider ?? null;
    this.core = new CoreBridge(options.transport);

    if (config !== null) {
      if (config.allowedOrigins === null) {
        throw new Error(
          'JsBridge: allowedOrigins is required. '
          + 'Use new Set(["*"]) to allow all origins, '
          + 'or supply specific origins.'
        );
      }
      if (config.methodWhitelist === null) {
        throw new Error(
          'JsBridge: methodWhitelist is required. '
          + 'Use new Set(["*"]) to allow all methods, '
          + 'or supply specific methods.'
        );
      }
    }

    const rules: PolicyRule[] = [new RequestShapePolicy()];
    if (config !== null) {
      rules.push(new HandshakeGatePolicy());
      // allowedOrigins 非 {"*"} 时才进链；装配期防御性拷贝——
      // 不持宿主 Set 引用，宿主后续增删不影响已装配链（与 MethodGatePolicy 放行集的构造方式对齐）
      if (config.allowedOrigins !== null && !config.allowedOrigins.has('*')) {
        const effectiveOrigins = new Set<string>();
        config.allowedOrigins.forEach((origin: string) => {
          effectiveOrigins.add(origin);
        });
        rules.push(new OriginPolicy(effectiveOrigins));
      }
      // methodWhitelist 非 {"*"} 时才进链；协议方法由框架自动并入放行集（语义详见 BridgeApiContract.getProtocolMethods 文档）
      if (config.methodWhitelist !== null && !config.methodWhitelist.has('*')) {
        // getProtocolMethods() 每次返回全新防御性拷贝，可直接在其上并入用户白名单
        const effectiveWhitelist = BridgeApiContract.getProtocolMethods();
        config.methodWhitelist.forEach((m: string) => {
          effectiveWhitelist.add(m);
        });
        rules.push(new MethodGatePolicy(effectiveWhitelist));
      }
      rules.push(new SessionPolicy());
      for (const ep of config.extraPolicies ?? []) {
        rules.push(new ExtraPolicyAdapter(ep));
      }
    }
    this.policyEngine = new PolicyEngine(rules);
  }

  isReady(): boolean {
    return this.ready;
  }

  addReadyListener(listener: () => void): void {
    if (this.readyListeners.length >= JsBridge.MAX_READY_LISTENERS) {
      throw new Error('JsBridge: ready listener limit reached');
    }
    this.readyListeners.push(listener);
  }

  attachTransport(transport: BridgeTransport | null): void {
    this.core.attachTransport(transport);
  }

  /// 绑定入站消息处理闭环，返回一个可传给 NativeBridgeProxy 的处理函数。
  /// 调用前须先注入 transport + PageContextProvider：provider 缺失在此 fail-fast；
  /// transport 缺失不做装配期校验，仅沿发送链计入失败（sendViaTransport 返回 false）。
  /// 每次调用返回新的 handler 闭包，内部捕获最新的 transport。
  /// 次序保证：握手响应先于 ready listener 副作用（如 lifecycle 补发）写入 transport。
  bindTransport(): (messageJson: string) => Promise<void> {
    // fail-fast：缺 PageContextProvider 是装配错误，绑定期立即暴露，
    // 不等首条消息才发现（消息级兜底仍保留在 processIncomingResponsesFromProviderUnchecked）
    if (this.pageContextProvider === null) {
      throw new Error('JsBridge: pageContextProvider not configured before bindTransport()');
    }
    // 标记生产路径已建立（origin 由 PageContextProvider 派生，可信）
    this.trustedOriginSource = true;
    return async (messageJson: string): Promise<void> => {
      // 处理链兜底（对齐 Flutter bindTransport catch-all 口径）：
      // 宿主 PageContextProvider / extraPolicies 抛出的异常若沿本闭包逃逸，
      // ArkTS runtime 会按 unhandled rejection 处理（报错日志、部分版本进程异常）。
      // 解析失败（malformed）与策略拒绝在 processIncomingResponsesForContextCore
      // 内已有 fail-closed 失败路径；本 catch 只兜"宿主代码异常"——丢弃本轮并日志，
      // JS 侧以既有 timeout 自愈
      let responses: string[];
      try {
        responses = await this.processIncomingResponsesFromProviderUnchecked(messageJson);
      } catch (e) {
        console.error('JsBridge: inbound processing failed (host provider/policy threw)', e as Object);
        return;
      }
      for (const response of responses) {
        await this.core.sendViaTransport(response);
      }
      this.flushReadyNotification();
    };
  }

  /// 触发已就绪但尚未通知的 ready listeners（幂等；每轮握手只通知一次）。
  private flushReadyNotification(): void {
    if (!this.readyNotificationPending) {
      return;
    }
    this.readyNotificationPending = false;
    for (const listener of this.readyListeners) {
      listener();
    }
  }

  destroy(): void {
    this.sessionService.clearAll();
    this.core.destroy();
    // 复用防泄漏：宿主复用同一实例重新 bind()/resetPageInstance() 时，
    // 旧 listener 不得再被回调（四端同步语义）
    this.readyListeners.length = 0;
  }

  resetPageInstance(): void {
    this.ready = this.securityConfig === null;  // null = 立即 ready；非 null = 等待握手
    this.readyNotificationPending = false;
    this.sessionService.clearByPageInstance(this.pageInstanceId);
    this.pageInstanceId = nextId();
  }

  // MARK: Handler 注册（两态，委托 CoreBridge；单一注册表，后者覆盖前者）

  registerSimpleHandler(method: string, handler: SimpleHandler): void {
    this.core.registerSimpleHandler(method, handler);
  }

  registerAsyncHandler(method: string, handler: AsyncHandler): void {
    this.core.registerAsyncHandler(method, handler);
  }

  // 次序语义（与 Flutter/iOS 同名入口一致，跨端契约）：这些入口在本轮处理完成时
  // **立即** flush ready listeners（可能同步产生 lifecycle 事件帧），此时握手响应串
  // 刚要返回给调用方——事件帧可能先于握手响应帧抵达 JS。严格的"握手响应先于 ready
  // 副作用"次序只在 bindTransport() 闭环内保证；JS 侧 lifecycle 扩展按 docs/03 §7.2
  // 对未 ready 事件排队补发，故此乱序在端到端语义上被掩盖。需要严格次序的宿主应使用
  // bindTransport()。
  /// @internal - TESTING ONLY. Production code MUST use bindTransport().
  /// Origin is trusted only when derived by PageContextProvider through bindTransport.
  /// 测试注入面：显式 origin 构造 context。origin 在入口经 OriginNormalizer.normalize
  /// 归一化（与 provider 路径同一约束——fail-closed）。生产宿主走 bindTransport() 闭环。
  processIncomingResponses(messageJson: string, origin: string): Promise<string[]> {
    // 运行时保护：bindTransport() 已建立生产路径时，拒绝外部 origin 注入
    if (this.trustedOriginSource) {
      console.warn('JsBridge: processIncomingResponses called after bindTransport - ignored (use bindTransport for production)');
      return Promise.resolve([]);
    }
    const responses = this.processIncomingResponsesForContextCore(
      messageJson,
      new TrustedPageContext(OriginNormalizer.normalize(origin), this.pageInstanceId)
    );
    return responses.then((r: string[]): string[] => {
      this.flushReadyNotification();
      return r;
    });
  }

  private processIncomingResponsesFromProviderUnchecked(messageJson: string): Promise<string[]> {
    if (this.pageContextProvider === null) {
      return Promise.reject(new Error('JsBridge: pageContextProvider not configured'));
    }
    let request: BridgeMessage;
    try {
      request = BridgeMessage.fromJsonString(messageJson);
    } catch (e) {
      return Promise.resolve([]);
    }
    return this.processIncomingResponsesForContextCore(
      messageJson,
      this.pageContextProvider.createContext(request, this.pageInstanceId)
    );
  }

  /// @internal - TESTING ONLY. Production code MUST use bindTransport().
  /// 测试注入面：以显式 TrustedPageContext 驱动策略链（生产宿主走 bindTransport() 闭环）。
  async processIncomingResponsesForContext(messageJson: string, context: TrustedPageContext): Promise<string[]> {
    // 运行时保护：bindTransport() 已建立生产路径时，拒绝外部 context 注入
    if (this.trustedOriginSource) {
      console.warn('JsBridge: processIncomingResponsesForContext called after bindTransport - ignored (use bindTransport for production)');
      return [];
    }
    const responses = await this.processIncomingResponsesForContextCore(messageJson, context);
    this.flushReadyNotification();
    return responses;
  }

  private async processIncomingResponsesForContextCore(messageJson: string, context: TrustedPageContext): Promise<string[]> {
    let request: BridgeMessage;
    try {
      request = BridgeMessage.fromJsonString(messageJson);
    } catch (e) {
      return [];
    }

    // 策略链求值：宿主注入的 extraPolicies 抛异常时 fail-closed 拒绝（deny 帧），
    // 与四端"策略链失败即拒绝"语义一致——禁止宿主策略异常沿处理链逃逸
    let deny: BridgeError | null;
    try {
      deny = this.policyEngine.evaluate(new PolicyInput(request, context, this.ready, this.sessionService.find(request.sessionId)));
    } catch (e) {
      console.error('JsBridge: policy chain threw during evaluate', e as Object);
      deny = new BridgeError(BridgeApiContract.ERR_POLICY_DENY, 'policy evaluation failed');
    }
    if (deny !== null) {
      return [this.core.failResponse(request, deny).toJsonString()];
    }

    if (request.method === BridgeApiContract.METHOD_HANDSHAKE) {
      const record = this.sessionService.issue(context, this.sessionTtlMs);
      this.ready = true;
      this.readyNotificationPending = true;
      const payload: HandshakePayload = {
        sessionId: record.sessionId,
        sessionTtlMs: this.sessionTtlMs,
        policyVersion: this.policyVersion,
        origin: context.origin,
        accepted: true
      };
      return [this.core.successResponse(request, payload, true).toJsonString()];
    }

    if (request.method === BridgeApiContract.METHOD_CANCEL_SCOPE) {
      let scopeId: string = '';
      const payload: Object | null = request.payload;
      if (payload !== null && typeof payload === 'object') {
        const raw = (payload as Record<string, Object>)['scopeId'];
        // 运行时类型检查：scopeId 非字符串（如数字）时置空串，禁止 as 直通穿透类型
        if (typeof raw === 'string') {
          scopeId = raw;
        }
      }
      const responsePayload: CancelScopePayload = {
        scopeId: scopeId,
        accepted: true
      };
      return [this.core.successResponse(request, responsePayload, true).toJsonString()];
    }

    return this.core.dispatch(request, context);
  }

  async postEvent(method: string, payload: Object | null): Promise<boolean> {
    if (!this.ready) {
      return false;
    }
    // 协议裁决（docs/03 §3.3 / C55）：v1 事件投放唯一形态为广播——事件帧 sessionId
    // 恒为空串 ""，不得默认以最近一次握手的 session 作为事件归属。API 为两参
    // postEvent(method, payload)，与 Android / iOS / Flutter 四端对齐；
    // 定向投送不属于 v1 能力面，引入须作为契约变更先登记验收用例（docs/09 §6）。
    return this.core.postEvent(method, payload);
  }
}

function nextId(): string {
  return `${Date.now()}-${Math.floor(Math.random() * 0xffffffff).toString(16)}`;
}
