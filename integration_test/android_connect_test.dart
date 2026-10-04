// App half of the Android end to end test; the host half is
// tool/e2e/android_e2e.dart, which runs this, plays Shifter (API + gateway)
// on the Mac, and checks from outside that Android gives the proxy to other
// apps. Run it through the host script, not on its own.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/shifter_app.dart';
import 'package:shifter_app/state/app_controller.dart';

import '../test/support/fake_shifter.dart' show fakeKey;

const _api = String.fromEnvironment('SHIFTER_BASE_URL');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('connect hands the local proxy to Android, disconnect takes it back', (tester) async {
    Future<int> hostStep() async {
      final client = HttpClient();
      try {
        final res = await (await client.getUrl(Uri.parse('$_api/_test/step'))).close();
        return (jsonDecode(await res.transform(utf8.decoder).join()) as Map)['step'] as int;
      } finally {
        client.close(force: true);
      }
    }

    await tester.pumpWidget(const ShifterApp(live: true));
    final app = AppScope.read(tester.element(find.byType(Navigator).first));

    Future<void> until(Future<bool> Function() ok, String what, {int seconds = 60}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!(await tester.runAsync(ok))!) {
        if (DateTime.now().isAfter(end)) fail('timed out: $what');
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump();
      }
    }

    // Sign in through the login screen.
    await until(() async => app.phase != AuthPhase.booting, 'boot');
    if (app.phase == AuthPhase.signedIn) await tester.runAsync(app.signOut);
    await until(() async => app.phase == AuthPhase.signedOut, 'login screen');
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField), fakeKey);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await until(() async => app.memberships != null, 'plans loaded');

    await tester.runAsync(() => app.selectMembership('pqqD'));
    await tester.runAsync(() => app.setTarget('pqqD', const ResidentialTarget(country: GeoCountry('de', 'Germany'))));

    // Step 1: the host has allowed the VPN slot (no consent dialog in tests).
    await until(() async => await hostStep() >= 1, 'host ready');
    await tester.runAsync(app.connect);
    await until(() async => !app.isConnecting, 'connect finished');
    expect(app.connection.status, ConnectionStatus.connected, reason: app.connection.message);
    expect(app.connection.exitIp, isNotNull, reason: 'exit IP checked through the local proxy');

    // Step 2: the host checked Android's proxy and sent a request through it.
    await until(() async => await hostStep() >= 2, 'host checks', seconds: 120);

    await tester.runAsync(app.disconnect);
    expect(app.connection.status, ConnectionStatus.disconnected);
    await tester.runAsync(app.signOut);
  });
}
