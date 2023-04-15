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

  toJson(): Record<string, Object> {
    return {
      'code': this.code,
      'message': this.message,
      'retryable': this.retryable,
      'details': this.details
    };
  }
}
