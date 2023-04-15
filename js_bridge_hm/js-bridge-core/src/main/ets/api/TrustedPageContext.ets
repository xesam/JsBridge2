export class TrustedPageContext {
  readonly origin: string;
  readonly pageInstanceId: string;

  constructor(origin: string, pageInstanceId: string) {
    this.origin = origin;
    this.pageInstanceId = pageInstanceId;
  }
}
