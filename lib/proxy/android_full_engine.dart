import 'dart:async';

import 'package:flutter/services.dart';

import 'proxy_engine.dart';
import 'socks_login.dart';
import 'system_proxy.dart' show SystemProxyException;

/// Android full-device mode: the VPN slot routes every packet, and a local
/// bridge in the app carries each TCP connection to the gateway over TLS
/// (android/.../FullTunnel.kt, GatewayBridge.kt). Shifter itself is outside
/// the VPN, so the exit check goes through that bridge.
class AndroidFullEngine implements ProxyEngine {
  AndroidFullEngine({this.checkUrl = ipCheckUrl}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopped') _stopped.add(null);
    });
  }

  static const _channel = MethodChannel('shifter/vpn');
  final String checkUrl;
  final _rejected = StreamController<void>.broadcast();
  final _stopped = StreamController<void>.broadcast();

  @override
  bool get supported => true;
  @override
  Stream<void> get rejected => _rejected.stream;
  @override
  Stream<void> get stopped => _stopped.stream;

  /// The VPN slot closes with the app's process, so nothing can be left behind.
  @override
  Future<void> recover() async {}

  @override
  Future<void> apply(GatewayEndpoint endpoint) async {
    try {
      await _channel.invokeMethod('start', {'host': '127.0.0.1', 'port': 0, 'bypass': <String>[], 'socks': socksLogin(endpoint)});
    } on PlatformException catch (e) {
      throw SystemProxyException(e.message ?? 'Could not start the connection.');
    }
  }

  @override
  Future<void> clear() => _channel.invokeMethod('stop');

  @override
  Future<ExitInfo> checkExit() async {
    final status = await _channel.invokeMapMethod<String, Object?>('status');
    if (status?['rejected'] == true) _rejected.add(null);
    final port = status?['port'] as int?;
    if (port == null) throw StateError('Not connected');
    return checkExitThrough(port, checkUrl, secret: status?['secret'] as String?);
  }
}
