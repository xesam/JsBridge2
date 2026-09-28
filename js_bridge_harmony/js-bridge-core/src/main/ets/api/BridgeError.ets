import { BridgeApiContract } from './BridgeApiContract';

export class BridgeError {
  readonly code: string;
  readonly message: string;
  readonly retryable: boolean;
  readonly details: Record<string, Object>;

  constructor(
    code: string,
    message: string,
    retryable: boolean = false,
    details: Record<string, Object> = {}
  ) {
    this.code = code;
    this.message = message;
    this.retryable = retryable;
    this.details = details;
  }

  static normalize(rawError: Object | Error | string): BridgeError {
    if (rawError instanceof BridgeError) {
      return rawError;
    }
    if (rawError instanceof Error) {
      const msg = rawError.message || 'Internal error';
      return new BridgeError(BridgeApiContract.ERR_INTERNAL, msg);
    }
    if (typeof rawError === 'object' && rawError !== null) {
      // 运行时类型守卫：宿主抛出非 Error 的 plain object 时，
      // 逐字段 typeof 校验后再收窄，缺字段或类型不符走 fallback——禁止 as 直通穿透
      const json = rawError as Record<string, Object>;
      const rawCode = json['code'];
      const rawMessage = json['message'];
      const rawRetryable = json['retryable'];
      const rawDetails = json['details'];
      const code = typeof rawCode === 'string' ? rawCode : BridgeApiContract.ERR_INTERNAL;
      const message = typeof rawMessage === 'string' ? rawMessage : 'Internal error';
      const retryable = typeof rawRetryable === 'boolean' ? rawRetryable : false;
      const details: Record<string, Object> = typeof rawDetails === 'object' && rawDetails !== null
        ? rawDetails as Record<string, Object>
        : {};
      return new BridgeError(code, message, retryable, details);
    }
    if (typeof rawError === 'string') {
      return new BridgeError(BridgeApiContract.ERR_INTERNAL, rawError);
    }
    return new BridgeError(BridgeApiContract.ERR_INTERNAL, 'Internal error');
  }

  toJson(): Record<string, Object> {
    return {
      'code': this.code,
      'message': this.message,
      'retryable': this.retryable,
      'details': this.details
    };
  }
}
