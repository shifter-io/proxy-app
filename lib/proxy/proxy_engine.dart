import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../data/store.dart';
import 'bypass.dart';
import 'local_proxy.dart';
import 'system_proxy.dart';

export 'local_proxy.dart' show GatewayEndpoint;

class ExitInfo {
  const ExitInfo(this.ip, {this.country});
  final String ip;

  /// iso2, lowercase
  final String? country;
}

const ipCheckUrl = String.fromEnvironment('SHIFTER_IP_CHECK_URL', defaultValue: 'https://ip-info.com/json');
const _ipCheckTimeout = Duration(seconds: 12);

/// Routes this device through one gateway login (the extension's
/// ProxyController, src/lib/proxy/controller.ts).
abstract class ProxyEngine {
  /// False where the app can't route other apps yet (phones, tablets).
  bool get supported;

  /// Fires when the gateway refuses the login while connected.
  Stream<void> get rejected;

  /// Undo a system proxy left behind by a crash or force-quit.
  Future<void> recover();

  Future<void> apply(GatewayEndpoint endpoint);
  Future<void> clear();

  /// Asks an IP service which address traffic now leaves from.
  Future<ExitInfo> checkExit();
}

/// Desktop: [LocalProxy] on 127.0.0.1 holds the login; the OS proxy points
/// at it. Re-applying (new location, New IP, settings) only swaps the login
/// in the local proxy; the OS settings are touched once per connection.
class LocalProxyEngine implements ProxyEngine {
  LocalProxyEngine(Store store, {SystemProxy? system, this.applySystemProxy = true, this.checkUrl = ipCheckUrl})
      : _system = system ?? SystemProxy.forPlatform(store) {
    _proxy.onRejected = () => _rejected.add(null);
  }

  final SystemProxy _system;

  /// Tests: run the local proxy without touching the OS settings.
  final bool applySystemProxy;

  /// IP service asked through the proxy ([ipCheckUrl]).
  final String checkUrl;

  final _proxy = LocalProxy();
  final _rejected = StreamController<void>.broadcast();
  /// Bypass list the OS settings were last given; null = OS proxy not set.
  List<String>? _systemBypass;

  /// Local proxy port while connected (tests, diagnostics).
  int? get port => _proxy.port;

  @override
  bool get supported => _system.supported || !applySystemProxy;

  @override
  Stream<void> get rejected => _rejected.stream;

  @override
  Future<void> recover() => applySystemProxy ? _system.restoreIfNeeded().catchError((_) {}) : Future.value();

  @override
  Future<void> apply(GatewayEndpoint endpoint) async {
    if (!supported) await _system.enable('127.0.0.1', 0, const []); // throws the explanation
    final port = await _proxy.start();
    _proxy.setEndpoint(endpoint);
    final bypass = expandedBypassList(endpoint.bypassList);
    if (applySystemProxy && _systemBypass?.join('\n') != bypass.join('\n')) {
      try {
        await _system.enable('127.0.0.1', port, bypass);
        _systemBypass = bypass;
      } catch (_) {
        await clear();
        rethrow;
      }
    }
  }

  @override
  Future<void> clear() async {
    if (applySystemProxy) {
      _systemBypass = null;
      await _system.disable();
    }
    await _proxy.stop();
  }

  @override
  Future<ExitInfo> checkExit() async {
    final port = _proxy.port;
    if (port == null) throw StateError('Not connected');
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = _ipCheckTimeout;
    try {
      final req = await client.getUrl(Uri.parse(checkUrl)).timeout(_ipCheckTimeout);
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final res = await req.close().timeout(_ipCheckTimeout);
      final text = await res.transform(utf8.decoder).join().timeout(_ipCheckTimeout);
      if (res.statusCode != 200) throw HttpException('IP check returned ${res.statusCode}');
      final body = jsonDecode(text) as Map<String, dynamic>;
      final ip = body['ip'] as String?;
      if (ip == null || ip.isEmpty) throw const HttpException('IP check returned no address');
      return ExitInfo(ip, country: (body['country'] as String?)?.toLowerCase());
    } finally {
      client.close(force: true);
    }
  }
}

/// Pretends to connect: the preview studio and widget tests.
class MockProxyEngine implements ProxyEngine {
  MockProxyEngine({this.delay = const Duration(milliseconds: 1100)});
  final Duration delay;
  final _rng = Random();
  String _username = '';
  String _exitIp = '';

  @override
  bool get supported => true;
  @override
  Stream<void> get rejected => const Stream.empty();
  @override
  Future<void> recover() async {}

  @override
  Future<void> apply(GatewayEndpoint endpoint) async {
    _username = endpoint.username;
    _exitIp = '';
    await Future<void>.delayed(delay);
  }

  @override
  Future<void> clear() async {}

  /// Same IP until reconnect, except rotating sessions (no sid), which change on every check.
  @override
  Future<ExitInfo> checkExit() async {
    final country = RegExp(r'-country-([a-z]{2})').firstMatch(_username)?[1];
    int o() => _rng.nextInt(254) + 1;
    if (_exitIp.isEmpty || !_username.contains('-sid-')) _exitIp = '203.0.113.${o()}';
    return ExitInfo(_exitIp, country: country);
  }
}
