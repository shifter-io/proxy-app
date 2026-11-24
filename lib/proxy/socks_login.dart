import 'dart:math';

import 'local_proxy.dart';

/// The SOCKS5 login for full-device mode: the plan's own gateway login.
/// SOCKS5 and HTTP share the gateway's host, port and username format
/// (targeting and session in the username).
///
/// Development: `--dart-define-from-file=<private file>` with SOCKS_HOST,
/// SOCKS_PORT, SOCKS_USER and SOCKS_PASS points the tunnel at another SOCKS5
/// server, keeping the plan's session id. Those values end up inside that
/// build, so never share it.
Map<String, Object> socksLogin(GatewayEndpoint endpoint) {
  if (_host.isEmpty || _port == 0 || _user.isEmpty) {
    return {'host': endpoint.host, 'port': endpoint.port, 'username': endpoint.username, 'password': endpoint.password};
  }
  final sid = RegExp(r'-sid-([A-Za-z0-9]+)').firstMatch(endpoint.username)?.group(1) ??
      List.generate(10, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[Random.secure().nextInt(36)]).join();
  return {'host': _host, 'port': _port, 'username': '$_user-session-$sid', 'password': _pass};
}

const _host = String.fromEnvironment('SOCKS_HOST');
const _port = int.fromEnvironment('SOCKS_PORT');
const _user = String.fromEnvironment('SOCKS_USER');
const _pass = String.fromEnvironment('SOCKS_PASS');
