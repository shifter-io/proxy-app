// Live end to end: the real Shifter API and gateway, with a real API key.
// Signs in, picks the first usable plan, connects and checks the exit IP is
// Shifter's, not the phone's own; on iOS also that a plain iOS request (as
// Safari and other apps make it) leaves through Shifter. Run it with
// tool/e2e/live_test.sh, which takes the key from the Keychain: never put
// the key in the repo.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/proxy/proxy_engine.dart' show ipCheckUrl;
import 'package:shifter_app/shifter_app.dart';
import 'package:shifter_app/state/app_controller.dart';

const _key = String.fromEnvironment('SHIFTER_TEST_KEY');

/// The exit IP another app sees: a native request on iOS (it follows the
/// tunnel's proxy settings); elsewhere a plain Dart request (direct).
Future<String> _ipSeenOutside() async {
  final String body;
  if (Platform.isIOS) {
    body = (await const MethodChannel('shifter/tunnel').invokeMethod<String>('fetch', ipCheckUrl))!;
  } else {
    final client = HttpClient();
    try {
      body = await (await (await client.getUrl(Uri.parse(ipCheckUrl))).close()).transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }
  return (jsonDecode(body) as Map)['ip'] as String;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('live: sign in, connect through Shifter, disconnect', (tester) async {
    expect(_key, isNotEmpty, reason: 'run through tool/e2e/live_test.sh');
    await tester.pumpWidget(const ShifterApp(live: true));
    final app = AppScope.read(tester.element(find.byType(Navigator).first));

    Future<void> until(bool Function() ok, String what, {int seconds = 60}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail('timed out: $what');
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump();
      }
    }

    await until(() => app.phase != AuthPhase.booting, 'boot');
    if (app.phase == AuthPhase.signedIn) await tester.runAsync(app.signOut);
    await until(() => app.phase == AuthPhase.signedOut, 'login screen');
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField), _key);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await until(() => app.memberships != null || app.membershipsError != null, 'plans loaded', seconds: 90);
    expect(app.membershipsError, isNull);
    final plans = app.memberships!;
    for (final m in plans) {
      debugPrint('LIVE plan ${m.id} ${m.type.name} "${m.planName}" ${m.status.name}');
    }

    final direct = (await tester.runAsync(_ipSeenOutside))!;
    debugPrint('LIVE direct IP $direct');

    final m = plans.firstWhere((m) => m.usable, orElse: () => fail('no usable plan on this account'));
    await tester.runAsync(() => app.selectMembership(m.id));
    if (m is ResidentialMembership) {
      await tester.runAsync(() => app.setTarget(m.id, const ResidentialTarget(country: GeoCountry('de', 'Germany'))));
    } else {
      final ips = (await tester.runAsync(() => app.api.ispIps(m.id)))!;
      expect(ips, isNotEmpty, reason: 'ISP plan has no IPs');
      await tester.runAsync(() => app.setTarget(m.id, IspTarget(ips.first)));
    }
    debugPrint('LIVE connecting with ${m.type.name} plan ${m.id}; tap Allow if iOS asks to add a VPN configuration');

    await tester.runAsync(app.connect);
    await until(() => !app.isConnecting, 'connect finished', seconds: 180);
    expect(app.connection.status, ConnectionStatus.connected, reason: app.connection.message);
    final exit = app.connection.exitIp!;
    debugPrint('LIVE app exit IP $exit (${app.connection.exitCountry})');
    expect(exit, isNot(direct), reason: 'the exit must be Shifter, not the phone');
    if (m is ResidentialMembership) expect(app.connection.exitCountry, 'de');

    if (Platform.isIOS) {
      final seen = (await tester.runAsync(_ipSeenOutside))!;
      debugPrint('LIVE other apps exit IP $seen');
      expect(seen, isNot(direct), reason: 'a plain iOS request must leave through Shifter');
    }

    await tester.runAsync(app.disconnect);
    expect(app.connection.status, ConnectionStatus.disconnected);
    if (Platform.isIOS) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      final after = (await tester.runAsync(_ipSeenOutside))!;
      debugPrint('LIVE after disconnect IP $after');
      expect(after, direct, reason: 'after disconnect, other apps go direct again');
    }
    await tester.runAsync(app.signOut);
  });
}
