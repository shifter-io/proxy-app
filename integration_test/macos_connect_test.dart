// End to end on this Mac: the real app (live API client, keychain, local
// proxy, macOS system proxy via networksetup) against the stand-in Shifter.
// It really switches the Mac's HTTP/HTTPS proxy on, then checks it is put back.
//
//   flutter test integration_test/macos_connect_test.dart -d macos \
//     --dart-define=SHIFTER_BASE_URL=http://127.0.0.1:18090 \
//     --dart-define=SHIFTER_IP_CHECK_URL=http://ip-check.test/json
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/data/store.dart';
import 'package:shifter_app/shifter_app.dart';
import 'package:shifter_app/state/app_controller.dart';

import '../test/support/fake_shifter.dart';

Future<String> scutilProxy() async => '${(await Process.run('scutil', ['--proxy'])).stdout}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sign in, connect through the system proxy, disconnect restores it', (tester) async {
    final shifter = FakeShifter();
    await tester.runAsync(() => shifter.start(apiPort: 18090));
    final before = await tester.runAsync(scutilProxy);
    // Start signed out, and give back whatever sign-in this Mac had afterwards.
    final store = PersistentStore();
    final saved = await tester.runAsync(store.readSession);
    addTearDown(() => store.writeSession(saved));
    await tester.runAsync(() => store.writeSession(null));

    await tester.pumpWidget(const ShifterApp(live: true));
    final app = AppScope.read(tester.element(find.byType(Navigator).first));

    Future<void> until(bool Function() ok, String what) async {
      for (var i = 0; i < 300 && !ok(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(ok(), isTrue, reason: 'timed out: $what');
    }

    // Sign in through the login screen.
    await until(() => app.phase == AuthPhase.signedOut, 'login screen');
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byType(TextField), fakeKey);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await until(() => app.memberships != null, 'plans loaded');
    expect(app.session?.user.email, 't@example.com');

    // Pick the residential plan and a country, then connect.
    await tester.runAsync(() => app.selectMembership('pqqD'));
    await tester.runAsync(() => app.setTarget('pqqD', const ResidentialTarget(country: GeoCountry('de', 'Germany'))));
    await tester.runAsync(app.connect);
    await until(() => !app.isConnecting, 'connect finished');
    expect(app.connection.status, ConnectionStatus.connected, reason: app.connection.message);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Connected'), findsWidgets);

    // macOS now sends HTTP and HTTPS to the app's local proxy…
    final on = await tester.runAsync(scutilProxy);
    expect(on, contains('HTTPEnable : 1'));
    expect(on, contains('HTTPSEnable : 1'));
    expect(on, contains('HTTPProxy : 127.0.0.1'));
    final port = RegExp(r'HTTPPort : (\d+)').firstMatch(on!)![1];
    expect(on, contains('shifter.io'), reason: 'the API is always bypassed');

    // …which reaches the gateway with the targeted login.
    final curl = await tester.runAsync(() => Process.run('curl', ['-s', '-x', 'http://127.0.0.1:$port', 'http://example.test/through-mac']));
    expect('${curl!.stdout}', 'origin GET /through-mac ');
    expect(shifter.log.last.user, matches(RegExp(r'^customer-test-country-de-sid-[a-z0-9]{12}-ttl-600$')));
    expect(app.connection.exitIp, shifter.exitIpFor(shifter.log.last.user));

    // Disconnect puts the Mac's own settings back exactly.
    await tester.runAsync(app.disconnect);
    final after = await tester.runAsync(scutilProxy);
    expect(after, before);

    await tester.runAsync(() => app.signOut());
    await tester.runAsync(shifter.stop);
  });
}
