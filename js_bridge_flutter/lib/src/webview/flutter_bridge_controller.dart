import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:js_bridge_core/js_bridge_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

class FlutterBridgeController with WidgetsBindingObserver {
  FlutterBridgeController({required this.navigatorKey})
      : bridge = JsBridge(
          securityConfig: SecurityConfig.secure()
            ..allowedOrigins = <String>{'file://', 'flutter-asset://', 'about:blank'}
            ..methodWhitelist = <String>{
              'bridge.handshake',
              'getUser',
              'request',
              'timerLog',
              'showLoading',
              'pickImage',
              'pickInput',
              'getCurrentLocation',
            }
            ..defaultCapabilities = <String>{
              'getUser',
              'request',
              'timerLog',
              'showLoading',
              'pickImage',
              'pickInput',
              'getCurrentLocation',
            },
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
            bridge.resetForNewPage();
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
  String _currentUrl = 'about:blank';
  bool _loadingVisible = false;
  bool _timerRunning = false;
  int _timerCounter = 0;
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
    bridge.registerHandler('getUser', (dynamic payload) async {
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

    bridge.registerHandler('request', (dynamic payload) async {
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

    bridge.registerStreamingHandler('timerLog', (dynamic payload) async {
      final Map<String, dynamic> object = _asMap(payload);
      final String action = (object['action'] as String?) ?? 'start';
      if (action == 'stop') {
        _timerRunning = false;
        return const <BridgeHandlerResult>[
          BridgeHandlerResult.success(
            <String, dynamic>{'event': 'stopped', 'running': false},
          ),
        ];
      }
      if (_timerRunning) {
        return const <BridgeHandlerResult>[
          BridgeHandlerResult.failure(
            BridgeError(
              code: 'E_INVALID_PAYLOAD',
              message: 'Timer is already running.',
            ),
          ),
        ];
      }
      _timerRunning = true;
      final List<BridgeHandlerResult> stream = <BridgeHandlerResult>[];
      for (int i = 0; i < 3; i += 1) {
        _timerCounter += 1;
        stream.add(
          BridgeHandlerResult.success(
            <String, dynamic>{
              'event': 'tick',
              'value': DateTime.now().millisecondsSinceEpoch % 100,
              'seq': _timerCounter,
              'running': true,
            },
            done: false,
          ),
        );
      }
      _timerRunning = false;
      stream.add(
        const BridgeHandlerResult.success(
          <String, dynamic>{'event': 'stopped', 'running': false},
        ),
      );
      return stream;
    });

    bridge.registerHandler('showLoading', (dynamic payload) async {
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
      Future<void>.delayed(const Duration(milliseconds: 1200), () {
        final NavigatorState? navigator = navigatorKey.currentState;
        if (_loadingVisible && navigator != null) {
          navigator.pop();
          _loadingVisible = false;
        }
      });
      return const BridgeHandlerResult.success(<String, dynamic>{
        'status': 'shown',
        'native': true,
      });
    });

    bridge.registerHandler('pickInput', (dynamic payload) async {
      final BuildContext? context = navigatorKey.currentContext;
      if (context == null) {
        return const BridgeHandlerResult.failure(
          BridgeError(code: 'E_INTERNAL', message: 'navigator context unavailable'),
        );
      }
      final TextEditingController nameController =
          TextEditingController(text: 'flutter-user');
      final TextEditingController ageController =
          TextEditingController(text: '18');
      final Completer<BridgeHandlerResult> completer =
          Completer<BridgeHandlerResult>();
      showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: const Text('Pick Input'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'name'),
                ),
                TextField(
                  controller: ageController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'age'),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  completer.complete(
                    const BridgeHandlerResult.failure(
                      BridgeError(code: 'E_CANCELED', message: 'launch canceled'),
                    ),
                  );
                },
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final int? age = int.tryParse(ageController.text.trim());
                  if (nameController.text.trim().isEmpty) {
                    Navigator.of(dialogContext).pop();
                    completer.complete(
                      const BridgeHandlerResult.failure(
                        BridgeError(
                          code: 'E_INVALID_PAYLOAD',
                          message: 'name is required',
                        ),
                      ),
                    );
                    return;
                  }
                  if (age == null) {
                    Navigator.of(dialogContext).pop();
                    completer.complete(
                      const BridgeHandlerResult.failure(
                        BridgeError(
                          code: 'E_INVALID_PAYLOAD',
                          message: 'age must be number',
                        ),
                      ),
                    );
                    return;
                  }
                  Navigator.of(dialogContext).pop();
                  completer.complete(
                    BridgeHandlerResult.success(<String, dynamic>{
                      'name': nameController.text.trim(),
                      'age': age,
                      'native': true,
                    }),
                  );
                },
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
      return completer.future;
    });

    bridge.registerHandler('pickImage', (dynamic payload) async {
      try {
        final XFile? file = await _imagePicker.pickImage(
          source: ImageSource.gallery,
        );
        if (file == null) {
          return const BridgeHandlerResult.failure(
            BridgeError(code: 'E_CANCELED', message: 'launch canceled'),
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

    bridge.registerHandler('getCurrentLocation', (dynamic payload) async {
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
          BridgeError(code: 'E_TIMEOUT', message: 'Location request timeout'),
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
      'window.__bridgeReceiveFromNative && window.__bridgeReceiveFromNative($escaped)',
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

  static String _normalizeOrigin(String rawUrl) {
    final Uri? uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      return 'about:blank';
    }
    if (uri.scheme == 'file') {
      return 'file://';
    }
    if (uri.scheme.startsWith('flutter')) {
      return '${uri.scheme}://';
    }
    if (uri.scheme == 'about') {
      return 'about:blank';
    }
    return '${uri.scheme}://${uri.host}';
  }
}

class _WebviewPageContextProvider implements PageContextProvider {
  _WebviewPageContextProvider(this._currentUrlGetter);

  final String Function() _currentUrlGetter;

  @override
  TrustedPageContext createContext(BridgeMessage message, String pageInstanceId) {
    return TrustedPageContext(
      origin: FlutterBridgeController._normalizeOrigin(_currentUrlGetter()),
      pageInstanceId: pageInstanceId,
    );
  }
}
