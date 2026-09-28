import { BridgeApiContract } from '../api/BridgeApiContract';
import { JsBridge } from '../JsBridge';

export class RuntimeStatePayload {
  state: string;
  seq: number;

  constructor(state: string, seq: number) {
    this.state = state;
    this.seq = seq;
  }
}

/// Tier 3 — lifecycle 事件发布器。未 ready 时事件入 FIFO 队列（上限 maxPendingEvents，
/// 超限丢最旧）；每次握手成功后按序 flush。seq 跟随本实例生命周期，不随页面重置。
/// 语义对齐 Android extensions/lifecycle/LifecycleExtension.java；差异点：ArkTS 的
/// postEvent 是异步的，故另加 enqueueOp 串行链保证事件不因 await 交错而乱序
/// （Android / iOS 为同步 postEvent，无此需求）。
export class LifecycleExtension {
  private readonly bridge: JsBridge;
  private readonly maxPendingEvents: number;
  private readonly pendingEvents: RuntimeStatePayload[] = [];
  private seq: number = 0;
  private tail: Promise<void> = Promise.resolve();

  constructor(bridge: JsBridge, maxPendingEvents: number = 32) {
    this.bridge = bridge;
    this.maxPendingEvents = Math.max(1, maxPendingEvents);
    this.bridge.addReadyListener(() => {
      this.flushPending();
    });
  }

  onHostEvent(state: string): Promise<void> {
    this.seq += 1;
    const payload = new RuntimeStatePayload(state, this.seq);
    return this.enqueueOp(async (): Promise<void> => {
      const sent = await this.bridge.postEvent(BridgeApiContract.METHOD_LIFECYCLE, payload);
      if (!sent) {
        this.pendingEvents.push(payload);
        if (this.pendingEvents.length > this.maxPendingEvents) {
          this.pendingEvents.shift();
        }
      }
    });
  }

  private flushPending(): void {
    this.enqueueOp(async (): Promise<void> => {
      while (this.pendingEvents.length > 0) {
        const event = this.pendingEvents.shift() as RuntimeStatePayload;
        const sent = await this.bridge.postEvent(BridgeApiContract.METHOD_LIFECYCLE, event);
        if (!sent) {
          this.pendingEvents.push(event);
          return;
        }
      }
    });
  }

  private enqueueOp(op: () => Promise<void>): Promise<void> {
    this.tail = this.tail.then((): Promise<void> => op());
    return this.tail;
  }
}
