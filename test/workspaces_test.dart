import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/data/api.dart';
import 'package:shifter_app/data/geo_catalog.dart';
import 'package:shifter_app/data/http_api.dart';
import 'package:shifter_app/data/mock_api.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/data/store.dart';
import 'package:shifter_app/proxy/proxy_engine.dart';
import 'package:shifter_app/state/app_controller.dart';

import 'support/fake_shifter.dart';

const personal = {'id': 'personal', 'name': 'Personal', 'role': 'owner', 'personal': true};
const team = {'id': 'team', 'name': 'Acme Ltd', 'role': 'viewer', 'personal': false};
const empty = {'id': 'empty', 'name': 'Workspace without plans', 'role': 'billing', 'personal': false};

void workspaceFixture(FakeShifter shifter) {
  final plans = shifter.memberships;
  final config = shifter.proxyConfig;
  final usage = shifter.usage;
  final res = (config['plans'] as List).first as Map;
  shifter.membershipsResponse = {
    'pqqD': {...plans['pqqD'], 'workspace': personal},
    'team-plan': {...plans['pqqD'], 'workspace': team},
    'zqJ4': {...plans['zqJ4'], 'workspace': team},
  };
  shifter.proxyConfigResponse = {
    'workspaces': [empty, team, personal],
    'plans': [
      {...res, 'workspace': personal},
      {...res, 'hash': 'team-plan', 'username': 'customer-team', 'workspace': team},
      {...(config['plans'] as List)[1], 'workspace': team},
    ],
  };
  shifter.usageResponse = {'memberships': [
    ...(usage['memberships'] as List),
    {...(usage['memberships'] as List).first, 'id': 'team-plan', 'quota_bytes': 10000000000,
      'used_bytes': 2000000000, 'remaining_bytes': 8000000000},
  ]};
  shifter.requireWorkspaceOptIn = true;
}

