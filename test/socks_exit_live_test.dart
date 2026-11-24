import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/proxy/android_full_engine.dart';
import 'package:shifter_app/proxy/proxy_engine.dart';

/// Live check of the SOCKS5 exit lookup. Needs a private env file with
/// SOCKS_HOST, SOCKS_PORT, SOCKS_USER and SOCKS_PASS:
///   SHIFTER_SOCKS_ENV_FILE=<file> flutter test test/socks_exit_live_test.dart
void main() {
  final path = Platform.environment['SHIFTER_SOCKS_ENV_FILE'];
  test('exit IP through SOCKS5 stays on one session', () async {
    final env = {
      for (final line in File(path!).readAsLinesSync())
        if (line.contains('=')) line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
    };
    final session = 'chk${DateTime.now().millisecondsSinceEpoch}';
    final login = <String, Object>{
      'host': env['SOCKS_HOST']!,
      'port': int.parse(env['SOCKS_PORT']!),
      'username': '${env['SOCKS_USER']}-session-$session',
      'password': env['SOCKS_PASS']!,
    };
    final first = await checkExitThroughSocks(login, ipCheckUrl);
    final second = await checkExitThroughSocks(login, ipCheckUrl);
    expect(first.ip, isNotEmpty);
    expect(second.ip, first.ip, reason: 'same session, same exit');
  }, skip: path == null ? 'Set SHIFTER_SOCKS_ENV_FILE.' : false, timeout: const Timeout(Duration(seconds: 60)));
}
