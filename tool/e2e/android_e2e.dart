// Android end to end, host half. Plays Shifter on this Mac (API + a gateway
// that logs every login), runs integration_test/android_connect_test.dart on
// an emulator or phone, and checks from outside the app that:
//   1. connecting gives Android a VPN network carrying the local proxy,
//   2. another app's request (the browser) goes through it to the gateway
//      with the targeted login,
//   3. disconnecting removes it again.
//
//   dart run tool/e2e/android_e2e.dart [-d <adb serial>] [--browser-package <pkg>]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../test/support/fake_shifter.dart';

const _package = 'io.shifter.shifter_app';
const _apiPort = 18090;

late String _serial;

Future<String> adb(List<String> args) async {
  final r = await Process.run('adb', ['-s', _serial, ...args]);
  return '${r.stdout}${r.stderr}';
}

Future<void> until(Future<bool> Function() ok, String what, {int seconds = 120}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!await ok()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

/// The Shifter VPN network's proxy, as Android reports it ("127.0.0.1:port"), or null.
Future<String?> vpnProxy() async {
  final dump = await adb(['shell', 'dumpsys', 'connectivity']);
  for (final line in dump.split('\n')) {
    if (!line.contains('VPN') || !line.contains('HttpProxy')) continue;
    final m = RegExp(r'HttpProxy: \[([^\]]+)\] (\d+)').firstMatch(line);
    if (m != null) return '${m[1]}:${m[2]}';
  }
  return null;
}

Future<void> main(List<String> args) async {
  String? arg(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final devices = (await Process.run('adb', ['devices'])).stdout.toString().split('\n').skip(1).where((l) => l.endsWith('device')).map((l) => l.split('\t').first).toList();
  _serial = arg('-d') ?? (devices.isNotEmpty ? devices.first : throw StateError('no Android device: start an emulator first'));
  final sdk = (await adb(['shell', 'getprop', 'ro.build.version.sdk'])).trim();
  stdout.writeln('device $_serial, Android API $sdk');

  final shifter = FakeShifter(host: '10.0.2.2', bind: InternetAddress.anyIPv4);
  await shifter.start(apiPort: _apiPort);
  final failures = <String>[];
  void check(bool ok, String what) {
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $what');
    if (!ok) failures.add(what);
  }

  final test = await Process.start('flutter', [
    'test', 'integration_test/android_connect_test.dart', '-d', _serial,
    '--dart-define=SHIFTER_BASE_URL=${shifter.apiUrl}',
    '--dart-define=SHIFTER_IP_CHECK_URL=http://ip-check.test/json',
  ]);
  final testOut = StringBuffer();
  test.stdout.transform(utf8.decoder).listen((s) => testOut.write(s));
  test.stderr.transform(utf8.decoder).listen((s) => testOut.write(s));
  final testExit = test.exitCode;

  try {
    // The app is installed and running: allow its VPN slot without the
    // consent dialog (what tapping "OK" does once).
    await until(() async => (await adb(['shell', 'pidof', _package])).trim().isNotEmpty, 'app started', seconds: 600);
    await adb(['shell', 'appops', 'set', _package, 'ACTIVATE_VPN', 'allow']);
    check(await vpnProxy() == null, 'no Shifter proxy before connecting');
    shifter.step = 1;

    // Connected once the app's exit-IP check went through the gateway.
    await until(() async => shifter.log.any((e) => e.target.contains('ip-check.test')), 'app connected');
    final user = shifter.log.firstWhere((e) => e.target.contains('ip-check.test')).user;
    check(RegExp(r'^customer-test-country-de-sid-[a-z0-9]{12}-ttl-600$').hasMatch(user), 'gateway login targets Germany with a sticky session ($user)');

    String? proxy;
    await until(() async => (proxy = await vpnProxy()) != null, 'VPN network with proxy', seconds: 15).catchError((_) {});
    check(proxy != null && proxy!.startsWith('127.0.0.1:'), 'Android gives other apps the local proxy ($proxy)');
    final notification = await adb(['shell', 'dumpsys', 'notification', '--noredact']);
    check(notification.contains('Connected through Shifter'), 'connection notification shown');

    // Another app: open a page in the browser; it must reach the gateway.
    final browser = arg('--browser-package');
    final before = shifter.log.length;
    await adb([
      'shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', 'http://example.test/from-android-browser',
      if (browser != null) ...['-p', browser],
    ]);
    var reached = false;
    await until(() async => reached = shifter.log.skip(before).any((e) => e.target.contains('example.test')), 'browser request', seconds: 30)
        .catchError((_) {});
    check(reached, 'a browser request went through the local proxy to the gateway');
    if (reached) {
      final e = shifter.log.skip(before).firstWhere((e) => e.target.contains('example.test'));
      check(e.user == user, 'with the same login (${e.user})');
    }
    await adb(['shell', 'am', 'start', '-n', '$_package/.MainActivity']);

    shifter.step = 2;
    final code = await testExit.timeout(const Duration(minutes: 3));
    check(code == 0, 'app half passed');
    if (code != 0) stdout.writeln(testOut);
    await until(() async => await vpnProxy() == null, 'VPN gone', seconds: 10).catchError((_) {});
    check(await vpnProxy() == null, 'disconnect removed the proxy');
  } catch (e) {
    failures.add('$e');
    stdout
      ..writeln('ERROR $e')
      ..writeln(testOut);
    test.kill();
  } finally {
    await shifter.stop();
  }
  stdout.writeln(failures.isEmpty ? '\nAll checks passed on API $sdk.' : '\n${failures.length} check(s) failed on API $sdk.');
  exit(failures.isEmpty ? 0 : 1);
}
