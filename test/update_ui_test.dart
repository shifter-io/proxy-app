import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/state/app_controller.dart';
import 'package:shifter_app/theme/theme.dart';
import 'package:shifter_app/ui/update/update_host.dart';
import 'package:shifter_app/update/update_coordinator.dart';
import 'package:shifter_app/update/update_models.dart';
import 'package:shifter_app/update/update_store.dart';

import 'update_coordinator_test.dart' show FakeAdapter, FakeRepository;
import 'update_security_test.dart' show identity, releaseJson;

void main() {
  for (final width in [280.0, 393.0, 1100.0]) {
    testWidgets(
      'update modal survives navigation at width $width and enlarged text',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final app = AppController();
        final store = UpdateStore(null);
        final u = UpdateCoordinator(
          store: store,
          adapter: FakeAdapter(),
          identity: identity,
          repository: FakeRepository(store),
          prepareConnection: app.prepareForUpdate,
          canPrompt: () => false,
          capabilities: const UpdateCapabilities(
            download: true,
            cancel: true,
            install: true,
          ),
        );
        u.release = Release(releaseJson());
        u.phase = UpdatePhase.available;
        final navigator = GlobalKey<NavigatorState>();
        final boundary = GlobalKey();
        await tester.pumpWidget(
          AppScope(
            controller: app,
            child: MaterialApp(
              navigatorKey: navigator,
              theme: buildShifterTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.6)),
                child: RepaintBoundary(
                  key: boundary,
                  child: UpdateHost(
                    app: app,
                    enabled: false,
                    navigatorKey: navigator,
                    initialCoordinator: u,
                    child: child!,
                  ),
                ),
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: UpdateScope.of(context)!.open,
                      child: const Text('About / App updates'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.text('About / App updates'));
        await tester.pumpAndSettle();
        expect(find.text('Download update'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (width == 393) {
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '../reports/app-updates-evidence/update-modal-phone.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const UpdateBackGuard(
              child: Scaffold(body: Text('Another account route')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Download update'), findsOneWidget);
        if (width == 280) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        }
        await tester.pumpAndSettle();
        expect(find.text('Download update'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
      },
    );
  }
}
