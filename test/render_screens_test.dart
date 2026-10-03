// Renders the app inside simulated devices to PNGs for visual review:
//   flutter test test/render_screens_test.dart
// Output: build/screens/*.png
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/data/geo_catalog.dart';
import 'package:shifter_app/preview/device_frame.dart';
import 'package:shifter_app/preview/devices.dart';
import 'package:shifter_app/shifter_app.dart';
import 'package:shifter_app/theme/theme.dart';
import 'package:shifter_app/theme/tokens.dart';

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(rootBundle.load('assets/fonts/$f'));
    }
    await loader.load();
  }

  await family('Geist', ['Geist-Light.ttf', 'Geist-Regular.ttf', 'Geist-Medium.ttf', 'Geist-SemiBold.ttf', 'Geist-Bold.ttf']);
  await family('GeistMono', ['GeistMono-Regular.ttf', 'GeistMono-Medium.ttf', 'GeistMono-SemiBold.ttf']);
}

final _out = Directory('build/screens')..createSync(recursive: true);

/// Pumps [frames] × [step] of fake time, letting real async work (image and
/// SVG decoding) finish in between.
Future<void> _settle(WidgetTester tester, {int frames = 12, Duration step = const Duration(milliseconds: 150)}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
}

Future<void> _shot(WidgetTester tester, GlobalKey boundary, String name) async {
  await tester.runAsync(() async {
    final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await ro.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('${_out.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<GlobalKey> _pumpDevice(WidgetTester tester, PreviewDevice d, {String? demoKey, bool connected = false, bool landscape = false}) async {
  final outer = DeviceFrame.outerSize(d, landscape);
  await tester.binding.setSurfaceSize(Size(outer.width + 80, outer.height + 80));
  final boundary = GlobalKey();
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildShifterTheme(),
    home: ColoredBox(
      color: Sf.bgDeep,
      child: Center(
        child: RepaintBoundary(
          key: boundary,
          child: Container(
            color: Sf.bgDeep,
            padding: const EdgeInsets.all(30),
            child: DeviceFrame(device: d, landscape: landscape, child: ShifterApp(key: UniqueKey(), demoKey: demoKey, demoConnected: connected)),
          ),
        ),
      ),
    ),
  ));
  await _settle(tester, frames: 16);
  return boundary;
}

const _demo = 'demo0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV';
const _single = 'single0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQR';

void main() {
  // Load fonts and the location catalog once, outside any test's fake clock.
  setUpAll(() async {
    await _loadFonts();
    await GeoCatalog.load();
  });

  final devices = ['fold1-cover', 'iphone-se', 'iphone-15', 'zfold5-inner', 'ipad-air', 'macbook'];

  for (final id in devices) {
    testWidgets('login · $id', (tester) async {
      final b = await _pumpDevice(tester, deviceById(id));
      await _shot(tester, b, '${id}_1_login');
    });

    testWidgets('home · $id', (tester) async {
      final b = await _pumpDevice(tester, deviceById(id), demoKey: _single);
      await _shot(tester, b, '${id}_2_home');
    });

    testWidgets('connected · $id', (tester) async {
      final b = await _pumpDevice(tester, deviceById(id), demoKey: _single, connected: true);
      await _shot(tester, b, '${id}_3_connected');
    });

    testWidgets('plans · $id', (tester) async {
      final b = await _pumpDevice(tester, deviceById(id), demoKey: _demo);
      await _shot(tester, b, '${id}_4_plans');
    });
  }

  for (final id in ['iphone-15', 'fold1-cover']) {
    testWidgets('location + settings · $id', (tester) async {
      final b = await _pumpDevice(tester, deviceById(id), demoKey: _single);
      await tester.tap(find.text('LOCATION').hitTestable().first);
      await _settle(tester, frames: 10);
      await _shot(tester, b, '${id}_5_location');
      await tester.tap(find.text('United States').hitTestable().first);
      await _settle(tester, frames: 10);
      await _shot(tester, b, '${id}_6_country');
      await tester.tap(find.text('Cities').last, warnIfMissed: false);
      await _settle(tester, frames: 6);
      await tester.enterText(find.byType(TextField).last, 'austin');
      await _settle(tester, frames: 6);
      await tester.tap(find.text('Austin').hitTestable().first);
      await _settle(tester, frames: 6);
      await _shot(tester, b, '${id}_7_city');
    });

    testWidgets('settings · $id', (tester) async {
      final b = await _pumpDevice(tester, deviceById(id), demoKey: _single);
      await tester.tap(find.byTooltip('Settings').hitTestable().first);
      await _settle(tester, frames: 10);
      await _shot(tester, b, '${id}_8_settings');
    });

    testWidgets('isp · $id', (tester) async {
      final b = await _pumpDevice(tester, deviceById(id), demoKey: 'isp0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVW', connected: true);
      await _shot(tester, b, '${id}_9_isp');
    });
  }

  testWidgets('landscape phone', (tester) async {
    final b = await _pumpDevice(tester, deviceById('iphone-15'), demoKey: _single, connected: true, landscape: true);
    await _shot(tester, b, 'iphone-15_landscape');
  });

  testWidgets('settings · macbook', (tester) async {
    final b = await _pumpDevice(tester, deviceById('macbook'), demoKey: _single);
    await tester.tap(find.text('Settings').hitTestable().first);
    await _settle(tester, frames: 10);
    await _shot(tester, b, 'macbook_8_settings');
  });

  testWidgets('isp targeting · iphone-15', (tester) async {
    final b = await _pumpDevice(tester, deviceById('iphone-15'), demoKey: _single);
    await tester.tap(find.text('LOCATION').hitTestable().first);
    await _settle(tester, frames: 10);
    await tester.enterText(find.byType(TextField).last, 'comcast');
    await _settle(tester, frames: 8);
    await _shot(tester, b, 'isp_1_search');
    await tester.enterText(find.byType(TextField).last, '');
    await _settle(tester, frames: 6);
    await tester.tap(find.text('United States').hitTestable().first);
    await _settle(tester, frames: 10);
    await tester.tap(find.text('ISP').last, warnIfMissed: false);
    await _settle(tester, frames: 8);
    await _shot(tester, b, 'isp_2_country');
    await tester.tap(find.text('States').last, warnIfMissed: false);
    await _settle(tester, frames: 4);
    await tester.enterText(find.byType(TextField).last, 'texas');
    await _settle(tester, frames: 6);
    await tester.tap(find.text('Texas').hitTestable().first);
    await _settle(tester, frames: 10);
    await tester.enterText(find.byType(TextField).last, 'austin');
    await _settle(tester, frames: 6);
    await tester.tap(find.text('Austin').hitTestable().first);
    await tester.enterText(find.byType(TextField).last, '');
    await _settle(tester, frames: 6);
    await tester.tap(find.text('ISP').last, warnIfMissed: false);
    await _settle(tester, frames: 8);
    await tester.tap(find.textContaining('Google Fiber').hitTestable().first);
    await _settle(tester, frames: 8);
    await _shot(tester, b, 'isp_3_city');
  });
}
