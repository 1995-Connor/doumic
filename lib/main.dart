import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import 'mic/mic_bridge.dart';
import 'state/recorder_controller.dart';
import 'theme/app_theme.dart';
import 'ui/screens/mic_bridge_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    try {
      await FlutterBluePlus.setOptions(restoreState: true);
    } catch (error) {
      debugPrint('[BLE] State restoration setup failed: $error');
    }
  }
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  final controller = RecorderController();
  // DouMic is a mic bridge only — never auto-run cloud transcription.
  controller.setAutoTranscribe(false);

  unawaited(MicBridge.instance.ensureInitialized());
  runApp(DouMicApp(controller: controller));
}

/// Standalone virtual-mic app for the Anker D3200. Not a recording manager.
class DouMicApp extends StatelessWidget {
  const DouMicApp({super.key, required this.controller});

  final RecorderController controller;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: controller),
        ChangeNotifierProvider<MicBridge>.value(value: MicBridge.instance),
      ],
      child: MaterialApp(
        title: '豆麦',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: const MicBridgeScreen(),
      ),
    );
  }
}
