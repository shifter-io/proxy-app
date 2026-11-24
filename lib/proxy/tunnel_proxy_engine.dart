import 'dart:async';

import 'package:flutter/services.dart';

import 'bypass.dart';
import 'proxy_engine.dart';
import 'socks_login.dart';
import 'system_proxy.dart' show SystemProxyException;

/// iOS: the local proxy can't live in the app (iOS suspends it in the
/// background), so it runs in the Shifter packet tunnel extension
/// (ios/ShifterTunnel/, a Swift twin of [LocalProxy]). The tunnel routes no
/// packets; its network settings point apps at that proxy, as the system
/// proxy does on desktop. This engine hands it the gateway login.
///
/// With a SOCKS5 login the tunnel instead runs in full-device mode: every
/// packet, TCP and UDP, goes through the gateway (ios/ShifterTunnel/
/// FullTunnel.swift); see [socksLogin].
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
        if (socksLogin(endpoint) case final socks?) 'socks': socks,
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
