import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

import 'bypass.dart';
import 'proxy_engine.dart';
import 'system_proxy.dart' show SystemProxyException;

/// iOS: the local proxy can't live in the app (iOS suspends it in the
/// background), so it runs in the Shifter packet tunnel extension
/// (ios/ShifterTunnel/, a Swift twin of [LocalProxy]). The tunnel routes no
/// packets; its network settings point apps at that proxy, as the system
/// proxy does on desktop. This engine hands it the gateway login.
///
/// With a SOCKS5 login the tunnel instead runs in full-device mode: every
/// packet, TCP and UDP, goes through the gateway (ios/ShifterTunnel/
/// FullTunnel.swift). Until the production gateway exposes SOCKS5, that login
/// comes only from a local test build's dart-defines ([_testSocks]).
class TunnelProxyEngine implements ProxyEngine {
  TunnelProxyEngine({this.checkUrl = ipCheckUrl}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopped') _stopped.add(null);
    });
  }

  static const _channel = MethodChannel('shifter/tunnel');
  final String checkUrl;
  final _rejected = StreamController<void>.broadcast();
  final _stopped = StreamController<void>.broadcast();
  int? _port;
  int? get port => _port;
  bool _full = false;

  @override
  bool get supported => true;
  @override
  Stream<void> get rejected => _rejected.stream;
  @override
  Stream<void> get stopped => _stopped.stream;

  /// A tunnel left running by a previous run (the app was closed while
  /// connected) still routes traffic; end it so the app's state is the truth.
  @override
  Future<void> recover() => _channel.invokeMethod('stop');

  @override
  Future<void> apply(GatewayEndpoint endpoint) async {
    try {
      final status = await _channel.invokeMapMethod<String, Object?>('apply', {
        'host': endpoint.host,
        'port': endpoint.port,
        'username': endpoint.username,
        'password': endpoint.password,
        'bypass': expandedBypassList(endpoint.bypassList),
        if (_testSocks(endpoint) case final socks?) 'socks': socks,
      });
      _port = status?['port'] as int?;
      _full = status?['full'] == true;
      if (_port == null) throw SystemProxyException("The connection didn't start. Try again.");
    } on PlatformException catch (e) {
      throw SystemProxyException(e.message ?? 'Could not start the connection.');
    }
  }

  @override
  Future<void> clear() async {
    await _channel.invokeMethod('stop');
    _port = null;
  }

  @override
  Future<ExitInfo> checkExit() async {
    final status = await _channel.invokeMapMethod<String, Object?>('status');
    if (status?['rejected'] == true) _rejected.add(null);
    final port = status?['port'] as int? ?? _port;
    if (port == null) throw StateError('Not connected');
    // Full-device mode: this app's own requests go through the tunnel too.
    if (status?['full'] == true || _full) return checkExitDirect(checkUrl);
    return checkExitThrough(port, checkUrl);
  }
}

/// Local test builds only: the SOCKS5 gateway from
/// `--dart-define-from-file=<private env file>` (SOCKS_HOST, SOCKS_PORT,
/// SOCKS_USER, SOCKS_PASS). The values end up inside that build, so never
/// share it. Session: the plan login's `-sid-` value, so New IP still gives a
/// new exit; rotating plans get one session per connect.
Map<String, Object>? _testSocks(GatewayEndpoint endpoint) {
  const host = String.fromEnvironment('SOCKS_HOST');
  const port = int.fromEnvironment('SOCKS_PORT');
  const user = String.fromEnvironment('SOCKS_USER');
  const pass = String.fromEnvironment('SOCKS_PASS');
  if (host.isEmpty || port == 0 || user.isEmpty) return null;
  final sid = RegExp(r'-sid-([A-Za-z0-9]+)').firstMatch(endpoint.username)?.group(1) ??
      List.generate(10, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[Random.secure().nextInt(36)]).join();
  return {'host': host, 'port': port, 'username': '$user-session-$sid', 'password': pass};
}
