// Responsive workspace regression and optional PNG evidence:
// flutter test test/workspace_layout_test.dart --dart-define=WORKSPACE_SCREENSHOTS=true
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/data/geo_catalog.dart';
import 'package:shifter_app/data/mock_api.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/state/app_controller.dart';
import 'package:shifter_app/theme/theme.dart';
import 'package:shifter_app/ui/screens/plans_screen.dart';
import 'package:shifter_app/ui/shell/app_root.dart';
import 'package:shifter_app/ui/widgets/ambient_motion.dart';
import 'package:shifter_app/ui/widgets/membership_card.dart';

const _personal = Workspace(id: 'personal', name: 'Personal', role: 'owner', personal: true);
const _team = Workspace(id: 'team', name: 'Acme Research & Operations International', role: 'viewer', personal: false);
const _empty = Workspace(id: 'empty', name: 'Workspace without plans', role: 'billing', personal: false);

Membership _plan(String id, Workspace? workspace, {bool expired = false}) => ResidentialMembership(
    id: id, workspace: workspace, planName: 'Spark',
    status: expired ? MembershipStatus.expired : MembershipStatus.active,
    expiresAt: DateTime(2027, 1, 25), pool: ResidentialPool.full,
    traffic: const Traffic(totalBytes: 10000000000, usedBytes: 2000000000));

class _WorkspaceApi extends MockShifterApi {
  _WorkspaceApi(this.catalog);
  final MembershipCatalog catalog;
  @override
  Future<MembershipCatalog> memberships() async => catalog;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 160));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('WORKSPACE_SCREENSHOTS')) return;
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('qa-results/workspaces')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<AppController> _show(WidgetTester tester, Size size, GlobalKey key,
    {double scale = 1, MembershipCatalog? catalog}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  await tester.binding.setSurfaceSize(size);
  final app = AppController(api: _WorkspaceApi(catalog ?? MembershipCatalog(
      memberships: [_plan('personal', _personal), _plan('team', _team)],
      workspaces: const [_personal, _team, _empty])));
  await tester.pump(const Duration(milliseconds: 600));
  await app.signIn(Session(user: const User(id: 'qa', email: 'qa@example.com', name: 'Workspace QA'),
      apiKey: 'synthetic-workspace-layout-key', createdAt: DateTime(2026, 10, 13)));
  await tester.pumpWidget(AppScope(controller: app, child: MaterialApp(
    theme: buildShifterTheme(), debugShowCheckedModeBanner: false,
    builder: (context, child) => RepaintBoundary(key: key, child: MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!)),
    home: const AmbientMotionScope(child: AppRoot()),
  )));
  await _settle(tester);
  addTearDown(() async { app.dispose(); tester.view.resetPhysicalSize(); tester.view.resetDevicePixelRatio(); await tester.binding.setSurfaceSize(null); });
  return app;
}

void main() {
  setUpAll(() async {
    await GeoCatalog.load();
    for (final family in ['Geist', 'GeistMono']) {
      final loader = FontLoader(family);
      for (final weight in ['Regular', 'Medium', 'SemiBold']) {
        loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
      }
      await loader.load();
    }
  });

  for (final size in [const Size(280, 653), const Size(320, 568), const Size(393, 852),
      const Size(600, 800), const Size(768, 1024), const Size(1024, 768), const Size(1440, 900), const Size(1024, 480), const Size(844, 390)]) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';
    testWidgets('workspace picker, home and switching at $name', (tester) async {
      final key = GlobalKey();
      final app = await _show(tester, size, key);
      expect(find.text('Personal'), findsOneWidget);
      expect(find.text(_team.name), findsOneWidget);
      expect(find.text('Workspace without plans'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, key, '$name-plans');
      final card = find.byKey(const ValueKey('plan-team'));
      await tester.ensureVisible(card);
      await _settle(tester);
      await tester.tap(card);
      await _settle(tester);
      expect(app.activeId, 'team');
      expect(find.text('Traffic uses ${_team.name}’s plan and wallet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, key, '$name-home');
      if (size.width < 600) {
        await tester.tap(find.bySemanticsLabel(RegExp('Switch membership')));
        await _settle(tester);
        expect(find.text('Switch plan'), findsOneWidget);
        expect(find.text('Workspace without plans'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(tester, key, '$name-switcher');
        await tester.drag(find.byType(ListView).last, const Offset(0, -650));
        await _settle(tester);
        expect(find.text('No active Residential or ISP plans in this workspace.').hitTestable(), findsOneWidget);
        await _capture(tester, key, '$name-empty-workspace');
        Navigator.of(tester.element(find.text('Switch plan'))).pop();
        await _settle(tester);
      } else {
        await tester.tap(find.text('Plans').hitTestable().first);
        await _settle(tester);
        expect(find.text('Workspace without plans'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _capture(tester, key, '$name-switcher');
      }
    });
  }

  testWidgets('long workspace names and enlarged text at 320px', (tester) async {
    final key = GlobalKey();
    final app = await _show(tester, const Size(320, 720), key, scale: 1.3);
    expect(tester.takeException(), isNull);
    await app.selectMembership('team');
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await _capture(tester, key, '320-large-text');
  });

  testWidgets('mixed legacy plans remain visible; viewer renew is Open in panel', (tester) async {
    await _show(tester, const Size(393, 852), GlobalKey(), catalog: MembershipCatalog(
      memberships: [_plan('legacy', null), _plan('team', _team, expired: true)], workspaces: const [_team, _empty]));
    await tester.tap(find.bySemanticsLabel(RegExp('Switch membership')));
    await _settle(tester);
    expect(find.text('Personal'), findsOneWidget);
    expect(find.byType(MembershipCard), findsOneWidget);
    await tester.ensureVisible(find.text('EXPIRED'));
    await _settle(tester);
    await tester.tap(find.text('EXPIRED'));
    await _settle(tester);
    expect(find.text('Open in panel'), findsOneWidget);
    expect(find.text('Renew'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('personal-only picker keeps the ungrouped layout', (tester) async {
    await _show(tester, const Size(393, 852), GlobalKey(), catalog: MembershipCatalog(
      memberships: [_plan('one', _personal), _plan('two', _personal)], workspaces: const [_personal]));
    expect(find.text('Personal'), findsNothing);
    expect(find.byType(PlansList), findsOneWidget);
    expect(find.byType(MembershipCard), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
