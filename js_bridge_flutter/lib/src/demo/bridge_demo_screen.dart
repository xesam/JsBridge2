import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app/flutter_x_app.dart';
import '../webview/flutter_bridge_controller.dart';

class BridgeDemoScreen extends StatefulWidget {
  const BridgeDemoScreen({super.key});

  @override
  State<BridgeDemoScreen> createState() => _BridgeDemoScreenState();
}

class _BridgeDemoScreenState extends State<BridgeDemoScreen> {
  late final FlutterBridgeController _bridgeController;

  @override
  void initState() {
    super.initState();
    _bridgeController = FlutterBridgeController(
      navigatorKey: FlutterXApp.navigatorKey,
    );
    _bridgeController.load();
  }

  @override
  void dispose() {
    _bridgeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[Color(0xFF06141A), Color(0xFF0F2C33)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: WebViewWidget(controller: _bridgeController.webViewController),
        ),
      ),
    );
  }
}
