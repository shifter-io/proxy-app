// Local proxy, bypass rules and username building, against the stand-in gateway.
//   flutter test test/proxy_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/data/format.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/proxy/bypass.dart';
import 'package:shifter_app/proxy/local_proxy.dart';

import 'support/fake_shifter.dart';

void main() {
  group('bypass rules', () {
    test('normalizes what users type', () {
      expect(normalizeBypassRule('https://Example.com/path?q'), 'example.com');
      expect(normalizeBypassRule('*.corp.example.com'), '*.corp.example.com');
      expect(normalizeBypassRule('192.168.0.0/16'), '192.168.0.0/16');
      expect(normalizeBypassRule('10.0.0.300'), isNull);
      expect(normalizeBypassRule('not a host'), isNull);
    });

    test('matches hosts, wildcards and CIDR ranges', () {
      expect(matchesBypassRule('example.com', '*.example.com'), isTrue);
      expect(matchesBypassRule('a.b.example.com', '*.example.com'), isTrue);
      expect(matchesBypassRule('badexample.com', '*.example.com'), isFalse);
      expect(matchesBypassRule('192.168.4.20', '192.168.0.0/16'), isTrue);
      expect(matchesBypassRule('203.0.113.1', '192.168.0.0/16'), isFalse);
      expect(isBypassed('api.shifter.io', const []), isTrue, reason: 'the API must stay reachable');
      expect(isBypassed('example.org', const []), isFalse);
    });
  });

  test('builds the residential username like the panel endpoint builder', () {
    const t = ResidentialTarget(
      country: GeoCountry('us', 'United States'),
      region: GeoRegion('new_york', 'New York'),
      city: GeoCity('new_york', 'New York'),
      asn: GeoAsn(7922, 'Comcast'),
    );
    expect(
      buildResidentialUsername('customer-example', t, const ProxySettings(ttlSeconds: 600, strict: true), sid: 'abc123'),
      'customer-example-country-us-region-new_york-city-new_york-asn-7922-sid-abc123-ttl-600-strict-true',
    );
    expect(
      buildResidentialUsername('customer-example', ResidentialTarget.worldwide, const ProxySettings(sessionMode: SessionMode.rotating), sid: 'x'),
      'customer-example',
    );
  });

  // The same tests run against the Dart proxy (desktop, Android) and, on a
  // Mac, the Swift proxy inside the iOS packet tunnel.
  for (final swift in [false, if (Platform.isMacOS) true]) {
    group(swift ? 'iOS tunnel proxy (Swift)' : 'local proxy', () {
      late FakeShifter shifter;
      late _ProxyUnderTest proxy;

      GatewayEndpoint endpoint(String user, {List<String> bypass = const []}) => GatewayEndpoint(
            host: '127.0.0.1',
            port: shifter.gatewayPort,
            username: user,
            password: fakePassword,
            bypassList: bypass,
          );

      setUp(() async {
        shifter = FakeShifter();
        await shifter.start();
        final first = endpoint('customer-test-country-us');
        proxy = swift ? await _SwiftProxy.start(first) : await _DartProxy.start(first);
      });

      tearDown(() async {
        await proxy.stop();
        await shifter.stop();
      });

      HttpClient client() => HttpClient()..findProxy = ((_) => 'PROXY 127.0.0.1:${proxy.port}');

      Future<String> get(String url, {String method = 'GET', String? body}) async {
        final c = client();
        try {
          final req = await c.openUrl(method, Uri.parse(url));
          if (body != null) req.write(body);
          final res = await req.close();
          return '${res.statusCode} ${await utf8.decoder.bind(res).join()}';
        } finally {
          c.close(force: true);
        }
      }

      /// CONNECT, then plain HTTP inside the tunnel (TLS isn't the proxy's business).
      Future<String> tunnel(String authority) async {
        final s = await Socket.connect('127.0.0.1', proxy.port);
        final out = StringBuffer();
        final done = Completer<void>();
        s.listen((d) => out.write(latin1.decode(d)), onDone: done.complete);
        s.write('CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n\r\n');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        s.write('GET /inside HTTP/1.1\r\nHost: $authority\r\nConnection: close\r\n\r\n');
        await done.future.timeout(const Duration(seconds: 5));
        s.destroy();
        return out.toString();
      }

      test('adds the gateway login to plain HTTP requests', () async {
        expect(await get('http://example.test/hello'), '200 origin GET /hello ');
        expect(shifter.log.single, (user: 'customer-test-country-us', target: 'HTTP http://example.test/hello'));
      });

      test('forwards request bodies', () async {
        expect(await get('http://example.test/upload', method: 'POST', body: 'payload'), '200 origin POST /upload payload');
      });

      test('tunnels CONNECT through the gateway with the login', () async {
        final res = await tunnel('example.test:443');
        expect(res, startsWith('HTTP/1.1 200 Connection Established'));
        expect(res, contains('origin GET /inside'));
        expect(shifter.log.single, (user: 'customer-test-country-us', target: 'example.test:443'));
      });

      test('a new login applies to the next request, no restart needed', () async {
        await get('http://example.test/a');
        await proxy.setEndpoint(endpoint('customer-test-country-de-sid-n3w'));
        await get('http://example.test/b');
        expect(shifter.log.map((e) => e.user), ['customer-test-country-us', 'customer-test-country-de-sid-n3w']);
      });

      test('a new login closes tunnels still on the old exit', () async {
        final s = await Socket.connect('127.0.0.1', proxy.port);
        final closed = Completer<void>();
        s.listen((_) {}, onDone: closed.complete, onError: (_) => closed.complete());
        s.write('CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await proxy.setEndpoint(endpoint('customer-test-country-fr'));
        await closed.future.timeout(const Duration(seconds: 3));
        s.destroy();
      });

      test('bypassed hosts go direct, never to the gateway', () async {
        await proxy.setEndpoint(endpoint('customer-test', bypass: ['*.example.test']));
        // localhost is always direct; the user's rule covers sub.example.test.
        expect(await get('http://localhost:${shifter.origin.port}/direct'), '200 origin GET /direct ');
        expect(shifter.log, isEmpty);
      });

      test('a client that half-closes after its request still gets the answer', () async {
        final s = await Socket.connect('127.0.0.1', proxy.port);
        final out = StringBuffer();
        final done = Completer<void>();
        s.listen((d) => out.write(latin1.decode(d)), onDone: done.complete);
        s.write('GET http://example.test/half HTTP/1.1\r\nHost: example.test\r\n\r\n');
        await s.flush();
        await s.close(); // shutdown(SHUT_WR)
        await done.future.timeout(const Duration(seconds: 5));
        expect(out.toString(), contains('origin GET /half'));
      });

      test('500 tunnels, 50 at a time, leave nothing open behind', () async {
        for (var round = 0; round < 10; round++) {
          final results = await Future.wait([for (var i = 0; i < 50; i++) tunnel('example.test:443')]);
          expect(results.every((r) => r.contains('origin GET /inside')), isTrue);
        }
        for (var i = 0; i < 40 && await proxy.openConnections > 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(await proxy.openConnections, 0);
      });

      test('a refused login reports rejected and answers 502, not 407', () async {
        shifter.rejectAll = true;
        expect(await get('http://example.test/x'), startsWith('502'));
        expect(await proxy.rejected, isTrue);
      });
    });
  }
}

/// One proxy implementation, driven the same way by every test above.
abstract class _ProxyUnderTest {
  int get port;
  Future<void> setEndpoint(GatewayEndpoint e);
  Future<bool> get rejected;
  Future<int> get openConnections;
  Future<void> stop();
}

class _DartProxy implements _ProxyUnderTest {
  _DartProxy._(this._proxy);
  final LocalProxy _proxy;
  var _rejected = false;

  static Future<_DartProxy> start(GatewayEndpoint e) async {
    late final _DartProxy p;
    p = _DartProxy._(LocalProxy(onRejected: () => p._rejected = true));
    await p._proxy.start();
    p._proxy.setEndpoint(e);
    return p;
  }

  @override
  int get port => _proxy.port!;
  @override
  Future<void> setEndpoint(GatewayEndpoint e) async => _proxy.setEndpoint(e);
  @override
  Future<bool> get rejected async => _rejected;
  @override
  Future<int> get openConnections async => _proxy.openConnections;
  @override
  Future<void> stop() => _proxy.stop();
}

/// ios/ShifterTunnel/TunnelProxy.swift, built as a Mac program
/// (tool/e2e/tunnel_proxy/main.swift) and driven over stdin.
class _SwiftProxy implements _ProxyUnderTest {
  _SwiftProxy._(this._process, this._lines, this.port);
  final Process _process;
  final StreamIterator<String> _lines;
  @override
  final int port;

  static const _binary = 'build/tunnel_proxy';
  static const _sources = ['ios/ShifterTunnel/TunnelProxy.swift', 'tool/e2e/tunnel_proxy/main.swift'];

  static Future<void> _build() async {
    final bin = File(_binary);
    final built = bin.existsSync() ? bin.lastModifiedSync() : null;
    if (built != null && _sources.every((s) => File(s).lastModifiedSync().isBefore(built))) return;
    final r = await Process.run('swiftc', ['-O', ..._sources, '-o', _binary]);
    if (r.exitCode != 0) throw StateError('swiftc failed: ${r.stderr}');
  }

  static Future<_SwiftProxy> start(GatewayEndpoint e) async {
    await _build();
    final p = await Process.start(_binary, [e.host, '${e.port}', e.username, e.password, expandedBypassList(e.bypassList).join(',')]);
    final lines = StreamIterator(p.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    if (!await lines.moveNext()) throw StateError('tunnel_proxy exited');
    final port = int.parse(RegExp(r'^PORT (\d+)$').firstMatch(lines.current)![1]!);
    return _SwiftProxy._(p, lines, port);
  }

  Future<String> _command(String line) async {
    _process.stdin.writeln(line);
    await _lines.moveNext();
    return _lines.current;
  }

  Future<Map<String, dynamic>> _status() async => jsonDecode(await _command('status')) as Map<String, dynamic>;

  @override
  Future<void> setEndpoint(GatewayEndpoint e) => _command('login ${e.username} ${expandedBypassList(e.bypassList).join(',')}');
  @override
  Future<bool> get rejected async => (await _status())['rejected'] as bool;
  @override
  Future<int> get openConnections async => (await _status())['connections'] as int;
  @override
  Future<void> stop() async {
    _process.kill();
    await _process.exitCode;
  }
}
