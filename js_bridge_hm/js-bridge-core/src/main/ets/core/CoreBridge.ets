import { BridgeApiContract } from '../api/BridgeApiContract';
import { BridgeError } from '../api/BridgeError';
import { BridgeMessage, BridgeMessageKind } from '../api/BridgeMessage';
import { TrustedPageContext } from '../api/TrustedPageContext';

/// 传输函数类型：发送消息，返回是否成功。
export type BridgeTransport = (messageJson: string) => boolean | Promise<boolean>;

export type SimpleBridgeHandler = (payload: Object | null) => BridgeHandlerResult | Promise<BridgeHandlerResult>;
export type BridgeHandler = (context: TrustedPageContext, payload: Object | null) => BridgeHandlerResult | Promise<BridgeHandlerResult>;
export type StreamingResultEmitter = (result: BridgeHandlerResult) => Promise<boolean>;
export type SimpleStreamingBridgeHandler = (
  payload: Object | null,
  emit?: StreamingResultEmitter
) => BridgeHandlerResult[] | Promise<BridgeHandlerResult[]>;
export type StreamingBridgeHandler = (
  context: TrustedPageContext,
  payload: Object | null,
  emit?: StreamingResultEmitter
) => BridgeHandlerResult[] | Promise<BridgeHandlerResult[]>;

export class BridgeHandlerResult {
  readonly ok: boolean;
  readonly payload: Object | null;
  readonly error: BridgeError | null;
  readonly done: boolean;

  private constructor(ok: boolean, payload: Object | null, error: BridgeError | null, done: boolean) {
    this.ok = ok;
    this.payload = payload;
    this.error = error;
    this.done = done;
  }

  static success(payload: Object | null, done: boolean = true): BridgeHandlerResult {
    return new BridgeHandlerResult(true, payload, null, done);
  }

  static failure(error: BridgeError): BridgeHandlerResult {
    return new BridgeHandlerResult(false, null, error, true);
  }
}

type ContextStreamingHandler = (
  context: TrustedPageContext,
  payload: Object | null,
  emit?: StreamingResultEmitter
) => BridgeHandlerResult[] | Promise<BridgeHandlerResult[]>;

/// Tier 1 — 核心协议层。纯消息分发，零 security 依赖。
export class CoreBridge {
  private transport: BridgeTransport | null = null;
  private readonly handlers: Map<string, ContextStreamingHandler> = new Map<string, ContextStreamingHandler>();
  private sendFailures: number = 0;

  constructor(transport?: BridgeTransport) {
    this.transport = transport ?? null;
  }

  sendFailureCount(): number {
    return this.sendFailures;
  }

  attachTransport(transport: BridgeTransport | null): void {
    this.transport = transport;
  }

  registerHandler(method: string, handler: SimpleBridgeHandler): void {
    this.handlers.set(method, async (context: TrustedPageContext, payload: Object | null): Promise<BridgeHandlerResult[]> => {
      return [await handler(payload)];
    });
  }

  registerHandlerWithContext(method: string, handler: BridgeHandler): void {
    this.handlers.set(method, async (context: TrustedPageContext, payload: Object | null): Promise<BridgeHandlerResult[]> => {
      return [await handler(context, payload)];
    });
  }

  registerStreamingHandler(method: string, handler: SimpleStreamingBridgeHandler): void {
    this.handlers.set(method, async (context: TrustedPageContext, payload: Object | null, emit?: StreamingResultEmitter): Promise<BridgeHandlerResult[]> => {
      return await handler(payload, emit);
    });
  }

  registerStreamingHandlerWithContext(method: string, handler: StreamingBridgeHandler): void {
    this.handlers.set(method, handler);
  }

  async dispatch(request: BridgeMessage, context: TrustedPageContext): Promise<string[]> {
    const handler = this.handlers.get(request.method);
    if (handler === undefined) {
      return [this.failResponse(request, new BridgeError(BridgeApiContract.ERR_METHOD_NOT_FOUND, 'Method not found')).toJsonString()];
    }
    try {
      const results = await handler(context, request.payload, async (result: BridgeHandlerResult): Promise<boolean> => {
        return this.emitStreamingResponse(request, result);
      });
      return results.map((result: BridgeHandlerResult) => {
        if (result.ok) {
          return this.successResponse(request, result.payload, result.done).toJsonString();
        }
        return this.failResponse(request, result.error as BridgeError).toJsonString();
      });
    } catch (e) {
      return [this.failResponse(request, new BridgeError(BridgeApiContract.ERR_INTERNAL, `handler exception: ${e}`)).toJsonString()];
    }
  }

  buildEvent(method: string, payload: Object | null, sessionId: string | null = null): string {
    return new BridgeMessage(
      nextId(),
      sessionId ?? '',
      BridgeMessageKind.EVENT,
      method,
      Date.now(),
      0,
      false,
      payload
    ).toJsonString();
  }

  async postEvent(method: string, payload: Object | null, sessionId: string | null = null): Promise<boolean> {
    if (this.transport === null) {
      this.sendFailures += 1;
      return false;
    }
    try {
      const sent = await this.transport(this.buildEvent(method, payload, sessionId));
      if (!sent) {
        this.sendFailures += 1;
      }
      return sent;
    } catch (e) {
      this.sendFailures += 1;
      return false;
    }
  }

  destroy(): void {
    this.transport = null;
  }

  /// 通过已绑定的 transport 发送预构建的 JSON 字符串。
  /// 供 bindTransport 闭环使用；与 Android 的 respondSuccess/respondFail 对齐。
  async sendViaTransport(messageJson: string): Promise<boolean> {
    if (this.transport === null) {
      this.sendFailures += 1;
      return false;
    }
    try {
      const sent = await this.transport(messageJson);
      if (!sent) {
        this.sendFailures += 1;
      }
      return sent;
    } catch (e) {
      this.sendFailures += 1;
      return false;
    }
  }

  successResponse(request: BridgeMessage, payload: Object | null, done: boolean): BridgeMessage {
    return new BridgeMessage(
      nextId(),
      request.sessionId,
      BridgeMessageKind.RESPONSE,
      request.method,
      Date.now(),
      0,
      false,
      payload,
      request.id,
      done,
      true,
      null
    );
  }

  failResponse(request: BridgeMessage, error: BridgeError): BridgeMessage {
    return new BridgeMessage(
      nextId(),
      request.sessionId,
      BridgeMessageKind.RESPONSE,
      request.method,
      Date.now(),
      0,
      false,
      null,
      request.id,
      true,
      false,
      error
    );
  }

  private async emitStreamingResponse(request: BridgeMessage, result: BridgeHandlerResult): Promise<boolean> {
    if (this.transport === null) {
      this.sendFailures += 1;
      return false;
    }
    const response = result.ok
      ? this.successResponse(request, result.payload, result.done)
      : this.failResponse(request, result.error as BridgeError);
    try {
      const sent = await this.transport(response.toJsonString());
      if (!sent) {
        this.sendFailures += 1;
      }
      return sent;
    } catch (e) {
      this.sendFailures += 1;
      return false;
    }
  }
}

function nextId(): string {
  return `${Date.now()}-${Math.floor(Math.random() * 0xffffffff).toString(16)}`;
}
