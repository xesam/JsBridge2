import { BridgeApiContract } from '../api/BridgeApiContract';
import { BridgeError } from '../api/BridgeError';
import { BridgeMessage, BridgeMessageKind } from '../api/BridgeMessage';
import { TrustedPageContext } from '../api/TrustedPageContext';

export type BridgeTransport = (messageJson: string) => boolean | Promise<boolean>;

// MARK: 统一 Handler API (v1.0) — 注册表面固定为两态：Simple / Async

export class Result<T, E> {
  readonly value: T | null;
  readonly error: E | null;
  readonly isSuccess: boolean;

  private constructor(value: T | null, error: E | null, isSuccess: boolean) {
    this.value = value;
    this.error = error;
    this.isSuccess = isSuccess;
  }

  /// value 允许为 null：async handler 以 success(null) 表达"无数据成功"的终止帧（docs/03 §6 / C52）。
  static success<T, E>(value: T | null): Result<T, E> {
    return new Result<T, E>(value, null, true);
  }

  static failure<T, E>(error: E): Result<T, E> {
    return new Result<T, E>(null, error, false);
  }
}

/// Simple Handler: 单返回值，通信在返回时结束（恰好一帧，done 恒为 true）。
export type SimpleHandler = (
  context: TrustedPageContext,
  payload: Object | null
) => BridgeHandlerResult | Promise<BridgeHandlerResult>;

/// Response Emitter: 异步多响应发送器（done=false 为非终帧，done=true 收尾）
export type ResponseEmitter = (result: Result<Object, BridgeError>, done: boolean) => Promise<void>;

/// Async Handler: 带 ResponseEmitter 参数，可在返回后继续推帧（多帧只能由此形态表达）。
export type AsyncHandler = (
  context: TrustedPageContext,
  payload: Object | null,
  emitter: ResponseEmitter | null
) => void | Promise<void>;

/// Handler 结果：Simple 恒为单帧（done 恒为 true），故不携带 done 字段
export class BridgeHandlerResult {
  readonly ok: boolean;
  readonly payload: Object | null;
  readonly error: BridgeError | null;

  private constructor(ok: boolean, payload: Object | null, error: BridgeError | null) {
    this.ok = ok;
    this.payload = payload;
    this.error = error;
  }

  static success(payload: Object | null): BridgeHandlerResult {
    return new BridgeHandlerResult(true, payload, null);
  }

  static failure(error: BridgeError): BridgeHandlerResult {
    return new BridgeHandlerResult(false, null, error);
  }
}

type FrameEmitter = (result: BridgeHandlerResult, done: boolean) => Promise<boolean>;

/// 注册表内部统一形态：返回单帧结果；null 表示帧已由 FrameEmitter 直接发出（Async Handler）
type ContextStreamingHandler = (
  context: TrustedPageContext,
  payload: Object | null,
  emit: FrameEmitter
) => Promise<BridgeHandlerResult | null>;

/// Tier 1 — 核心协议层。纯消息分发，零 security 依赖。
///
/// Handler 注册表面固定为两态：registerSimpleHandler（恰好一帧，done 恒为 true）
/// 与 registerAsyncHandler（经 ResponseEmitter 多帧）；二者共用**单一注册表**，
/// 同一 method 重复注册时后者覆盖前者（见 docs/09-conformance.md C49）。
export class CoreBridge {
  private transport: BridgeTransport | null = null;
  private readonly handlers: Map<string, ContextStreamingHandler> = new Map<string, ContextStreamingHandler>();
  private sendFailures: number = 0;

  constructor(transport?: BridgeTransport) {
    this.transport = transport ?? null;
  }

  attachTransport(transport: BridgeTransport | null): void {
    this.transport = transport;
  }

  // MARK: Handler 注册（两态：Simple / Async）

  /**
   * 注册 Simple Handler: 单返回值，通信在返回时结束（恰好一帧，done 恒为 true）。
   * 需要多帧请改用 registerAsyncHandler。
   */
  registerSimpleHandler(method: string, handler: SimpleHandler): void {
    this.handlers.set(method, async (context: TrustedPageContext, payload: Object | null): Promise<BridgeHandlerResult | null> => {
      try {
        return await handler(context, payload);
      } catch (e) {
        return BridgeHandlerResult.failure(BridgeError.normalize(e));
      }
    });
  }

