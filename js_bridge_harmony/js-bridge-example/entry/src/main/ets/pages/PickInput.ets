import { router } from '@kit.ArkUI';
import { BridgeError, BridgeHandlerResult } from '@xesam/js_bridge_core';

@Entry
@Component
struct PickInput {
  @State name: string = '';
  @State age: string = '';
  /// 四个按钮出口已自行 router.back(params) 回传结果；
  /// 置位后 onBackPress 不再重复拦截，避免覆盖结果。
  private settled: boolean = false;

  onBackPress(): boolean {
    if (this.settled) {
      return false;
    }
    // 系统返回（侧滑/返回键）未走任何按钮：补一次失败回传（E_INTERNAL，
    // 否则调用方的 Promise 无处 settle，只能等到 JS 侧超时。
    this.settled = true;
    router.back({
      url: 'pages/Index',
      params: {
        pickInputResult: BridgeHandlerResult.failure(
          new BridgeError('E_INTERNAL', 'launch canceled')  // 返回 E_INTERNAL 而非 E_CANCELED——E_CANCELED 为 JS 本地码，不跨端传输（docs/03 §8）
        )
      }
    });
    return true;
  }

  build() {
    Column() {
      Text('Pick Input')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 20, bottom: 24 })
        .width('100%')
        .textAlign(TextAlign.Center)

      TextInput({ placeholder: 'name', text: this.name })
        .onChange((value: string) => {
          this.name = value;
        })
        .margin({ bottom: 16 })

      TextInput({ placeholder: 'age', text: this.age })
        .type(InputType.Number)
        .onChange((value: string) => {
          this.age = value;
        })
        .margin({ bottom: 24 })

      Button('Submit')
        .width('100%')
        .onClick(() => {
          this.submit();
        })
        .margin({ bottom: 12 })

      Button('Cancel')
        .width('100%')
        .backgroundColor(Color.Gray)
        .onClick(() => {
          this.cancel();
        })
    }
    .width('100%')
    .height('100%')
    .padding(16)
  }

  /// 唯一的出口：回传结果并置位 settled，使 onBackPress 不再重复拦截。
  private finish(result: BridgeHandlerResult): void {
    this.settled = true;
    router.back({
      url: 'pages/Index',
      params: {
        pickInputResult: result
      }
    });
  }

  private submit(): void {
    const name = this.name.trim();
    const ageNum = Number(this.age.trim());

    if (name.length === 0) {
      this.finish(BridgeHandlerResult.failure(
        new BridgeError('E_INVALID_PAYLOAD', 'name is required')
      ));
      return;
    }

    if (!Number.isInteger(ageNum) || ageNum < 0) {
      this.finish(BridgeHandlerResult.failure(
        new BridgeError('E_INVALID_PAYLOAD', 'age must be a non-negative integer')
      ));
      return;
    }

    this.finish(BridgeHandlerResult.success(new InputPayload(name, ageNum)));
  }

  private cancel(): void {
    this.finish(BridgeHandlerResult.failure(new BridgeError('E_INTERNAL', 'launch canceled')));  // 返回 E_INTERNAL 而非 E_CANCELED——E_CANCELED 为 JS 本地码，不跨端传输（docs/03 §8）
  }
}

class InputPayload {
  name: string;
  age: number;
  native: boolean = true;

  constructor(name: string, age: number) {
    this.name = name;
    this.age = age;
  }
}
