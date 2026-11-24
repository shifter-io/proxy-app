import 'dart:math';

import 'local_proxy.dart';

/// The gateway's SOCKS5 login for full-device mode, or null when this build
/// has none (then the app uses the proxy-settings mode).
///
/// For now it comes only from a local build's
/// `--dart-define-from-file=<private env file>` (SOCKS_HOST, SOCKS_PORT,
/// SOCKS_USER, SOCKS_PASS). The values end up inside that build, so never
/// share it. Session: the plan login's `-sid-` value, so New IP still gives a
/// new exit; rotating plans get one session per connect.
Map<String, Object>? socksLogin(GatewayEndpoint endpoint) {
  if (!socksConfigured) return null;
  final sid = RegExp(r'-sid-([A-Za-z0-9]+)').firstMatch(endpoint.username)?.group(1) ??
      List.generate(10, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[Random.secure().nextInt(36)]).join();
  return {'host': _host, 'port': _port, 'username': '$_user-session-$sid', 'password': _pass};
}

bool get socksConfigured => _host.isNotEmpty && _port != 0 && _user.isNotEmpty;

const _host = String.fromEnvironment('SOCKS_HOST');
const _port = int.fromEnvironment('SOCKS_PORT');
const _user = String.fromEnvironment('SOCKS_USER');
const _pass = String.fromEnvironment('SOCKS_PASS');
