import 'package:flutter/material.dart';

import '../demo/bridge_demo_screen.dart';

class FlutterXApp extends StatelessWidget {
  const FlutterXApp({super.key});

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'JsBridge Flutter Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF06141A),
        useMaterial3: true,
      ),
      home: const BridgeDemoScreen(),
    );
  }
}
