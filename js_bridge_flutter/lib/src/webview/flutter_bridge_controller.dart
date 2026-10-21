import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:js_bridge_core/js_bridge_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../demo/pick_input_screen.dart';

class FlutterBridgeController with WidgetsBindingObserver {
  FlutterBridgeController({required this.navigatorKey})
      : bridge = JsBridge(
          securityConfig: SecurityConfig(
            allowedOrigins: <String>{'file://', 'flutter-asset://'},
            methodWhitelist: <String>{
              // methodWhitelist 语义为业务方法白名单，协议方法（bridge.handshake 等）由框架自动放行
              'getUser',
              'request',
              'timerLog',
              'showLoading',
              'pickImage',
              'pickInput',
              'getCurrentLocation',
            },
          ),
        ) {
    WidgetsBinding.instance.addObserver(this);
    bridge.attachPageContextProvider(
      _WebviewPageContextProvider(() => _currentUrl),
    );
    _registerHandlers();
    bridge.attachTransport((String messageJson) async {
      try {
        await _sendToWeb(messageJson);
        return true;
      } catch (_) {
        return false;
      }
    });
    _lifecycleExtension = LifecycleExtension(bridge);
    final Future<void> Function(String) onIncoming = bridge.bindTransport();
    webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'NativeBridge',
        onMessageReceived: (JavaScriptMessage message) {
          unawaited(onIncoming(message.message));
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            _currentUrl = url;
            bridge.resetPageInstance();
            unawaited(_lifecycleExtension.onHostEvent('created'));
          },
          onPageFinished: (String url) {
            _currentUrl = url;
          },
        ),
      );
  }

  final GlobalKey<NavigatorState> navigatorKey;
  final JsBridge bridge;
  late final WebViewController webViewController;
  late final LifecycleExtension _lifecycleExtension;
  String? _currentUrl;
  bool _loadingVisible = false;
  bool _timerRunning = false;
  int _timerCounter = 0;
  Timer? _activeTimer;
  ResponseEmitter? _timerStreamEmitter;
  /// 定位单飞守卫（与 Android `GetCurrentLocationPlugin.requesting` / iOS
  /// `locationResultCompletion` 同语义）：进行中再来一次 → E_BUSY，
  /// 避免 web 侧连续触发把并发定位压进平台定位栈。
  bool _locationRequestInFlight = false;
  final ImagePicker _imagePicker = ImagePicker();

  Future<void> load() {
    return webViewController.loadFlutterAsset('assets/web/index.html');
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final String mapped = switch (state) {
      AppLifecycleState.resumed => 'resumed',
      AppLifecycleState.inactive => 'paused',
      AppLifecycleState.hidden => 'stopped',
      AppLifecycleState.paused => 'stopped',
      AppLifecycleState.detached => 'destroyed',
    };
    unawaited(_lifecycleExtension.onHostEvent(mapped));
  }

  void _registerHandlers() {
    bridge.registerSimpleHandler('getUser', (TrustedPageContext context, dynamic payload) async {
      final Map<String, dynamic> object = _asMap(payload);
      final String? userId = object['userId'] as String?;
      if (userId == '001') {
        return const BridgeHandlerResult.success(<String, dynamic>{'name': 'xesam'});
      }
      return BridgeHandlerResult.failure(
        BridgeError(
          code: 'E_NOT_FOUND',
          message: 'user not found',
          details: <String, dynamic>{'userId': userId ?? ''},
        ),
      );
    });

    bridge.registerSimpleHandler('request', (TrustedPageContext context, dynamic payload) async {
      final Map<String, dynamic> object = _asMap(payload);
      final String? urlString = object['url'] as String?;
      if (urlString == null || urlString.isEmpty) {
        return const BridgeHandlerResult.failure(
          BridgeError(code: 'E_INVALID_PAYLOAD', message: 'request.url is required'),
        );
      }
      final Uri? uri = Uri.tryParse(urlString);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return const BridgeHandlerResult.failure(
          BridgeError(code: 'E_INVALID_PAYLOAD', message: 'request.url must be http/https'),
        );
      }
      try {
        final HttpClient client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
        final HttpClientRequest request = await client.getUrl(uri);
        final HttpClientResponse response = await request.close();
        final String body = await utf8.decoder.bind(response).join();
        client.close();
        return BridgeHandlerResult.success(<String, dynamic>{
          'code': response.statusCode,
          'body': body,
          'url': urlString,
        });
      } catch (error) {
        return BridgeHandlerResult.failure(
          BridgeError(code: 'E_REQUEST_FAILED', message: error.toString()),
        );
      }
    });

    // timerLog: 使用新的 AsyncHandler 实现真正的无限 streaming
    bridge.registerAsyncHandler('timerLog', (TrustedPageContext context, dynamic payload, ResponseEmitter? emitter) async {
      final Map<String, dynamic> object = _asMap(payload);
      final String action = (object['action'] as String?) ?? 'start';

      if (emitter == null) return;

      if (action == 'stop') {
        if (!_timerRunning) {
          await emitter(
            const Result<dynamic, BridgeError>.success(
              <String, dynamic>{'event': 'stopped', 'running': false},
            ),
            true,
          );
          return;
        }
        _timerRunning = false;
        _activeTimer?.cancel();
        _activeTimer = null;
        final ResponseEmitter? previousStreamEmitter = _timerStreamEmitter;
        _timerStreamEmitter = null;
        if (previousStreamEmitter != null) {
          await previousStreamEmitter(
            const Result<dynamic, BridgeError>.success(
              <String, dynamic>{'event': 'stopped', 'running': false},
            ),
            true,
          );
        }
        await emitter(
          const Result<dynamic, BridgeError>.success(
            <String, dynamic>{'event': 'stopped', 'running': false},
          ),
          true,
        );
        return;
      }

      if (_timerRunning) {
        await emitter(
          const Result<dynamic, BridgeError>.failure(
            BridgeError(
              code: 'E_INVALID_PAYLOAD',
              message: 'Timer is already running.',
            ),
          ),
          true,
        );
        return;
      }

      _timerRunning = true;
      // 持有 start 请求的流 emitter，stop 时向它补发 stopped 终止帧（对齐 Android TimerExt / HarmonyOS）
      _timerStreamEmitter = emitter;

      // 启动后台 Timer 实现真正的无限 streaming
      _activeTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) async {
        if (!_timerRunning) {
          timer.cancel();
          _activeTimer = null;
          return;
        }

        _timerCounter += 1;
        await emitter(
          Result<dynamic, BridgeError>.success(
            <String, dynamic>{
              'event': 'tick',
              'value': DateTime.now().millisecondsSinceEpoch % 100,
              'seq': _timerCounter,
              'running': true,
            },
          ),
          false,
        );
      });
    });

    bridge.registerSimpleHandler('showLoading', (TrustedPageContext context, dynamic payload) async {
      final Map<String, dynamic> object = _asMap(payload);
      final BuildContext? context = navigatorKey.currentContext;
      if (context == null) {
        return const BridgeHandlerResult.failure(
          BridgeError(code: 'E_INTERNAL', message: 'navigator context unavailable'),
        );
      }
      if (_loadingVisible) {
        Navigator.of(context, rootNavigator: true).pop();
        _loadingVisible = false;
      }
      final String title = (object['title'] as String?) ?? 'Loading';
      final String content = (object['content'] as String?) ?? 'Please wait...';
      final int durationMs = (object['durationMs'] as num?)?.toInt() ?? 1200;

      _loadingVisible = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: Text(title),
            content: Row(
              children: <Widget>[
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(content)),
              ],
            ),
          );
        },
      );
      Future<void>.delayed(Duration(milliseconds: math.max(300, durationMs)), () {
        final NavigatorState? navigator = navigatorKey.currentState;
        if (_loadingVisible && navigator != null) {
          navigator.pop();
          _loadingVisible = false;
        }
      });
      return BridgeHandlerResult.success(<String, dynamic>{
        'status': 'shown',
        'native': true,
        'durationMs': durationMs,
      });
    });

    bridge.registerSimpleHandler('pickInput', (TrustedPageContext context, dynamic payload) async {
      final BuildContext? context = navigatorKey.currentContext;
      if (context == null) {
        return const BridgeHandlerResult.failure(
          BridgeError(code: 'E_INTERNAL', message: 'navigator context unavailable'),
        );
      }
      final BridgeHandlerResult? result = await Navigator.of(context).push<BridgeHandlerResult>(
        MaterialPageRoute<BridgeHandlerResult>(
          builder: (BuildContext context) => const PickInputScreen(),
        ),
      );
      return result ?? const BridgeHandlerResult.failure(
        BridgeError(code: 'E_INTERNAL', message: 'launch canceled'),  // 返回 E_INTERNAL 而非 E_CANCELED——E_CANCELED 为 JS 本地码，不跨端传输（docs/03 §8）
      );
    });

    bridge.registerSimpleHandler('pickImage', (TrustedPageContext context, dynamic payload) async {
      try {
        final XFile? file = await _imagePicker.pickImage(
          source: ImageSource.gallery,
        );
        if (file == null) {
          return const BridgeHandlerResult.failure(
            BridgeError(code: 'E_INTERNAL', message: 'launch canceled'),  // 返回 E_INTERNAL 而非 E_CANCELED——E_CANCELED 为 JS 本地码，不跨端传输（docs/03 §8）
          );
        }
        return BridgeHandlerResult.success(<String, dynamic>{
          'uri': file.path,
          'type': 'image/*',
          'source': 'photo-library',
          'native': true,
        });
      } catch (error) {
        return BridgeHandlerResult.failure(
          BridgeError(code: 'E_LAUNCH_FAILED', message: error.toString()),
        );
      }
    });

    bridge.registerSimpleHandler('getCurrentLocation', (TrustedPageContext context, dynamic payload) async {
      final Map<String, dynamic> object = _asMap(payload);
      final String accuracy = (object['accuracy'] as String?) ?? 'coarse';
      final int timeoutMs = (object['timeoutMs'] as num?)?.toInt() ?? 10000;
      if (_locationRequestInFlight) {
        return const BridgeHandlerResult.failure(
          BridgeError(
            code: 'E_BUSY',
            message: 'location request is already in progress',
          ),
        );
      }
      _locationRequestInFlight = true;
      // 权限先行（对齐 Android / HarmonyOS 参考实现）；unableToDetermine 亦触发弹框
      // （iOS notDetermined 映射为此值，跳过会让权限永不落地）。
      // 不做 isLocationServiceEnabled 预门控：fused usable 标志受授权/GMS 状态影响，
      // CN-ROM 授权后仍可能返回 false；开关真实关闭由下方 LocationServiceDisabledException 兜底。
      try {
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.unableToDetermine) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied) {
          return const BridgeHandlerResult.failure(
            BridgeError(
              code: 'E_PERMISSION_DENIED',
              message: 'Location permission denied',
            ),
          );
        }
        if (permission == LocationPermission.deniedForever) {
          return BridgeHandlerResult.failure(
            BridgeError(
              code: 'E_PERMISSION_PERMANENTLY_DENIED',
              message: 'Location permission permanently denied',
              details: <String, dynamic>{'canOpenSettings': true},
            ),
          );
        }

        // 最近一次定位快路径（与 Android findLastKnownLocation / iOS manager.location 对齐）：
        // 命中即返回，不等新解——否则"当前无可用新解"（室内/冷启动）必然等满原生预算，
        // 而原生预算不短于 JS 声明时限时，用户只会看到 JS 侧的 E_TIMEOUT。
        // Position 不暴露底层 provider 名，故 coarse/fine 共用同一次最近定位查询
        // （Android 侧按精度分摊 GPS/NETWORK/PASSIVE 的取舍在此不适用）。
        try {
          final Position? lastKnown = await Geolocator.getLastKnownPosition();
          if (lastKnown != null) {
            return BridgeHandlerResult.success(_locationPayload(lastKnown));
          }

          // Android 强制 LocationManager 路径（对齐参考实现）：
          // CN-ROM 的 GMS fused 路径不可靠（实测授权后仍失败/挂起）。
          final LocationSettings settings = Platform.isAndroid
              ? AndroidSettings(
                  accuracy: accuracy == 'fine'
                      ? LocationAccuracy.best
                      : LocationAccuracy.medium,
                  timeLimit: Duration(milliseconds: timeoutMs),
                  forceLocationManager: true,
                )
              : LocationSettings(
                  accuracy: accuracy == 'fine'
                      ? LocationAccuracy.best
                      : LocationAccuracy.medium,
                  timeLimit: Duration(milliseconds: timeoutMs),
                );
          final Position position = await Geolocator.getCurrentPosition(
            locationSettings: settings,
          );
          return BridgeHandlerResult.success(_locationPayload(position));
        } on TimeoutException {
          return const BridgeHandlerResult.failure(
            BridgeError(code: 'E_INTERNAL', message: 'Location request timeout'),  // 返回 E_INTERNAL 而非 E_TIMEOUT——E_TIMEOUT 为 JS 本地码，不跨端传输（docs/03 §8）
          );
        } on PermissionDeniedException {
          return const BridgeHandlerResult.failure(
            BridgeError(code: 'E_PERMISSION_DENIED', message: 'Location permission denied'),
          );
        } on LocationServiceDisabledException {
          return const BridgeHandlerResult.failure(
            BridgeError(code: 'E_LOCATION_UNAVAILABLE', message: 'Location services disabled'),
          );
        } catch (error) {
          return BridgeHandlerResult.failure(
            BridgeError(
              code: 'E_LOCATION_UNAVAILABLE',
              message: error.toString(),
            ),
          );
        }
      } finally {
        _locationRequestInFlight = false;
      }
    });
  }

  /// 定位响应 payload——字段集与 Android `toPayload` / iOS 响应体一致。
  /// provider 报告**来源**而非请求精度：`Position` 不暴露底层 provider 名，
  /// 故给出插件来源标签（对照 iOS 的 'core-location' / 'simulated'）。
  static Map<String, dynamic> _locationPayload(Position position) {
    return <String, dynamic>{
      'lat': position.latitude,
      'lng': position.longitude,
      'accuracy': position.accuracy,
      'provider': position.isMocked ? 'simulated' : 'geolocator',
      'timestamp': position.timestamp.millisecondsSinceEpoch,
    };
  }

  Future<void> _sendToWeb(String messageJson) {
    final String escaped = jsonEncode(messageJson);
    return webViewController.runJavaScript(
      'window.__jsbridge2__ && window.__jsbridge2__.receive && window.__jsbridge2__.receive($escaped)',
    );
  }

  static Map<String, dynamic> _asMap(dynamic payload) {
    if (payload is Map<String, dynamic>) {
      return payload;
    }
    if (payload is Map) {
      return payload.cast<String, dynamic>();
    }
    return const <String, dynamic>{};
  }
}

class _WebviewPageContextProvider implements PageContextProvider {
  _WebviewPageContextProvider(this._currentUrlGetter);

  final String? Function() _currentUrlGetter;

  @override
  TrustedPageContext createContext(BridgeMessage message, String pageInstanceId) {
    // origin 必须经由核心层归一化函数派生（docs/03 §9 细则 5，验收锚点 C54）：
    // file:///... → 'file://'，flutter-asset:///... → 'flutter-asset://'；
    // 非层级形态（about:blank 等）与无法解析/未加载（null）时归一化为空串
    // （fail-closed，永不命中白名单）。
    return TrustedPageContext(
      origin: OriginNormalizer.normalize(_currentUrlGetter()),
      pageInstanceId: pageInstanceId,
    );
  }
}
