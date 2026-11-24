import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/http_api.dart';
import 'data/models.dart';
import 'data/store.dart';
import 'proxy/proxy_engine.dart';
import 'state/app_controller.dart';
import 'theme/theme.dart';
import 'theme/tokens.dart';
import 'ui/shell/app_root.dart';
import 'ui/update/update_host.dart';
import 'ui/widgets/ambient_motion.dart';

/// One complete app instance. The preview studio runs several of these side
/// by side, each with its own state, inside simulated device screens.
class ShifterApp extends StatefulWidget {
  const ShifterApp({
    super.key,
    this.demoKey,
    this.demoConnected = false,
    this.live = false,
  });

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
  bool get _desktopUpdates =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  static const _desktop = MethodChannel('io.shifter.desktop');
  bool get _desktopEnabled =>
      widget.live && (Platform.isMacOS || Platform.isWindows);

  void _sendConnectionState() {
    final status = switch (controller.connection.status) {
      ConnectionStatus.connected => 'Connected',
      ConnectionStatus.connecting => 'Connecting',
      ConnectionStatus.disconnected => 'Disconnected',
      ConnectionStatus.error => 'Connection error',
    };
    unawaited(
      _desktop
          .invokeMethod<void>('connection', {
            'status': status,
            'canConnect':
                controller.phase == AuthPhase.signedIn &&
                controller.activeMembership != null &&
                controller.canConnect &&
                !controller.isConnecting,
          })
          .catchError((Object _) {}),
    );
  }

  final _navigatorKey = GlobalKey<NavigatorState>();

  AppController _create() {
    if (!widget.live) {
      return AppController(
        demoKey: widget.demoKey,
        demoConnected: widget.demoConnected,
      );
    }
    final store = PersistentStore();
    return AppController(
      api: HttpShifterApi(store: store),
      store: store,
      engine: ProxyEngine.forPlatform(store),
      suppressUpdateReconnect: true,
    );
  }

  @override
  void initState() {
    super.initState();
    if (_desktopEnabled) {
      _desktop.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'toggleConnection':
            if (controller.isConnected ||
                (controller.phase == AuthPhase.signedIn &&
                    controller.canConnect &&
                    !controller.isConnecting)) {
              await controller.toggleConnection();
            }
          case 'shutdown':
            await controller.shutdown();
          default:
            throw MissingPluginException();
        }
      });
      controller.addListener(_sendConnectionState);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sendConnectionState();
      });
    }
    // Quitting while connected: put the OS proxy settings back first.
    if (widget.live) {
      _lifecycle = AppLifecycleListener(
        onExitRequested: () async {
          try {
            await controller.shutdown();
            return AppExitResponse.exit;
          } catch (_) {
            return AppExitResponse.cancel;
          }
        },
      );
    }
  }

  @override
  void dispose() {
    if (_desktopEnabled) {
      controller.removeListener(_sendConnectionState);
      _desktop.setMethodCallHandler(null);
    }
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
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: buildShifterTheme(),
        // Paint behind route fades too, so the native surface never shows
        // through while switching from startup to login or the account.
        builder: (context, child) {
          final content = ColoredBox(color: Sf.bgDeepest, child: child!);
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarDividerColor: Colors.transparent,
              systemNavigationBarIconBrightness: Brightness.light,
              systemNavigationBarContrastEnforced: false,
            ),
            child: _desktopUpdates
                ? UpdateHost(
                    app: controller,
                    enabled: widget.live,
                    navigatorKey: _navigatorKey,
                    child: content,
                  )
                : content,
          );
        },
        home: const UpdateBackGuard(
          child: AmbientMotionScope(child: AppRoot()),
        ),
      ),
    );
  }
}
