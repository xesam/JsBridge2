import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { geoLocationManager } from '@kit.LocationKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { router } from '@kit.ArkUI';
import {
  BridgeError,
  BridgeMessage,
  BridgeMessageKind,
  BridgeHandlerResult,
  JsBridgeOptions,
  JsBridge,
  OriginNormalizer,
  PageContextProvider,
  TrustedPageContext,
  ResponseEmitter,
  Result,
  LifecycleExtension
} from '@xesam/js_bridge_core';

const PAGE_ORIGIN = 'file://';

class FilePageContextProvider implements PageContextProvider {
  createContext(message: BridgeMessage, pageInstanceId: string): TrustedPageContext {
    // origin 必须经核心层归一化产生（docs/03 §9 细则 5，验收锚点 C54）
    return new TrustedPageContext(OriginNormalizer.normalize(PAGE_ORIGIN), pageInstanceId);
  }
}

class RequestPayload {
  url: string;
  code: number;
  body: string;

  constructor(url: string, code: number, body: string) {
    this.url = url;
    this.code = code;
    this.body = body;
  }
}

class TimerTickPayload {
  event: string = 'tick';
  value: number;
  seq: number;
  running: boolean = true;

  constructor(value: number, seq: number) {
    this.value = value;
    this.seq = seq;
  }
}

class TimerStoppedPayload {
  event: string = 'stopped';
  running: boolean = false;
}

class UserPayload {
  name: string;

  constructor(name: string) {
    this.name = name;
  }
}

class LoadingPayload {
  status: string;
  native: boolean = true;
  durationMs: number;

