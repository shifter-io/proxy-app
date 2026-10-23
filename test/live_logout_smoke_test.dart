// Reproduce desktop sign-out with a real account; no proxy changes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/data/http_api.dart';
import 'package:shifter_app/data/geo_catalog.dart';
import 'package:shifter_app/data/store.dart';
import 'package:shifter_app/state/app_controller.dart';
import 'package:shifter_app/theme/theme.dart';
import 'package:shifter_app/ui/shell/app_root.dart';
import 'package:shifter_app/ui/screens/login_screen.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  final path = Platform.environment['SHIFTER_QA_ACCOUNTS'];
  if (path == null) {
    test(
      'live logout requires private fixtures',
      () {},
      skip: 'Set SHIFTER_QA_ACCOUNTS.',
    );
    return;
  }
  setUpAll(() async {
    await GeoCatalog.load();
    for (final family in {
      'Geist': ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold'],
      'GeistMono': ['Regular', 'Medium', 'SemiBold'],
    }.entries) {
      final loader = FontLoader(family.key);
      for (final weight in family.value) {
        loader.addFont(
          rootBundle.load('assets/fonts/${family.key}-$weight.ttf'),
        );
      }
      await loader.load();
    }
  });
  for (final account in [
    'RES_PAID',
    'NO_PLANS',
    'RES_INACTIVE',
    'NON_GEO_PENDING',
    'BOTH_ACTIVE',
  ]) {
    for (final size in <String, Size>{
      'small-phone': const Size(320, 568),
      'phone': const Size(393, 852),
      'tablet': const Size(820, 1180),
      'desktop': const Size(1440, 900),
    }.entries) {
      testWidgets('real UI sign-out $account ${size.key}', (tester) async {
        final keys = jsonDecode(File(path).readAsStringSync()) as Map;
        final client = HttpOverrides.runWithHttpOverrides(
          () => HttpClient(),
          _RealHttp(),
        );
        final app = AppController(
          api: HttpShifterApi(client: client),
          store: MemoryStore(),
        );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size.value;
        await tester.binding.setSurfaceSize(size.value);
        try {
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          await tester.runAsync(
            () async =>
                app.signIn(await app.api.verifyApiKey(keys[account] as String)),
          );
          await tester.pumpWidget(
            AppScope(
              controller: app,
              child: MaterialApp(
                theme: buildShifterTheme(),
                home: const AppRoot(),
              ),
            ),
          );
          await tester.pump(const Duration(seconds: 2));
          expect(tester.takeException(), isNull);
          final settings = find.byTooltip('Settings').hitTestable();
          if (settings.evaluate().isNotEmpty) {
            await tester.tap(settings.first);
          } else {
            await tester.tap(find.text('Settings').hitTestable().first);
          }
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          await tester.ensureVisible(find.text('Sign out'));
          await tester.pump(const Duration(seconds: 1));
          await tester.tap(find.text('Sign out').hitTestable().first);
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(find.text('Sign out of Shifter?'), findsOneWidget);
          await tester.tap(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.text('Sign out'),
            ),
          );
          for (var i = 0; i < 30; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 50));
            expect(
              tester.takeException(),
              isNull,
              reason: '$account ${size.key} sign-out transition',
            );
          }
          expect(app.phase, AuthPhase.signedOut);
          expect(app.session, isNull);
          expect(await app.store.readSession(), isNull);
          expect(find.byType(LoginScreen), findsOneWidget);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            tester.takeException(),
            isNull,
            reason:
                'outgoing desktop shell must tolerate the signed-out account',
          );
        } finally {
          await tester.pumpWidget(const SizedBox());
          app.dispose();
          client.close(force: true);
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      });
    }
  }
}