Future<void> until(bool Function() check) async {
  for (var i = 0; i < 200 && !check(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(check(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  setUpAll(GeoCatalog.load);
  late FakeShifter shifter;
  late HttpShifterApi api;
  setUp(() async {
    shifter = FakeShifter();
    await shifter.start();
    workspaceFixture(shifter);
    api = HttpShifterApi(baseUrl: shifter.apiUrl);
  });
  tearDown(() => shifter.stop());

  test('exact workspace opt-in, both auth headers, unfiltered usage and sorted empty teams', () async {
    await api.verifyApiKey(fakeKey);
    final catalog = await api.memberships();
    expect(catalog.workspaces.map((w) => w.id), ['personal', 'team', 'empty']);
    expect(catalog.memberships.map((m) => m.planName), ['Spark', 'Spark', '4 ISP Proxies']);
    final m = catalog.memberships[1] as ResidentialMembership;
    expect(m.displayName, 'Spark (Acme Ltd)');
    expect(m.canManage, isFalse);
    expect(m.traffic!.remainingBytes, 8000000000);
    expect(catalog.memberships.first.displayName, 'Spark');
    expect(shifter.apiRequests.every((r) => r.bearer && r.apiKey), isTrue);
    expect(shifter.apiRequests.where((r) => r.uri.path.endsWith('/usage')).single.uri.query, '');
    expect(shifter.apiRequests.where((r) => r.uri.path.endsWith('/proxy-config')).single.uri.query, 'workspaces=all');
  });

  test('workspace metadata falls back to config and catalog merges membership-only teams', () async {
    (shifter.membershipsResponse!['team-plan'] as Map).remove('workspace');
    shifter.proxyConfigResponse!['workspaces'] = [empty];
    await api.verifyApiKey(fakeKey);
    final catalog = await api.memberships();
    expect(catalog.memberships[1].workspace!.id, 'team');
    expect(catalog.workspaces.map((w) => w.id), ['personal', 'team', 'empty']);
  });

  test('legacy responses and personal-only accounts keep plain names', () async {
    shifter.membershipsResponse = null;
    shifter.proxyConfigResponse = null;
    await api.verifyApiKey(fakeKey);
    final catalog = await api.memberships();
    expect(catalog.workspaces, isEmpty);
    expect(catalog.memberships.every((m) => m.workspace == null && m.displayName == m.planName), isTrue);
  });

  for (final role in ['viewer', 'billing', 'admin', 'owner']) {
    test('$role can connect with fresh team credentials and team ISP targets', () async {
      (shifter.membershipsResponse!['team-plan'] as Map)['workspace'] = {...team, 'role': role};
      final store = MemoryStore();
      final app = AppController(api: api, store: store,
          engine: LocalProxyEngine(store, applySystemProxy: false, checkUrl: 'http://ip-check.test/json'));
      addTearDown(() async { await app.shutdown(); app.dispose(); });
      await until(() => app.phase == AuthPhase.signedOut);
      await app.signIn(await api.verifyApiKey(fakeKey));
      await app.selectMembership('team-plan');
      expect(app.activeMembership!.canManage, role == 'admin' || role == 'owner');
      await app.setTarget('team-plan', const ResidentialTarget(country: GeoCountry('de', 'Germany')));
      await app.connect();
      expect(app.isConnected, isTrue, reason: app.connection.message);
      expect(shifter.log.last.user, startsWith('customer-team-country-de-'));
      await app.selectMembership('pqqD');
      expect(app.connection.status, ConnectionStatus.disconnected);
      expect((app.engine as LocalProxyEngine).port, isNull);
      expect(app.targetFor('pqqD'), isNull);
      await app.selectMembership('team-plan');
      expect((app.targetFor('team-plan') as ResidentialTarget).country!.code, 'de');
      await app.selectMembership('zqJ4');
      final ips = await api.ispIps('zqJ4');
      await app.setTarget('zqJ4', IspTarget(ips.first));
      await app.connect();
      expect(app.isConnected, isTrue);
      expect(shifter.log.last.user, ips.first.id);
      expect(shifter.apiRequests.where((r) => r.uri.path.endsWith('/proxy-config')).every((r) => r.uri.query == 'workspaces=all'), isTrue);
    });
  }

  test('single team plan auto-selects, survives restart, and keeps empty workspaces reachable', () async {
    shifter.membershipsResponse!.removeWhere((id, _) => id != 'team-plan');
    final store = MemoryStore();
    final app = AppController(api: api, store: store);
    addTearDown(app.dispose);
    await until(() => app.phase == AuthPhase.signedOut);
    await app.signIn(await api.verifyApiKey(fakeKey));
    expect(app.activeId, 'team-plan');
    expect(app.canSwitchMembership, isTrue);
    final restored = AppController(api: HttpShifterApi(baseUrl: shifter.apiUrl), store: store);
    addTearDown(restored.dispose);
    await until(() => restored.activeMembership != null);
    expect(restored.activeId, 'team-plan');
    expect(restored.workspaces, hasLength(3));
    await restored.signOut();
    expect(restored.workspaces, isEmpty);
  });

  test('revoked access disconnects, clears saved selection and rejects fresh credentials', () async {
    final store = MemoryStore();
    final app = AppController(api: api, store: store,
        engine: LocalProxyEngine(store, applySystemProxy: false, checkUrl: 'http://ip-check.test/json'));
    addTearDown(() async { await app.shutdown(); app.dispose(); });
    await until(() => app.phase == AuthPhase.signedOut);
    await app.signIn(await api.verifyApiKey(fakeKey));
    await app.selectMembership('team-plan');
    await app.connect();
    expect(app.isConnected, isTrue);
    shifter.membershipsResponse = {};
    shifter.proxyConfigResponse = {'plans': [], 'workspaces': [personal]};
    await app.reloadMemberships();
    expect(app.connection.status, ConnectionStatus.disconnected);
    expect((app.engine as LocalProxyEngine).port, isNull);
    expect(store.activeMembership, isNull);
    await app.selectMembership('team-plan');
    await app.connect();
    expect(app.activeId, isNull);
    await expectLater(api.credentials('team-plan'), throwsA(isA<ApiException>()));
  });

  test('slow catalog from a signed-out account cannot repopulate workspaces', () async {
    final delayed = _DelayedApi();
    final app = AppController(api: delayed);
    addTearDown(app.dispose);
    await until(() => app.phase == AuthPhase.signedOut);
    final signingIn = app.signIn(Session(user: const User(id: 'a', email: 'a@example.com'), apiKey: fakeKey, createdAt: DateTime.now()));
    await until(() => delayed.requested);
    await app.signOut();
    delayed.result.complete(MembershipCatalog(memberships: [], workspaces: [Workspace.fromJson(team)!]));
    await signingIn;
    expect(app.phase, AuthPhase.signedOut);
    expect(app.workspaces, isEmpty);
    expect(app.memberships, isNull);
  });
}

class _DelayedApi extends MockShifterApi {
  final result = Completer<MembershipCatalog>();
  bool requested = false;
  @override
  Future<MembershipCatalog> memberships() { requested = true; return result.future; }
}
