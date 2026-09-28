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
        _timerRunning = false;
        _activeTimer?.cancel();
        _activeTimer = null;
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

      // 启动后台 Timer 实现真正的无限 streaming
      _activeTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) async {
        if (!_timerRunning) {
          timer.cancel();
          _activeTimer = null;
          await emitter(
            const Result<dynamic, BridgeError>.success(
              <String, dynamic>{'event': 'stopped', 'running': false},
            ),
            true,
          );
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
      final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return const BridgeHandlerResult.failure(
          BridgeError(
            code: 'E_LOCATION_UNAVAILABLE',
            message: 'Location services disabled',
          ),
        );
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
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

      try {
        final LocationSettings settings = LocationSettings(
          accuracy: accuracy == 'fine'
              ? LocationAccuracy.best
              : LocationAccuracy.medium,
          timeLimit: Duration(milliseconds: timeoutMs),
        );
        final Position position = await Geolocator.getCurrentPosition(
          locationSettings: settings,
        );
        return BridgeHandlerResult.success(<String, dynamic>{
          'lat': position.latitude,
          'lng': position.longitude,
          'accuracy': position.accuracy,
          'provider': accuracy == 'fine' ? 'fine' : 'coarse',
          'timestamp':
              position.timestamp.millisecondsSinceEpoch,
        });
      } on TimeoutException {
        return const BridgeHandlerResult.failure(
          BridgeError(code: 'E_INTERNAL', message: 'Location request timeout'),  // 返回 E_INTERNAL 而非 E_TIMEOUT——E_TIMEOUT 为 JS 本地码，不跨端传输（docs/03 §8）
        );
      } catch (error) {
        return BridgeHandlerResult.failure(
          BridgeError(
            code: 'E_LOCATION_UNAVAILABLE',
            message: error.toString(),
          ),
        );
      }
    });
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
