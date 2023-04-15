import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { http } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import {
  BridgeError,
  BridgeMessage,
  BridgeMessageKind,
  BridgeHandlerResult,
  JsBridgeOptions,
  JsBridge,
  PageContextProvider,
  TrustedPageContext,
  StreamingResultEmitter,
  LifecycleExtension
} from '@xesam/js_bridge_core';

const PAGE_ORIGIN = 'file://';

class FilePageContextProvider implements PageContextProvider {
  createContext(message: BridgeMessage, pageInstanceId: string): TrustedPageContext {
    return new TrustedPageContext(PAGE_ORIGIN, pageInstanceId);
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
  @State pickInputVisible: boolean = false;
  @State pickInputName: string = '';
  @State pickInputAge: string = '';
  private pickInputResolve: ((result: BridgeHandlerResult) => void) | null = null;
  private loadingTimer: number = -1;
  private timerRunning: boolean = false;
  private timerCounter: number = 0;
  private timerInterval: number = -1;
  private timerStreamEmitter: StreamingResultEmitter | null = null;
  private locationInFlight: boolean = false;

  aboutToAppear(): void {
    this.bridge.resetForNewPage();
    void this.lifecycleExtension.onHostEvent('created');
  }

  onPageShow(): void {
    void this.lifecycleExtension.onHostEvent('foreground');
  }

  onPageHide(): void {
    void this.lifecycleExtension.onHostEvent('background');
  }

  private createBridge(): JsBridge {
    const options: JsBridgeOptions = {
      allowedOrigins: new Set<string>([PAGE_ORIGIN]),
      methodWhitelist: new Set<string>([
        'bridge.handshake',
        'getUser',
        'request',
        'timerLog',
        'showLoading',
        'pickImage',
        'pickInput',
        'getCurrentLocation'
      ]),
      defaultCapabilities: new Set<string>([
        'getUser',
        'request',
        'timerLog',
        'showLoading',
        'pickImage',
        'pickInput',
        'getCurrentLocation'
      ]),
      transport: (messageJson: string): boolean => this.sendToWeb(messageJson),
      pageContextProvider: new FilePageContextProvider()
    };
    const bridge = JsBridge.secure(options);

    bridge.registerHandler('getUser', () => BridgeHandlerResult.failure(
      new BridgeError('E_UNSUPPORTED', 'getUser requires a host-provided account service')
    ));
    bridge.registerHandler('request', async (payload) => this.handleRequest(payload));
    bridge.registerStreamingHandler('timerLog', async (payload, emit) => this.handleTimerLog(payload, emit));
    bridge.registerHandler('showLoading', (payload) => {
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
    bridge.registerHandler('pickImage', async (payload) => this.handlePickImage(payload));
    bridge.registerHandler('pickInput', () => this.handlePickInput());
    bridge.registerHandler('getCurrentLocation', async (payload) => {
      return this.handleGetCurrentLocation(
        this.stringField(payload, 'accuracy', 'coarse'),
        this.numberField(payload, 'timeoutMs', 10000)
      );
    });

    return bridge;
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

  private handlePickInput(): Promise<BridgeHandlerResult> {
    if (this.pickInputResolve !== null) {
      return Promise.resolve(BridgeHandlerResult.failure(new BridgeError('E_BUSY', 'pickInput is already in progress')));
    }
    this.pickInputName = '';
    this.pickInputAge = '';
    this.pickInputVisible = true;
    return new Promise<BridgeHandlerResult>((resolve) => {
      this.pickInputResolve = resolve;
    });
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
          new BridgeError('E_CANCELED', 'launch canceled')
        );
      }
      return BridgeHandlerResult.success(new PickImagePayload(result.photoUris[0], type));
    } catch (_) {
      return BridgeHandlerResult.failure(
        new BridgeError('E_LAUNCH_FAILED', 'pickImage failed')
      );
    }
  }

  private async handleTimerLog(payload: Object | null, emit?: StreamingResultEmitter): Promise<BridgeHandlerResult[]> {
    const action = this.stringField(payload, 'action', 'start');
    if (action === 'stop') {
      await this.stopTimerStream();
      return [
        BridgeHandlerResult.success(new TimerStoppedPayload(), true)
      ];
    }
    if (action !== 'start') {
      return [
        BridgeHandlerResult.failure(new BridgeError('E_INVALID_PAYLOAD', 'Timer action must be start or stop.'))
      ];
    }
    if (this.timerRunning) {
      return [
        BridgeHandlerResult.failure(new BridgeError('E_INVALID_PAYLOAD', 'Timer is already running.'))
      ];
    }
    if (emit === undefined) {
      return [
        BridgeHandlerResult.failure(new BridgeError('E_INTERNAL', 'stream emitter unavailable'))
      ];
    }

    this.timerRunning = true;
    this.timerStreamEmitter = emit;
    this.timerInterval = setInterval((): void => {
      if (!this.timerRunning || this.timerStreamEmitter === null) {
        return;
      }
      this.timerCounter += 1;
      void this.timerStreamEmitter(BridgeHandlerResult.success(
        new TimerTickPayload(Date.now() % 100, this.timerCounter),
        false
      ));
    }, 1000);
    return [];
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
    if (shouldEmitStop) {
      await emitter(BridgeHandlerResult.success(new TimerStoppedPayload(), true));
    }
  }

  private completePickInput(result: BridgeHandlerResult): void {
    const resolve = this.pickInputResolve;
    this.pickInputResolve = null;
    this.pickInputVisible = false;
    if (resolve !== null) {
      resolve(result);
    }
  }

  private confirmPickInput(): void {
    const name = this.pickInputName.trim();
    const age = Number(this.pickInputAge.trim());
    if (name.length === 0 || !Number.isInteger(age) || age < 0) {
      this.completePickInput(BridgeHandlerResult.failure(
        new BridgeError('E_INVALID_PAYLOAD', 'name is required and age must be a non-negative integer')
      ));
      return;
    }
    this.completePickInput(BridgeHandlerResult.success(new InputPayload(name, age)));
  }

  private sendToWeb(messageJson: string): boolean {
    try {
      console.info(`bridge sendToWeb ${messageJson}`);
      const script = `window.__bridgeReceiveFromNative && window.__bridgeReceiveFromNative(${JSON.stringify(messageJson)})`;
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
          finalize(BridgeHandlerResult.failure(new BridgeError('E_TIMEOUT', 'location request timeout', true)));
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
            this.bridge.resetForNewPage();
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

      if (this.pickInputVisible) {
        Column() {
          Text('Pick Input')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 16 })
          TextInput({ placeholder: 'name', text: this.pickInputName })
            .onChange((value: string) => {
              this.pickInputName = value;
            })
            .margin({ bottom: 12 })
          TextInput({ placeholder: 'age', text: this.pickInputAge })
            .type(InputType.Number)
            .onChange((value: string) => {
              this.pickInputAge = value;
            })
            .margin({ bottom: 16 })
          Row() {
            Button('Cancel')
              .onClick(() => {
                this.completePickInput(BridgeHandlerResult.failure(
                  new BridgeError('E_CANCELED', 'launch canceled')
                ));
              })
              .margin({ right: 12 })
            Button('OK')
              .onClick(() => {
                this.confirmPickInput();
              })
          }
          .justifyContent(FlexAlign.End)
          .width('100%')
        }
        .padding(20)
        .width('82%')
        .backgroundColor(Color.White)
        .borderRadius(16)
        .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: 8 })
        .position({ x: '9%', y: '28%' })
      }
    }
    .width('100%')
    .height('100%')
  }
}
