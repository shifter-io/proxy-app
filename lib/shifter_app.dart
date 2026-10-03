import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'data/http_api.dart';
import 'data/store.dart';
import 'proxy/proxy_engine.dart';
import 'state/app_controller.dart';
import 'theme/theme.dart';
import 'ui/shell/app_root.dart';
import 'ui/widgets/ambient_motion.dart';

/// One complete app instance. The preview studio runs several of these side
/// by side, each with its own state, inside simulated device screens.
class ShifterApp extends StatefulWidget {
  const ShifterApp({super.key, this.demoKey, this.demoConnected = false, this.live = false});

  /// The real app: shifter.io API, keychain storage, and the local proxy
  /// routing this device. Off in the preview studio and tests (mock data).
  final bool live;

  /// Preview only: start signed in with this mock API key.
  final String? demoKey;

  /// Preview only: start connected.
  final bool demoConnected;

  @override
  State<ShifterApp> createState() => _ShifterAppState();
}

class _ShifterAppState extends State<ShifterApp> {
  late final AppController controller = _create();
  AppLifecycleListener? _lifecycle;

  AppController _create() {
    if (!widget.live) return AppController(demoKey: widget.demoKey, demoConnected: widget.demoConnected);
    final store = PersistentStore();
    return AppController(api: HttpShifterApi(store: store), store: store, engine: LocalProxyEngine(store));
  }

  @override
  void initState() {
    super.initState();
    // Quitting while connected: put the OS proxy settings back first.
    if (widget.live) {
      _lifecycle = AppLifecycleListener(onExitRequested: () async {
        await controller.shutdown().timeout(const Duration(seconds: 8), onTimeout: () {});
        return AppExitResponse.exit;
      });
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AppScope sits above MaterialApp so pushed routes, sheets and dialogs
    // all see the same controller.
    return AppScope(
      controller: controller,
      child: MaterialApp(
        title: 'Shifter',
        debugShowCheckedModeBanner: false,
        theme: buildShifterTheme(),
        home: const AmbientMotionScope(child: AppRoot()),
      ),
    );
  }
}
