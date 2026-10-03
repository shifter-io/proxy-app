import 'package:flutter/material.dart';

import 'state/app_controller.dart';
import 'theme/theme.dart';
import 'ui/shell/app_root.dart';

/// One complete app instance. The preview studio runs several of these side
/// by side, each with its own state, inside simulated device screens.
class ShifterApp extends StatefulWidget {
  const ShifterApp({super.key, this.demoKey, this.demoConnected = false});

  /// Preview only: start signed in with this mock API key.
  final String? demoKey;

  /// Preview only: start connected.
  final bool demoConnected;

  @override
  State<ShifterApp> createState() => _ShifterAppState();
}

class _ShifterAppState extends State<ShifterApp> {
  late final controller = AppController(demoKey: widget.demoKey, demoConnected: widget.demoConnected);

  @override
  void dispose() {
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
        home: const AppRoot(),
      ),
    );
  }
}
