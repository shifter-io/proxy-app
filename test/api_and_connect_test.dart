// HTTP API mapping and the full connect flow against the stand-in Shifter.
// The OS proxy is left alone (applySystemProxy: false); everything else is real.
//   flutter test test/api_and_connect_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/data/api.dart';
import 'package:shifter_app/data/format.dart';
import 'package:shifter_app/data/geo_catalog.dart';
import 'package:shifter_app/data/http_api.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/data/store.dart';
import 'package:shifter_app/proxy/android_system_proxy.dart';
import 'package:shifter_app/proxy/bypass.dart';
import 'package:shifter_app/proxy/proxy_engine.dart';
import 'package:shifter_app/proxy/system_proxy.dart';
import 'package:shifter_app/state/app_controller.dart';
import 'package:shifter_app/theme/theme.dart';
import 'package:shifter_app/ui/screens/home_screen.dart';
import 'package:shifter_app/ui/widgets/membership_card.dart';

import 'support/fake_shifter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HttpClient request with 400; these tests
  // talk to a real (local) server.
  HttpOverrides.global = null;
  late FakeShifter shifter;

  setUp(() async {
    shifter = FakeShifter();
    await shifter.start();
  });
  tearDown(() => shifter.stop());

  group('HttpShifterApi', () {
    late HttpShifterApi api;
    setUp(() => api = HttpShifterApi(baseUrl: shifter.apiUrl, store: MemoryStore()));

    void residentialUsage(Map<String, dynamic> fields) {
      final response = shifter.usage;
      final row = (response['memberships'] as List).first as Map<String, dynamic>;
      row.addAll(fields);
      shifter.usageResponse = response;
    }

    test('rejects a wrong key as unauthorized', () async {
      await expectLater(
        api.verifyApiKey('x' * 40),
        throwsA(isA<ApiException>().having((e) => e.unauthorized, 'unauthorized', isTrue)),
      );
    });

    test('signs in with the key and names the user', () async {
      final s = await api.verifyApiKey('  $fakeKey ');
      expect(s.apiKey, fakeKey);
      expect(s.user.name, 'Test User');
      expect(s.user.walletBalance, 10);
    });

    test('joins memberships, usage and proxy-config', () async {
      await api.verifyApiKey(fakeKey);
      final list = await api.memberships();
      expect(list.map((m) => m.id), ['pqqD', 'zqJ4', 'old1', 'unpd'], reason: 'legacy plans and other products are hidden');

      final res = list[0] as ResidentialMembership;
      expect(res.planName, 'Spark');
      expect(res.status, MembershipStatus.active);
      expect(res.pool, ResidentialPool.full);
      expect(res.traffic!.remainingBytes, 3750000000);
      expect(res.renewsAt, isNotNull);
      expect(res.entryPoints.map((e) => e.key), ['auto', 'fra']);
      expect(res.manageUrl, '${shifter.apiUrl}/panel/membership/pqqD');

      final isp = list[1] as IspMembership;
      expect(isp.ipCount, 3);
      expect(isp.countries, ['us', 'ro']);

      expect(list[2].status, MembershipStatus.expired, reason: 'ended plans stay, folded under Expired');

      final unpaid = list[3] as ResidentialMembership;
      expect(unpaid.status, MembershipStatus.suspended, reason: 'not in proxy-config yet');
      expect(unpaid.usable, isFalse);
      expect(unpaid.pool, ResidentialPool.country);
    });

    test('lists ISP IPs by carrier, numbered, without addresses', () async {
      await api.verifyApiKey(fakeKey);
      final ips = await api.ispIps('zqJ4');
      final comcast = (await GeoCatalog.load()).asnName(7922);
      expect(ips.map((ip) => ip.label), ['$comcast #1', '$comcast #2', 'Test Carrier RO'],
          reason: 'AS7922 comes from the catalog, AS999999 from the geo endpoint');
      expect(ips.first.country, 'us');
    });

    testWidgets('missing residential traffic never appears as unlimited; ISP does', (tester) async {
      // Reproduce the live residential response, including the misleading
      // metered flag and wallet allowance (which is not the plan's balance).
      residentialUsage({
        'metered': false,
        'quota_bytes': null,
        'used_bytes': null,
        'remaining_bytes': null,
        'overage_billed': true,
        'wallet_covers_gb': 219.7,
      });
      final plans = (await tester.runAsync(() async {
        await api.verifyApiKey(fakeKey);
        return api.memberships();
      }))!;
      final res = plans.first as ResidentialMembership;
      expect(res.traffic, isNull);

      Future<void> show(Membership m) => tester.pumpWidget(MaterialApp(
        theme: buildShifterTheme(),
        home: Scaffold(body: Column(children: [
          StatsCard(m: m, settings: const ProxySettings(), onSession: () {}),
          UsageLine(m),
        ])),
      ));

      await show(res);
      expect(find.text('Unlimited'), findsNothing);
      expect(find.text('TRAFFIC LEFT'), findsOneWidget);
      expect(find.text('Traffic left'), findsOneWidget);
      expect(find.text('Usage not available yet'), findsOneWidget);
      expect(find.text('—'), findsNWidgets(2));

      await show(plans.whereType<IspMembership>().first);
      expect(find.text('Unlimited'), findsNWidgets(2));
      expect(find.text('Usage not available yet'), findsNothing);
    });

    test('residential byte figures take precedence over an incorrect metered flag', () async {
      residentialUsage({'metered': false});
      await api.verifyApiKey(fakeKey);
      final res = (await api.memberships()).first as ResidentialMembership;
      expect(res.traffic!.totalBytes, 5000000000);
      expect(res.traffic!.usedBytes, 1250000000);
      expect(trafficLeft(res)!.left, 3750000000);
    });

    test('a quota without usage or a remaining balance is unavailable, not unused', () async {
      residentialUsage({'used_bytes': null, 'remaining_bytes': null});
      await api.verifyApiKey(fakeKey);
      final res = (await api.memberships()).first as ResidentialMembership;
      expect(res.traffic, isNull);
    });

    test('a supplied remaining balance is preserved when used bytes are absent', () async {
      residentialUsage({'used_bytes': null});
      await api.verifyApiKey(fakeKey);
      final res = (await api.memberships()).first as ResidentialMembership;
      expect(res.traffic!.usedBytes, 1250000000);
      expect(trafficLeft(res)!.left, 3750000000);
    });

    test('a zero residential balance stays zero', () async {
      residentialUsage({'used_bytes': 5000000000, 'remaining_bytes': 0});
      await api.verifyApiKey(fakeKey);
      final res = (await api.memberships()).first as ResidentialMembership;
      expect(trafficLeft(res), (left: 0, ratio: 0.0, total: 5000000000));
    });

    test('overage without a remaining field displays zero remaining traffic', () async {
      residentialUsage({'used_bytes': 6250000000, 'remaining_bytes': null});
      await api.verifyApiKey(fakeKey);
      final res = (await api.memberships()).first as ResidentialMembership;
      expect(trafficLeft(res), (left: 0, ratio: 0.0, total: 5000000000));
    });

    test('hands out gateway credentials', () async {
      await api.verifyApiKey(fakeKey);
      final c = await api.credentials('pqqD');
      expect((c.host, c.port, c.username, c.password), ('127.0.0.1', shifter.gatewayPort, 'customer-test', fakePassword));
      expect(c.stickySessions, isTrue);
      await expectLater(api.credentials('unpd'), throwsA(isA<ApiException>()));
    });
  });

  group('AppController', () {
    late MemoryStore store;
    late AppController app;

    AppController build() => AppController(
          api: HttpShifterApi(baseUrl: shifter.apiUrl, store: store),
          store: store,
          engine: LocalProxyEngine(store, applySystemProxy: false, checkUrl: 'http://ip-check.test/json'),
        );

    Future<void> until(bool Function() ok, [String what = 'condition']) async {
      for (var i = 0; i < 200 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(ok(), isTrue, reason: 'timed out waiting for $what');
    }

    setUp(() async {
      store = MemoryStore();
      app = build();
      await until(() => app.phase == AuthPhase.signedOut, 'boot');
      await app.signIn(await app.api.verifyApiKey(fakeKey));
    });
    tearDown(() async {
      await app.shutdown();
      app.dispose();
    });

    test('remembers the session and picks nothing when several plans are usable', () async {
      expect(store.session?.apiKey, fakeKey);
      expect(app.memberships, hasLength(4));
      expect(app.activeId, isNull);
    });

    test('connects residential with the targeting in the username and shows the exit', () async {
      await app.selectMembership('pqqD');
      await app.setTarget('pqqD', const ResidentialTarget(country: GeoCountry('de', 'Germany'), city: GeoCity('berlin', 'Berlin')));
      await app.connect();
      expect(app.connection.status, ConnectionStatus.connected, reason: app.connection.message);
      final user = shifter.log.last.user;
      expect(user, matches(RegExp(r'^customer-test-country-de-city-berlin-sid-[a-z0-9]{12}-ttl-600$')));
      expect(app.connection.exitIp, shifter.exitIpFor(user));
      expect(app.connection.exitCountry, 'de');
      expect(store.targets['pqqD'], isA<ResidentialTarget>());

      // New IP: a fresh sid.
      await app.newIp();
      final next = shifter.log.last.user;
      expect(next, isNot(user));
      expect(next, startsWith('customer-test-country-de-city-berlin-sid-'));

      // Settings apply live on the same sticky session.
      await app.updateSettings(app.settings.copyWith(strict: true));
      final strict = shifter.log.last.user;
      expect(strict, '$next-strict-true');

      // Entry point: the chosen gateway region replaces the host.
      expect(toEndpoint(await app.api.credentials('pqqD'), app.connection.target!,
              app.settings.copyWith(entryPoint: () => 'fra'), 'sid1').host, 'fra.localhost');

      await app.disconnect();
      expect(app.connection.status, ConnectionStatus.disconnected);
    });

    test('connects an ISP IP with its own username', () async {
      await app.selectMembership('zqJ4');
      final ips = await app.api.ispIps('zqJ4');
      await app.setTarget('zqJ4', IspTarget(ips[1]));
      await app.connect();
      expect(app.connection.status, ConnectionStatus.connected, reason: app.connection.message);
      expect(shifter.log.last.user, 'us-new_york-new_york-as7922-BBBBB');
    });

    test('a refused login ends in a clear error', () async {
      await app.selectMembership('pqqD');
      shifter.rejectAll = true;
      await app.connect();
      expect(app.connection.status, ConnectionStatus.error);
      expect(app.connection.message, contains('rejected the proxy login'));
    });

    test('a revoked key signs out', () async {
      await app.selectMembership('pqqD');
      app.api.useSession(Session(user: app.session!.user, apiKey: 'r' * 40, createdAt: DateTime.now()));
      await app.connect();
      expect(app.phase, AuthPhase.signedOut);
      expect(store.session, isNull);
    });

    test('restores the session, plan and target on the next launch', () async {
      await app.selectMembership('pqqD');
      await app.setTarget('pqqD', const ResidentialTarget(country: GeoCountry('fr', 'France')));
      final again = build();
      await until(() => again.activeMembership != null, 'restored plan');
      expect(again.session?.user.email, 't@example.com');
      expect((again.targetFor('pqqD') as ResidentialTarget).country?.code, 'fr');
      again.dispose();
    });

    test('the OS dropping the routing (VPN turned off in Settings) disconnects', () async {
      final os = _FakeSystemProxy();
      final routed = AppController(
        api: HttpShifterApi(baseUrl: shifter.apiUrl, store: store),
        store: store,
        engine: LocalProxyEngine(store, system: os, checkUrl: 'http://ip-check.test/json'),
      );
      addTearDown(routed.dispose);
      await until(() => routed.phase == AuthPhase.signedIn, 'boot');
      await routed.selectMembership('pqqD');
      await routed.setTarget('pqqD', const ResidentialTarget(country: GeoCountry('de', 'Germany')));
      await routed.connect();
      expect(routed.connection.status, ConnectionStatus.connected, reason: routed.connection.message);
      expect(os.enabled, isTrue);

      os.stop('revoked');
      await until(() => routed.connection.status == ConnectionStatus.disconnected && !os.enabled, 'disconnected');
      expect((routed.engine as LocalProxyEngine).port, isNull, reason: 'local proxy stopped');
    });
  });

  test('Android proxy exclusion list keeps only host names and wildcards', () {
    expect(androidExclusionList(expandedBypassList(ProxySettings.defaultBypassList)),
        containsAll(['localhost', '127.0.0.1', '*.local', 'local', '*.shifter.io', 'shifter.io']));
    expect(androidExclusionList(['10.0.0.0/8', '[::1]', 'a b', '*.example.com']), ['*.example.com']);
  });
}

class _FakeSystemProxy extends SystemProxy {
  final _stopped = StreamController<String?>.broadcast();
  bool enabled = false;

  void stop(String reason) {
    enabled = false;
    _stopped.add(reason);
  }

  @override
  Stream<String?> get stopped => _stopped.stream;
  @override
  Future<void> enable(String host, int port, List<String> bypass) async => enabled = true;
  @override
  Future<void> disable() async => enabled = false;
}
