import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/update/adapters/update_adapter.dart';
import 'package:shifter_app/update/update_config.dart';
import 'package:shifter_app/update/update_coordinator.dart';
import 'package:shifter_app/update/update_models.dart';
import 'package:shifter_app/update/update_repository.dart';
import 'package:shifter_app/update/update_store.dart';

import 'update_security_test.dart' show identity, releaseJson;

class FakeAdapter implements UpdateAdapter {
  bool allowed = true;
  int installed = 0;
  String? downloadOperationId;
  String? installOperationId;
  Map<String, dynamic> nativeState = {};
  @override
  Future<InstalledIdentity> identity() async => throw UnimplementedError();
  @override
  Future<UpdateCapabilities> capabilities() async =>
      const UpdateCapabilities(install: true);
  @override
  Future<bool> eligible(Release release, {required bool automatic}) async =>
      allowed;
  @override
  Future<void> prepare(Release release, String? path) async {}
  @override
  Future<void> install(
    Release release,
    String? path,
    String operationId,
  ) async {
    installed++;
    installOperationId = operationId;
  }

  @override
  Future<Map<String, dynamic>> reconcile() async => nativeState;
  @override
  Future<void> openStore() async {}
  @override
  Future<void> startStoreDownload(String operationId, Release release) async {
    downloadOperationId = operationId;
  }
}

class FakeRepository extends UpdateRepository {
  FakeRepository(UpdateStore store)
    : super(
        UpdateConfig(
          origin: Uri.parse('https://updates.example.test'),
          keys: {'test': List.filled(32, 0)},
        ),
        identity,
        store,
        proxy: () => 'DIRECT',
      );
  int checks = 0;
  Completer<void>? pending;
  bool withdrawn = false;
  bool fail = false;
  @override
  Future<VerifiedFeed> fetch() async {
    checks++;
    await pending?.future;
    if (fail) throw const UpdateFailure('Network unavailable');
    return VerifiedFeed(
      withdrawn ? [] : [Release(releaseJson())],
      DateTime.now().add(const Duration(hours: 1)),
      checks,
      '$checks',
      'test',
    );
  }
}

void main() {
  late FakeAdapter adapter;
  late FakeRepository repo;
  late UpdateStore store;
  late UpdateCoordinator coordinator;
  var cleanupFails = false;
  setUp(() {
    store = UpdateStore(null);
    adapter = FakeAdapter();
    repo = FakeRepository(store);
    cleanupFails = false;
    coordinator = UpdateCoordinator(
      store: store,
      adapter: adapter,
      identity: identity,
      repository: repo,
      capabilities: const UpdateCapabilities(install: true),
      canPrompt: () => true,
      prepareConnection: (handoff) async {
        if (cleanupFails) throw StateError('Proxy restoration failed');
        await handoff();
      },
    );
  });
  tearDown(() => coordinator.dispose());
  void usePlayCoordinator() {
    coordinator.dispose();
    coordinator = UpdateCoordinator(
      store: store,
      adapter: adapter,
      identity: const InstalledIdentity(
        applicationId: 'io.shifter.test',
        platform: 'android',
        architecture: 'universal',
        distribution: Distribution.play,
        version: '1.0.0',
        build: 10,
        osVersion: '35',
      ),
      repository: repo,
      capabilities: const UpdateCapabilities(install: true, store: true),
      canPrompt: () => true,
      prepareConnection: (handoff) => handoff(),
    );
  }

  test(
    'Play consent cancellation clears pending state and permits retry',
    () async {
      usePlayCoordinator();
      await coordinator.check();
      await coordinator.startPlayDownload();
      expect(coordinator.phase, UpdatePhase.downloading);
      adapter.nativeState = {
        'state': 'canceled',
        'operationId': adapter.downloadOperationId,
      };
      await coordinator.resume();
      expect(coordinator.phase, UpdatePhase.error);
      expect(store.read('pending'), isNull);
      await coordinator.check();
      expect(coordinator.phase, UpdatePhase.available);
      await coordinator.startPlayDownload();
      expect(coordinator.phase, UpdatePhase.downloading);
    },
  );

  test(
    'Play completion preserves native operation ID and observes failure',
    () async {
      usePlayCoordinator();
      await coordinator.check();
      await coordinator.startPlayDownload();
      adapter.nativeState = {
        'state': 'ready',
        'build': 11,
        'operationId': adapter.downloadOperationId,
      };
      await coordinator.resume();
      expect(coordinator.phase, UpdatePhase.ready);
      await coordinator.install();
      expect(coordinator.phase, UpdatePhase.handingOff);
      expect(adapter.installOperationId, adapter.downloadOperationId);
      adapter.nativeState['state'] = 'failed';
      await coordinator.resume();
      expect(coordinator.phase, UpdatePhase.error);
      expect(store.read('pending'), isNull);
    },
  );

  test('Play recovery keeps the journal operation ID across restart', () async {
    usePlayCoordinator();
    await coordinator.check();
    await coordinator.startPlayDownload();
    adapter.nativeState = {
      'state': 'ready',
      'build': 11,
      'operationId': adapter.downloadOperationId,
    };
    usePlayCoordinator();
    await coordinator.initialize();
    expect(coordinator.phase, UpdatePhase.ready);
    await coordinator.install();
    expect(adapter.installOperationId, adapter.downloadOperationId);
  });

  test('concurrent manual checks join the same operation', () async {
    repo.pending = Completer<void>();
    final first = coordinator.check();
    final second = coordinator.check();
    await Future<void>.delayed(Duration.zero);
    expect(repo.checks, 1);
    repo.pending!.complete();
    await Future.wait([first, second]);
    expect(coordinator.phase, UpdatePhase.available);
  });
  test('failed check never claims up to date', () async {
    repo.fail = true;
    await coordinator.check();
    expect(coordinator.phase, UpdatePhase.error);
    expect(coordinator.lastCheck, isNull);
  });
  test(
    'Later suppresses automatic prompts while manual checks remain available',
    () async {
      await coordinator.check(automatic: true);
      expect(coordinator.promptRequested, isTrue);
      await coordinator.later();
      await coordinator.considerPrompt();
      expect(coordinator.promptRequested, isFalse);
      await coordinator.check();
      expect(repo.checks, 2);
      expect(coordinator.phase, UpdatePhase.available);
    },
  );
  test('automatic checks respect six-hour throttle', () async {
    await coordinator.check(automatic: true);
    await coordinator.check(automatic: true);
    expect(repo.checks, 1);
    await coordinator.check();
    expect(repo.checks, 2);
  });
  test(
    'proxy restoration failure prevents installer and restart marker',
    () async {
      await coordinator.check();
      coordinator.phase = UpdatePhase.ready;
      cleanupFails = true;
      await coordinator.install();
      expect(adapter.installed, 0);
      expect(store.read('pending'), isNull);
      expect(coordinator.phase, UpdatePhase.error);
    },
  );
  test('withdrawal after download prevents installation', () async {
    await coordinator.check();
    coordinator.phase = UpdatePhase.ready;
    repo.withdrawn = true;
    await coordinator.install();
    expect(adapter.installed, 0);
    expect(coordinator.phase, UpdatePhase.error);
  });
  test('successful handoff journals target and suppresses reconnect', () async {
    await coordinator.check();
    coordinator.phase = UpdatePhase.ready;
    await coordinator.install();
    expect(adapter.installed, 1);
    expect(store.read('suppressReconnect'), 'true');
    expect(store.object('pending')!['release']['build'], 11);
  });
}
