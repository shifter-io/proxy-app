// iOS end to end, host half, on a real iPhone or iPad (the simulator can't
// run the tunnel extension). Plays Shifter on this Mac's Wi-Fi address (API +
// a gateway that logs every login), runs integration_test/connect_test.dart on
// the device, and checks from outside the app that:
//   1. connecting starts the Shifter tunnel and its proxy logs in with the
//      targeted login,
//   2. with Shifter in the background, Safari's request goes through the
//      tunnel's proxy to the gateway with the same login,
//   3. after disconnecting, Safari no longer reaches the gateway.
// The phone must be unlocked, on the same network as the Mac. The first run
// asks on the phone to allow the VPN configuration: tap Allow.
//
//   dart run tool/e2e/ios_e2e.dart [-d <udid>] [--host <this Mac's LAN IP>]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../test/support/fake_shifter.dart';
import 'e2e_support.dart';

const _apiPort = 18090;

late String _udid;

Future<String> devicectl(List<String> args) async {
  final r = await Process.run('xcrun', ['devicectl', 'device', ...args, '--device', _udid]);
  return '${r.stdout}${r.stderr}';
}

Future<void> openInSafari(String url) =>
    devicectl(['process', 'launch', '--terminate-existing', '--payload-url', url, 'com.apple.mobilesafari']);

Future<void> main(List<String> args) async {
  String? arg(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final list = (await Process.run('xcrun', ['devicectl', 'list', 'devices'])).stdout.toString();
  final connected = RegExp(r'(\S+) \(UDID\)\s+connected\s.*physical').allMatches(list).map((m) => m[1]!).toList();
  _udid = arg('-d') ?? (connected.isNotEmpty ? connected.first : throw StateError('no iPhone connected'));
  final host = arg('--host') ??
      [for (final i in ['en0', 'en1']) (await Process.run('ipconfig', ['getifaddr', i])).stdout.toString().trim()]
          .firstWhere((ip) => ip.isNotEmpty, orElse: () => throw StateError('no LAN address: pass --host'));
  stdout.writeln('device $_udid, Shifter played on $host');

  final shifter = FakeShifter(host: host, bind: InternetAddress.anyIPv4);
  await shifter.start(apiPort: _apiPort);
  final checks = Checks();
  final check = checks.check;

  final test = await Process.start('flutter', [
    'test', 'integration_test/connect_test.dart', '-d', _udid,
    '--dart-define=SHIFTER_BASE_URL=${shifter.apiUrl}',
    '--dart-define=SHIFTER_IP_CHECK_URL=http://ip-check.test/json',
  ]);
  final testOut = StringBuffer();
  test.stdout.transform(utf8.decoder).listen((s) => testOut.write(s));
  test.stderr.transform(utf8.decoder).listen((s) => testOut.write(s));
  int? exited;
  final testExit = test.exitCode.then((c) => exited = c);

  try {
    shifter.step = 1;
    stdout.writeln('building and installing; if the phone asks to add a VPN configuration, tap Allow');

    // Connected once the app's exit-IP check went through the tunnel's proxy.
    await until(() async {
      if (exited != null) throw StateError('the app half ended (exit $exited) before connecting');
      return shifter.log.any((e) => e.target.contains('ip-check.test'));
    }, 'app connected', seconds: 900);
    final user = shifter.log.firstWhere((e) => e.target.contains('ip-check.test')).user;
    check(RegExp(r'^customer-test-country-de-sid-[a-z0-9]{12}-ttl-600$').hasMatch(user), 'tunnel proxy logs in targeting Germany with a sticky session ($user)');

    // Another app, with Shifter in the background: Safari must reach the gateway.
    var before = shifter.log.length;
    await openInSafari('http://example.test/from-ios-safari');
    var reached = false;
    await until(() async => reached = shifter.log.skip(before).any((e) => e.target.contains('example.test')), 'Safari request', seconds: 30)
        .catchError((_) {});
    check(reached, 'with Shifter in the background, a Safari request went through the tunnel proxy to the gateway');
    if (reached) {
      final e = shifter.log.skip(before).firstWhere((e) => e.target.contains('example.test'));
      check(e.user == user, 'with the same login (${e.user})');
    }
    await devicectl(['process', 'launch', 'io.shifter.shifterApp']);

    shifter.step = 2;
    final code = await testExit.timeout(const Duration(minutes: 3));
    check(code == 0, 'app half passed');
    if (code != 0) stdout.writeln(testOut);

    before = shifter.log.length;
    await openInSafari('http://example.test/after-disconnect');
    await Future<void>.delayed(const Duration(seconds: 10));
    check(!shifter.log.skip(before).any((e) => e.target.contains('example.test')), 'after disconnect, Safari no longer goes through Shifter');
  } catch (e) {
    checks.failures.add('$e');
    stdout
      ..writeln('ERROR $e')
      ..writeln(testOut);
    test.kill();
  } finally {
    await shifter.stop();
  }
  checks.finish('iOS device $_udid');
}