  constructor(durationMs: number) {
    this.status = 'shown';
    this.durationMs = durationMs;
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

class PickImagePayload {
  uri: string;
  type: string;
  source: string = 'photo-library';
  native: boolean = true;

  constructor(uri: string, type: string) {
    this.uri = uri;
    this.type = type;
  }
}

class LocationPayload {
  lat: number;
  lng: number;
  accuracy: number;
  provider: string = 'harmony';
  timestamp: number;

  constructor(latitude: number, longitude: number, accuracy: number, timestamp: number) {
    this.lat = latitude;
    this.lng = longitude;
    this.accuracy = accuracy;
    this.timestamp = timestamp;
  }
}

class NativeBridgeProxy {
  private readonly onMessage: (messageJson: string) => void;

  constructor(onMessage: (messageJson: string) => void) {
    this.onMessage = onMessage;
  }

  postMessage(messageJson: string): void {
    this.onMessage(messageJson);
  }
}

class RequestOptionsPayload implements http.HttpRequestOptions {
  method: http.RequestMethod = http.RequestMethod.GET;
  expectDataType: http.HttpDataType = http.HttpDataType.STRING;
  readTimeout: number = 5000;
  connectTimeout: number = 5000;
}

@Entry
@Component
struct Index {
  private readonly controller: webview.WebviewController = new webview.WebviewController();
  private bridge: JsBridge = this.createBridge();
  private readonly lifecycleExtension: LifecycleExtension = new LifecycleExtension(this.bridge);
  private onIncoming: (messageJson: string) => Promise<void> = this.bridge.bindTransport();
  private nativeBridge: NativeBridgeProxy = new NativeBridgeProxy((messageJson: string): void => {
    void this.onIncoming(messageJson);
  });

  @State status: string = 'loading';
  @State loadingVisible: boolean = false;
  @State loadingTitle: string = 'Loading';
  @State loadingContent: string = 'Please wait...';
  private pickInputInFlight: boolean = false;
  private pickInputResult: BridgeHandlerResult | null = null;
  private pickInputResolve: ((result: BridgeHandlerResult) => void) | null = null;
  private loadingTimer: number = -1;
  private timerRunning: boolean = false;
  private timerCounter: number = 0;
  private timerInterval: number = -1;
  private timerStreamEmitter: ResponseEmitter | null = null;
  private locationInFlight: boolean = false;

  aboutToAppear(): void {
    this.bridge.resetPageInstance();
    void this.lifecycleExtension.onHostEvent('created');
  }

  onPageShow(): void {
    void this.lifecycleExtension.onHostEvent('foreground');
    // pickInput 的回填参数必须在 onPageShow 消费：router.back() 不重建栈中页面，
    // 不会再次触发 aboutToAppear（曾因此在 aboutToAppear 读取而永远收不到结果）。
    // 用 pickInputInFlight 而非 pickInputResolve 作守卫——后者在 await pushUrl
    // 之后才赋值，返回时它可能尚未写入。
    if (this.pickInputInFlight) {
      this.consumePickInputResult();
    }
  }

  /// 消费 PickInput 页面经 router.back(params) 回传的结果。
  /// 返回是否确实消费到了结果。
  private consumePickInputResult(): boolean {
    const params = router.getParams() as Record<string, Object>;
    if (!params || !params['pickInputResult']) {
      return false;
    }
    const result = params['pickInputResult'] as BridgeHandlerResult;
    this.pickInputResult = result;
    this.pickInputInFlight = false;
    const resolve = this.pickInputResolve;
    this.pickInputResolve = null;
    if (resolve !== null) {
      resolve(result);
    }
    return true;
  }

  onPageHide(): void {
    void this.lifecycleExtension.onHostEvent('background');
  }

  private createBridge(): JsBridge {
    const options: JsBridgeOptions = {
      securityConfig: {
        allowedOrigins: new Set<string>([PAGE_ORIGIN]),
        // methodWhitelist 语义为业务方法白名单，协议方法（bridge.handshake 等）由框架自动放行
        methodWhitelist: new Set<string>([
          'getUser',
          'request',
          'timerLog',
          'showLoading',
          'pickImage',
          'pickInput',
          'getCurrentLocation'
        ])
      },
      transport: (messageJson: string): boolean => this.sendToWeb(messageJson),
      pageContextProvider: new FilePageContextProvider()
    };
    const bridge = new JsBridge(options);

    // demo 用固定账号桩：与 Android/iOS/Flutter 的 mock 行为一致
    // （userId "001" -> xesam，其他 -> E_NOT_FOUND）。真实宿主应替换为账号服务。
    bridge.registerSimpleHandler('getUser',
      (context: TrustedPageContext, payload: Object | null): Promise<BridgeHandlerResult> => this.handleGetUser(payload));
    bridge.registerSimpleHandler('request',
      (context: TrustedPageContext, payload: Object | null): Promise<BridgeHandlerResult> => this.handleRequest(payload));
    bridge.registerAsyncHandler('timerLog',
      (context: TrustedPageContext, payload: Object | null, emitter: ResponseEmitter | null): Promise<void> => this.handleTimerLog(payload, emitter));
    bridge.registerSimpleHandler('showLoading', (context: TrustedPageContext, payload: Object | null): BridgeHandlerResult => {
      const visible = this.booleanField(payload, 'visible', true);
      const durationMs = this.numberField(payload, 'durationMs', 1200);
      this.showNativeLoading(
        this.stringField(payload, 'title', 'Loading'),
        this.stringField(payload, 'content', 'Please wait...'),
        durationMs,
        visible
      );
      return BridgeHandlerResult.success(
        new LoadingPayload(durationMs)
      );
    });
    bridge.registerSimpleHandler('pickImage',
      (context: TrustedPageContext, payload: Object | null): Promise<BridgeHandlerResult> => this.handlePickImage(payload));
    bridge.registerSimpleHandler('pickInput',
      (context: TrustedPageContext, payload: Object | null): Promise<BridgeHandlerResult> => this.handlePickInput());
    bridge.registerSimpleHandler('getCurrentLocation',
      (context: TrustedPageContext, payload: Object | null): Promise<BridgeHandlerResult> => {
        return this.handleGetCurrentLocation(
          this.stringField(payload, 'accuracy', 'coarse'),
          this.numberField(payload, 'timeoutMs', 10000)
        );
      });

    return bridge;
  }

  private async handleGetUser(payload: Object | null): Promise<BridgeHandlerResult> {
    const userId = this.stringField(payload, 'userId', '');
    if (userId === '001') {
      return BridgeHandlerResult.success(new UserPayload('xesam'));
    }
    const details: Record<string, Object> = { 'userId': userId };
    return BridgeHandlerResult.failure(
      new BridgeError('E_NOT_FOUND', 'user not found', false, details)
    );
  }

  private async handleRequest(payload: Object | null): Promise<BridgeHandlerResult> {
    const url = this.stringField(payload, 'url', '');
    if (url.length === 0) {
      return BridgeHandlerResult.failure(new BridgeError('E_INVALID_PAYLOAD', 'request.url is required'));
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return BridgeHandlerResult.failure(new BridgeError('E_INVALID_PAYLOAD', 'request.url must be http/https'));
    }

    const request = http.createHttp();
    try {
      const response = await request.request(url, new RequestOptionsPayload());
      const body = typeof response.result === 'string'
        ? response.result
        : JSON.stringify(response.result);
      return BridgeHandlerResult.success(new RequestPayload(url, response.responseCode as number, body));
    } catch (e) {
      return BridgeHandlerResult.failure(new BridgeError('E_REQUEST_FAILED', `request failed: ${e}`));
    } finally {
      request.destroy();
    }
  }

  private showNativeLoading(title: string, content: string, durationMs: number, visible: boolean): void {
    if (this.loadingTimer >= 0) {
      clearTimeout(this.loadingTimer);
      this.loadingTimer = -1;
    }
    if (!visible) {
      this.loadingVisible = false;
      return;
    }

    this.loadingTitle = title;
    this.loadingContent = content;
    this.loadingVisible = true;
    this.loadingTimer = setTimeout(() => {
      this.loadingVisible = false;
      this.loadingTimer = -1;
    }, Math.max(300, durationMs));
  }

  private async handlePickInput(): Promise<BridgeHandlerResult> {
    if (this.pickInputInFlight) {
      return BridgeHandlerResult.failure(new BridgeError('E_BUSY', 'pickInput is already in progress'));
    }
    this.pickInputInFlight = true;
    this.pickInputResult = null;

    // 先挂好 resolve 再跳转：pushUrl 之后导航与页面展示可能先于赋值发生，
    // 那时 onPageShow 消费到结果却无处投递（曾因此丢结果）。
    const pending = new Promise<BridgeHandlerResult>((resolve) => {
      this.pickInputResolve = resolve;
    });

    try {
      await router.pushUrl({
        url: 'pages/PickInput'
      });
    } catch (e) {
      this.pickInputInFlight = false;
      this.pickInputResolve = null;
      return BridgeHandlerResult.failure(new BridgeError('E_LAUNCH_FAILED', `launch failed: ${e}`));
    }

    // 页面已返回且已消费到结果时不会再有 onPageShow，这里补一次消费。
    this.consumePickInputResult();

    return pending;
  }

  private async handlePickImage(payload: Object | null): Promise<BridgeHandlerResult> {
    const type = this.stringField(payload, 'type', 'image/*');
    if (type !== 'image/*') {
      return BridgeHandlerResult.failure(
        new BridgeError('E_INVALID_PAYLOAD', 'pickImage only supports type=image/*')
      );
    }

    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options = new photoAccessHelper.PhotoSelectOptions();
      options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      options.maxSelectNumber = 1;
      const result = await picker.select(options);
      if (!result.photoUris || result.photoUris.length === 0) {
        return BridgeHandlerResult.failure(
          new BridgeError('E_INTERNAL', 'launch canceled')  // 返回 E_INTERNAL 而非 E_CANCELED——E_CANCELED 为 JS 本地码，不跨端传输（docs/03 §8）
        );
      }
      return BridgeHandlerResult.success(new PickImagePayload(result.photoUris[0], type));
    } catch (_) {
      return BridgeHandlerResult.failure(
        new BridgeError('E_LAUNCH_FAILED', 'pickImage failed')
      );
    }
  }

  private async handleTimerLog(payload: Object | null, emitter: ResponseEmitter | null): Promise<void> {
    // ArkTS 的 throw 只接受 Error 类型，故错误帧经 emitter 显式发出（而非抛出 BridgeError）
    if (emitter === null) {
      throw new Error('stream emitter unavailable');
    }
    const action = this.stringField(payload, 'action', 'start');
    if (action === 'stop') {
      await this.stopTimerStream();
      await emitter(Result.success<Object, BridgeError>(new TimerStoppedPayload()), true);
      return;
    }
    if (action !== 'start') {
      await emitter(
        Result.failure<Object, BridgeError>(new BridgeError('E_INVALID_PAYLOAD', 'Timer action must be start or stop.')),
        true
      );
      return;
    }
    if (this.timerRunning) {
      await emitter(
        Result.failure<Object, BridgeError>(new BridgeError('E_INVALID_PAYLOAD', 'Timer is already running.')),
        true
      );
      return;
    }

    this.timerRunning = true;
    this.timerStreamEmitter = emitter;
    this.timerInterval = setInterval((): void => {
      if (!this.timerRunning || this.timerStreamEmitter === null) {
        return;
      }
      this.timerCounter += 1;
      const tick: TimerTickPayload = new TimerTickPayload(Date.now() % 100, this.timerCounter);
      void this.timerStreamEmitter(Result.success<Object, BridgeError>(tick), false);
    }, 1000);
  }

  private async stopTimerStream(): Promise<void> {
    if (this.timerInterval >= 0) {
      clearInterval(this.timerInterval);
      this.timerInterval = -1;
    }
    const emitter = this.timerStreamEmitter;
    const shouldEmitStop = this.timerRunning && emitter !== null;
    this.timerRunning = false;
    this.timerStreamEmitter = null;
    if (shouldEmitStop && emitter !== null) {
      await emitter(Result.success<Object, BridgeError>(new TimerStoppedPayload()), true);
    }
  }


  private sendToWeb(messageJson: string): boolean {
    try {
      console.info(`bridge sendToWeb ${messageJson}`);
      const script = `window.__jsbridge2__ && window.__jsbridge2__.receive && window.__jsbridge2__.receive(${JSON.stringify(messageJson)})`;
      this.controller.runJavaScript(script);
      return true;
    } catch (e) {
      return false;
    }
  }

  private async handleGetCurrentLocation(accuracy: string, timeoutMs: number): Promise<BridgeHandlerResult> {
    if (this.locationInFlight) {
      return BridgeHandlerResult.failure(new BridgeError('E_BUSY', 'location request is already in progress'));
    }
    this.locationInFlight = true;
    try {
      const permissionResult = await this.requestLocationPermission(accuracy);
      if (permissionResult !== null) {
        return BridgeHandlerResult.failure(permissionResult);
      }

      return await new Promise<BridgeHandlerResult>((resolve) => {
        let settled = false;
        const finalize = (result: BridgeHandlerResult): void => {
          if (settled) {
            return;
          }
          settled = true;
          resolve(result);
        };
        const timeoutId = setTimeout(() => {
          finalize(BridgeHandlerResult.failure(new BridgeError('E_INTERNAL', 'location request timeout')));  // 返回 E_INTERNAL 而非 E_TIMEOUT——E_TIMEOUT 为 JS 本地码，不跨端传输（docs/03 §8）
        }, timeoutMs > 0 ? timeoutMs : 10000);

        geoLocationManager.getCurrentLocation((error: BusinessError, location: geoLocationManager.Location): void => {
          clearTimeout(timeoutId);
          if (error) {
            finalize(BridgeHandlerResult.failure(
              new BridgeError('E_LOCATION_UNAVAILABLE', `location failed: ${error.message}`)
            ));
            return;
          }
          finalize(BridgeHandlerResult.success(
            new LocationPayload(location.latitude, location.longitude, location.accuracy, location.timeStamp)
          ));
        });
      });
    } finally {
      this.locationInFlight = false;
    }
  }

  private async requestLocationPermission(accuracy: string): Promise<BridgeError | null> {
    const permissions: Permissions[] = accuracy === 'fine'
      ? ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION']
      : ['ohos.permission.APPROXIMATELY_LOCATION'];
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const atManager = abilityAccessCtrl.createAtManager();

    try {
      const accessTokenId = context.applicationInfo.accessTokenId;
      const missingPermissions: Permissions[] = [];
      for (const permission of permissions) {
        const grantStatus = await atManager.checkAccessToken(accessTokenId, permission);
        if (grantStatus !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          missingPermissions.push(permission);
        }
      }
      if (missingPermissions.length === 0) {
        return null;
      }

      const result = await atManager.requestPermissionsFromUser(context, missingPermissions);
      const deniedIndexes: number[] = [];
      result.authResults.forEach((authResult: number, index: number): void => {
        if (authResult !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          deniedIndexes.push(index);
        }
      });
      if (deniedIndexes.length > 0) {
        const permanentlyDenied = deniedIndexes.some((index: number): boolean => {
          return result.dialogShownResults !== undefined &&
            index < result.dialogShownResults.length &&
            result.dialogShownResults[index] === false;
        });
        if (permanentlyDenied) {
          return new BridgeError(
            'E_PERMISSION_PERMANENTLY_DENIED',
            'location permission permanently denied',
            false,
            { 'canOpenSettings': true }
          );
        }
        return new BridgeError('E_PERMISSION_DENIED', 'location permission denied');
      }
      return null;
    } catch (e) {
      return new BridgeError('E_LAUNCH_FAILED', `permission request failed: ${e}`);
    }
  }

  private stringField(payload: Object | null, field: string, fallback: string): string {
    if (payload === null || typeof payload !== 'object') {
      return fallback;
    }
    const value = (payload as Record<string, Object>)[field];
    return typeof value === 'string' ? value : fallback;
  }

  private booleanField(payload: Object | null, field: string, fallback: boolean): boolean {
    if (payload === null || typeof payload !== 'object') {
      return fallback;
    }
    const value = (payload as Record<string, Object>)[field];
    return typeof value === 'boolean' ? value : fallback;
  }

  private numberField(payload: Object | null, field: string, fallback: number): number {
    if (payload === null || typeof payload !== 'object') {
      return fallback;
    }
    const value = (payload as Record<string, Object>)[field];
    return typeof value === 'number' ? value : fallback;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Text(`JsBridge Harmony Demo: ${this.status}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .width('100%')
          .backgroundColor('#F2F4F7')

        Web({
          src: $rawfile('web/index.html'),
          controller: this.controller
        })
          .javaScriptProxy({
            object: this.nativeBridge,
            name: 'NativeBridge',
            methodList: ['postMessage'],
            controller: this.controller
          })
          .onPageBegin(() => {
            this.status = 'page loading';
            this.bridge.resetPageInstance();
          })
          .onPageEnd(() => {
            this.status = 'page loaded';
            void this.lifecycleExtension.onHostEvent('ready');
          })
          .width('100%')
          .layoutWeight(1)
      }
      .width('100%')
      .height('100%')

      if (this.loadingVisible) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
          Text(this.loadingTitle)
            .fontSize(16)
            .fontColor(Color.White)
            .margin({ top: 12 })
          Text(this.loadingContent)
            .fontSize(13)
            .fontColor('#E6FFFFFF')
            .margin({ top: 6 })
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
      }
    }
    .width('100%')
    .height('100%')
  }
}
