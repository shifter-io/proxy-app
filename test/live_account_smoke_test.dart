// Real backend smoke checks. Credentials stay outside the repository.
// SHIFTER_QA_ACCOUNTS=/private/path.json flutter test test/live_account_smoke_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/data/http_api.dart';
import 'package:shifter_app/data/geo_catalog.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/data/store.dart';
import 'package:shifter_app/state/app_controller.dart';
import 'package:shifter_app/theme/theme.dart';
import 'package:shifter_app/ui/shell/app_root.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  final path = Platform.environment['SHIFTER_QA_ACCOUNTS'];
  if (path == null) {
    test(
      'live account smoke requires private fixtures',
      () {},
      skip: 'Set SHIFTER_QA_ACCOUNTS to a private JSON file.',
    );
    return;
  }
  final accounts = (jsonDecode(File(path).readAsStringSync()) as Map)
      .cast<String, String>();
  final out = Directory(
    Platform.environment['SHIFTER_QA_OUTPUT'] ?? 'qa-results/live-smoke',
  )..createSync(recursive: true);
  final results = <Map<String, Object?>>[];
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
  tearDownAll(
    () => File('${out.path}/results.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results)),
  );
  for (final entry in accounts.entries) {
    testWidgets('real account ${entry.key}', (tester) async {
      final client = HttpOverrides.runWithHttpOverrides(
        () => HttpClient(),
        _RealHttp(),
      );
      final api = HttpShifterApi(client: client);
      final controller = AppController(api: api, store: MemoryStore());
      try {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() async {
          await controller.signIn(await api.verifyApiKey(entry.value));
        });
        expect(controller.membershipsError, isNull);
        final list = controller.memberships!;
        final usable = list.where((m) => m.usable).toList();
        final result = <String, Object?>{
          'account': entry.key,
          'memberships': list.length,
          'usable': usable.length,
          'plans': [
            for (final m in list)
              {
                'type': m.type.name,
                'status': m.status.name,
                if (m is ResidentialMembership) 'pool': m.pool.name,
              },
          ],
          'screens': <String>[],
          'gateSettingsAvailable': false,
        };
        results.add(result);
        if (entry.key == 'NO_PLANS') expect(list, isEmpty);
        if (['RES_INACTIVE', 'NON_GEO_PENDING'].contains(entry.key)) {
          expect(usable, isEmpty);
        }
        if (entry.key == 'BOTH_ACTIVE') {
          expect(usable.map((m) => m.type).toSet(), {
            ProductType.residential,
            ProductType.isp,
          });
        }
        if (entry.key.startsWith('RES_') && entry.key != 'RES_INACTIVE') {
          expect(usable.single.type, ProductType.residential);
        }
        if (entry.key == 'ISP_PAID') {
          expect(usable.single.type, ProductType.isp);
        }
        if (entry.key == 'ISP_TRIAL') {
          // This real trial expired before the 14 October retest. Keep it
          // as an expired-account UI check instead of assuming it is active.
          expect(list.single.type, ProductType.isp);
          expect(list.single.status.name, 'expired');
          expect(usable, isEmpty);
        }
        for (final m in usable.whereType<IspMembership>()) {
          final ips = await tester.runAsync(() => api.ispIps(m.id));
          expect(ips, isNotEmpty);
          result['assignedIps'] = ips!.length;
        }
        for (final size in <String, Size>{
          'small-phone': const Size(320, 568),
          'phone': const Size(393, 852),
          'tablet': const Size(820, 1180),
          'desktop': const Size(1440, 900),
        }.entries) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size.value;
          await tester.binding.setSurfaceSize(size.value);
          final boundary = GlobalKey();
          await tester.pumpWidget(
            AppScope(
              controller: controller,
              child: MaterialApp(
                theme: buildShifterTheme(),
                home: RepaintBoundary(key: boundary, child: const AppRoot()),
              ),
            ),
          );
          for (var i = 0; i < 15; i++) {
            await tester.pump(const Duration(milliseconds: 150));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          final layoutError = tester.takeException();
          if (layoutError != null) {
            final errors =
                (result['layoutErrors'] ??= <String>[]) as List<String>;
            errors.add('${size.key}: $layoutError');
          }
          if (usable.isEmpty) {
            expect(find.text('No active memberships'), findsOneWidget);
          }
          result['gateSettingsAvailable'] =
              find.byTooltip('Settings').evaluate().isNotEmpty ||
              find.text('Settings').evaluate().isNotEmpty;
          final name = '${entry.key}_${size.key}.png';
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            File('${out.path}/$name')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
          (result['screens'] as List<String>).add(name);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(controller.signOut);
        expect(controller.session, isNull);
        result['passed'] = true;
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        client.close(force: true);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  }
}
