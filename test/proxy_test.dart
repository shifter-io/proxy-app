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

  group('local proxy', () {
    late FakeShifter shifter;
    late LocalProxy proxy;
    var rejected = 0;

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
      rejected = 0;
      proxy = LocalProxy(onRejected: () => rejected++);
      await proxy.start();
      proxy.setEndpoint(endpoint('customer-test-country-us'));
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
      final s = await Socket.connect('127.0.0.1', proxy.port!);
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
      proxy.setEndpoint(endpoint('customer-test-country-de-sid-n3w'));
      await get('http://example.test/b');
      expect(shifter.log.map((e) => e.user), ['customer-test-country-us', 'customer-test-country-de-sid-n3w']);
    });

    test('a new login closes tunnels still on the old exit', () async {
      final s = await Socket.connect('127.0.0.1', proxy.port!);
      final closed = Completer<void>();
      s.listen((_) {}, onDone: closed.complete, onError: (_) => closed.complete());
      s.write('CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      proxy.setEndpoint(endpoint('customer-test-country-fr'));
      await closed.future.timeout(const Duration(seconds: 3));
      s.destroy();
    });

    test('bypassed hosts go direct, never to the gateway', () async {
      proxy.setEndpoint(endpoint('customer-test', bypass: ['*.example.test']));
      // localhost is always direct; the user's rule covers sub.example.test.
      expect(await get('http://localhost:${shifter.origin.port}/direct'), '200 origin GET /direct ');
      expect(shifter.log, isEmpty);
    });

    test('a refused login reports rejected and answers 502, not 407', () async {
      shifter.rejectAll = true;
      expect(await get('http://example.test/x'), startsWith('502'));
      expect(rejected, 1);
    });
  });
}