  /**
   * 注册 Async Handler: 带 ResponseEmitter 参数，可在返回后继续推帧（多帧）
   */
  registerAsyncHandler(method: string, handler: AsyncHandler): void {
    this.handlers.set(method, (context: TrustedPageContext, payload: Object | null, emit: FrameEmitter): Promise<BridgeHandlerResult | null> => {
      const emitter: ResponseEmitter = async (result: Result<Object, BridgeError>, done: boolean): Promise<void> => {
        if (result.isSuccess) {
          // 无数据成功（success(null)）的终止帧必须照发：ok=true、payload=null、done=true（docs/03 §6 / C52）。
          // 禁止以 null 守卫静默吞帧——否则 JS 端将挂死至超时（E_TIMEOUT 会伪装真实故障类别）
          await emit(BridgeHandlerResult.success(result.value), done);
        } else if (result.error !== null) {
          await emit(BridgeHandlerResult.failure(result.error), done);
        } else {
          // 失败但缺 error：归一化为 E_INTERNAL 错误帧，同样不静默吞帧
          await emit(BridgeHandlerResult.failure(
            new BridgeError(BridgeApiContract.ERR_INTERNAL, 'async handler emitted failure without error')
          ), done);
        }
      };

      // 启动不 await（docs/09 C62）：dispatch 对 Async handler 启动即返，
      // 对齐 Android / iOS / Flutter 的"dispatch 不因流式 handler 未完成而阻塞"语义——
      // 长时流式 handler 期间入站管线仍可继续处理后续消息，帧经 emitter 直达 transport。
      Promise.resolve()
        .then(async (): Promise<void> => {
          await handler(context, payload, emitter);
        })
        .catch(async (e: Object): Promise<void> => {
          // handler 异常必须转为失败终帧，不得向 ArkTS runtime 逃逸为 unhandled rejection
          try {
            await emit(BridgeHandlerResult.failure(BridgeError.normalize(e)), true);
          } catch (ignored) {
            // 终帧发送失败已计入 sendFailures（emitStreamingResponse 兜底），不再逃逸
          }
        });

      // 帧已由 emitter 直接发出，dispatch 不再产生额外帧
      return Promise.resolve<BridgeHandlerResult | null>(null);
    });
  }

  async dispatch(request: BridgeMessage, context: TrustedPageContext): Promise<string[]> {
    // Tier-1 kind 路由守卫（docs/09 C64 / docs/08 dispatch 契约）：仅 request 信封参与派发。
    // response/event 是 Native→JS 方向（docs/03 §1），standalone 使用 CoreBridge 时按 method
    // 命中同名 handler 属协议路由错误而非"无策略"自由；JsBridge 路径已在策略链
    // RequestShapePolicy 先行拒绝，此处为 belt-and-braces。
    if (request.kind !== BridgeMessageKind.REQUEST) {
      console.warn(`[JsBridge] dispatch dropped: non-request kind=${request.kind} method=${request.method} reqId=${request.reqId}`);
      return [];
    }
    const handler = this.handlers.get(request.method);
    if (handler === undefined) {
      return [this.failResponse(request, new BridgeError(BridgeApiContract.ERR_METHOD_NOT_FOUND, 'Method not found')).toJsonString()];
    }
    try {
      const emit: FrameEmitter = async (result: BridgeHandlerResult, done: boolean): Promise<boolean> => {
        return this.emitStreamingResponse(request, result, done);
      };
      const result: BridgeHandlerResult | null = await handler(context, request.payload, emit);
      if (result === null) {
        return [];
      }
      if (result.ok) {
        return [this.successResponse(request, result.payload, true).toJsonString()];
      }
      return [this.failResponse(request, result.error as BridgeError).toJsonString()];
    } catch (e) {
      return [this.failResponse(request, new BridgeError(BridgeApiContract.ERR_INTERNAL, `handler exception: ${e}`)).toJsonString()];
    }
  }

  // v1 事件帧 sessionId 恒为空串 ""（广播唯一形态，docs/03 §3.3 / C55）——
  // 无 sessionId 形参，与 Android / iOS / Flutter 四端对齐。
  private buildEvent(method: string, payload: Object | null): string {
    return new BridgeMessage(
      nextId(),
      '',
      BridgeMessageKind.EVENT,
      method,
      Date.now(),
      0,
      false,
      payload
    ).toJsonString();
  }

  async postEvent(method: string, payload: Object | null): Promise<boolean> {
    if (this.transport === null) {
      this.sendFailures += 1;
      return false;
    }
    try {
      const sent = await this.transport(this.buildEvent(method, payload));
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
      request.timeoutMs,
      request.keep,
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
      request.timeoutMs,
      request.keep,
      null,
      request.id,
      true,
      false,
      error
    );
  }

  private async emitStreamingResponse(request: BridgeMessage, result: BridgeHandlerResult, done: boolean): Promise<boolean> {
    if (this.transport === null) {
      this.sendFailures += 1;
      return false;
    }
    const response = result.ok
      ? this.successResponse(request, result.payload, done)
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
