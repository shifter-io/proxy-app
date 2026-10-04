import 'dart:async';

import 'package:flutter/services.dart';

import 'system_proxy.dart';

/// Android has no app-settable system proxy; the only way to point other
/// apps at one is a VPN slot (`VpnService`) whose network carries an HTTP
/// proxy (`setHttpProxy`). No packets go through it: apps that follow the
/// proxy send their traffic to the local proxy, which speaks Shifter's proxy
/// protocol to the gateway, exactly as on desktop. Everything else (UDP,
/// apps that ignore the proxy) goes direct. Android 10+.
///
/// Native side: android/app/src/main/kotlin/io/shifter/shifter_app/.
class AndroidSystemProxy extends SystemProxy {
  AndroidSystemProxy() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopped') _stopped.add(call.arguments as String?);
    });
  }

  static const _channel = MethodChannel('shifter/vpn');
  final _stopped = StreamController<String?>.broadcast();

  /// The VPN slot went away without the app asking: the user turned it off in
  /// Settings, or another VPN app took over.
  @override
  Stream<String?> get stopped => _stopped.stream;

  @override
  Future<void> enable(String host, int port, List<String> bypass) async {
    try {
      await _channel.invokeMethod('start', {'host': host, 'port': port, 'bypass': androidExclusionList(bypass)});
    } on PlatformException catch (e) {
      throw SystemProxyException(e.message ?? 'Could not start the connection.');
    }
  }

  @override
  Future<void> disable() => _channel.invokeMethod('stop');

  /// The VPN slot closes with the app's process, so nothing can be left behind.
  @override
  Future<void> restoreIfNeeded() async {}
}

/// Android's proxy exclusion list takes host names and wildcards only. CIDR
/// ranges and bracketed IPv6 are dropped here; the local proxy still sends
/// those addresses direct itself.
List<String> androidExclusionList(List<String> bypass) =>
    [for (final r in bypass) if (RegExp(r'^[A-Za-z0-9*._-]+$').hasMatch(r)) r];
