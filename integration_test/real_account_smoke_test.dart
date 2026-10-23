// Live native smoke checks. Supply credentials via a private define file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shifter_app/data/http_api.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/data/store.dart';
import 'package:shifter_app/proxy/proxy_engine.dart';
import 'package:shifter_app/state/app_controller.dart';
import 'package:shifter_app/theme/theme.dart';
import 'package:shifter_app/ui/screens/login_screen.dart';
import 'package:shifter_app/ui/shell/app_root.dart';

const fixture = String.fromEnvironment('QA_ACCOUNTS');
const fixturePath = String.fromEnvironment('QA_ACCOUNT_FILE');

Future<Map> nativeMacIp() async {
  String diagnostic = 'no response';
  for (var attempt = 1; attempt <= 3; attempt++) {
    final fetch = await Process.run('/usr/bin/swift', [
      '-e',
      '''
import Foundation
import Dispatch
let done = DispatchSemaphore(value: 0)
URLSession.shared.dataTask(with: URL(string: "https://ip-info.com/json")!) { data, _, error in
  if let data = data { FileHandle.standardOutput.write(data) }
  done.signal()
}.resume()
_ = done.wait(timeout: .now() + 20)
''',
    ]);
    try {
      final response = jsonDecode('${fetch.stdout}') as Map;
      if (fetch.exitCode == 0 &&
          response['ip'] is String &&
          (response['ip'] as String).isNotEmpty) {
        return response;
      }
    } on FormatException {
      // A temporary lookup timeout must not become a null IP comparison.
    }
    diagnostic = 'exit=${fetch.exitCode}, stderr=${fetch.stderr}';
    debugPrint('QA native IP lookup attempt=$attempt returned no usable JSON');
    if (attempt < 3) await Future<void>.delayed(const Duration(seconds: 1));
  }
  throw StateError('Native IP lookup failed after 3 attempts: $diagnostic');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final input = fixturePath.isEmpty
      ? fixture
      : File(fixturePath).readAsStringSync();
  final accounts = (jsonDecode(input) as Map).cast<String, String>();
  testWidgets('real accounts and native routing', (tester) async {
    final store = MemoryStore();
    final engine = ProxyEngine.forPlatform(store);
    final app = AppController(
      api: HttpShifterApi(),
      store: store,
      engine: engine,
    );
    final before = Platform.isMacOS
        ? '${(await Process.run('scutil', ['--proxy'])).stdout}'
        : null;
    Map? direct;
    Future<void> until(
      bool Function() ok, [
      String condition = 'condition',
    ]) async {
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (!ok() && DateTime.now().isBefore(end)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await tester.pump();
      }
      expect(
        ok(),
        isTrue,
        reason:
            'timed out: $condition; phase=${app.phase}; membershipsError=${app.membershipsError}',
      );
    }

    await tester.pumpWidget(
      AppScope(
        controller: app,
        child: MaterialApp(theme: buildShifterTheme(), home: const AppRoot()),
      ),
    );
    try {
      if (Platform.isMacOS) {
        direct = await tester.runAsync(nativeMacIp);
        expect(
          direct?['ip'],
          isNotEmpty,
          reason: 'independent direct-network baseline',
        );
      }
      await until(() => app.phase == AuthPhase.signedOut);
      for (final entry in accounts.entries) {
        expect(find.text('Preview with a demo key'), findsNothing);
        final loginKey = find.descendant(
          of: find.byType(LoginScreen),
          matching: find.byType(TextField),
        );
        await until(
          () => loginKey.hitTestable().evaluate().length == 1,
          '${entry.key} login field',
        );
        // Pasting a whole key starts verification through the actual form.
        await tester.enterText(loginKey, entry.value);
        await tester.pump();
        // Some native text-input implementations do not report a paste.
        // Submit only while the form remains idle, avoiding duplicate verification.
        final continueButton = find.text('Continue').hitTestable();
        if (continueButton.evaluate().isNotEmpty) {
          await tester.tap(continueButton.first);
        }
        await until(
          () => app.phase == AuthPhase.signedIn && app.memberships != null,
          '${entry.key} authentication',
        );
        await tester.pump(const Duration(seconds: 1));
        expect(app.membershipsError, isNull);
        debugPrint(
          'QA account=${entry.key} supported=${app.memberships!.length} usable=${app.usableMemberships.length}',
        );
        if (app.usableMemberships.isEmpty) {
          expect(find.text('No active memberships'), findsOneWidget);
        }
        if (entry.key == 'RES_PAID' || entry.key == 'ISP_PAID') {
          final m = app.usableMemberships.single;
          if (m is IspMembership) {
            final ips = await tester.runAsync(() => app.api.ispIps(m.id));
            await tester.runAsync(
              () => app.setTarget(m.id, IspTarget(ips!.first)),
            );
          }
          await tester.runAsync(app.connect);
          await until(() => !app.isConnecting);
          expect(
            app.connection.status,
            ConnectionStatus.connected,
            reason: app.connection.message,
          );
          expect(app.connection.exitIp, isNotEmpty);
          debugPrint('QA connection=${entry.key} PASS (exit redacted)');
          if (Platform.isMacOS) {
            final on =
                '${(await tester.runAsync(() => Process.run('scutil', ['--proxy'])))!.stdout}';
            expect(on, contains('HTTPEnable : 1'));
            expect(on, contains('HTTPSEnable : 1'));
            // A separate native URLSession follows the OS proxy independently
            // of the app's explicit loopback IP check.
            final external = await tester.runAsync(nativeMacIp);
            expect(
              external?['ip'],
              isNotEmpty,
              reason: 'independent proxied request',
            );
            expect(
              external!['ip'] != direct!['ip'],
              isTrue,
              reason: 'independent native request changes from direct IP',
            );
            if (m is IspMembership) {
              expect(
                external['ip'] == app.connection.exitIp,
                isTrue,
                reason: 'static ISP exit matches independent native request',
              );
            }
            debugPrint('QA native URLSession routing=${entry.key} PASS');
          }
          await tester.runAsync(app.disconnect);
          if (Platform.isMacOS) {
            final after =
                '${(await tester.runAsync(() => Process.run('scutil', ['--proxy'])))!.stdout}';
            expect(after, before, reason: 'Mac proxy restored exactly');
            final restored = await tester.runAsync(nativeMacIp);
            expect(
              restored!['ip'] == direct!['ip'],
              isTrue,
              reason: 'native request returns to direct IP after disconnect',
            );
          }
          debugPrint('QA disconnect=${entry.key} PASS');
        }
        final settings = find.byTooltip('Settings').hitTestable();
        await tester.tap(
          settings.evaluate().isNotEmpty
              ? settings.first
              : find.text('Settings').hitTestable().first,
        );
        await tester.pump(const Duration(seconds: 1));
        await until(() => find.text('Sign out').evaluate().isNotEmpty);
        await tester.ensureVisible(find.text('Sign out'));
        await until(
          () => find.text('Sign out').hitTestable().evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Sign out').hitTestable().first);
        await tester.pump(const Duration(seconds: 1));
        await until(
          () => find.text('Sign out of Shifter?').evaluate().isNotEmpty,
        );
        expect(find.text('Sign out of Shifter?'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.text('Sign out'),
          ),
        );
        await until(() => app.phase == AuthPhase.signedOut);
        await tester.pump(const Duration(seconds: 1));
        expect(app.session, isNull);
        expect(await tester.runAsync(store.readSession), isNull);
        debugPrint('QA UI sign-out=${entry.key} PASS');
      }
    } finally {
      await tester.runAsync(app.disconnect);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
