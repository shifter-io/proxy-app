import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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
  Future<void> install(Release release, String? path) async {
    installed++;
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
  String? minimumVersion;
  @override
  Future<String> fetchRequiredVersion() async {
    if (minimumVersion case final version?) return version;
    throw const UpdateFailure('Policy unavailable');
  }

  @override
  Future<void> download(
    Release release,
    File destination,
    void Function(int, int) progress,
  ) async {
    await destination.writeAsString('abc');
    progress(3, 3);
  }

  Map<String, dynamic> candidate = releaseJson();
  @override
  Future<VerifiedFeed> fetch() async {
    checks++;
    await pending?.future;
    if (fail) throw const UpdateFailure('Network unavailable');
    return VerifiedFeed(
      withdrawn ? [] : [Release(candidate)],
      DateTime.now().add(const Duration(hours: 1)),
      checks,
      '$checks',
      'test',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temporary;
  late FakeAdapter adapter;
  late FakeRepository repo;
  late UpdateStore store;
  late UpdateCoordinator coordinator;
  var cleanupFails = false;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('shifter-update-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => temporary.path);
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
  tearDown(() async {
    coordinator.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  test('concurrent manual checks join the same operation', () async {
    repo.pending = Completer<void>();
    final first = coordinator.check();
    final second = coordinator.check();
    while (repo.checks == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
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
  group('automatic desktop installation', () {
    var canApply = true;
    var revokeDuringPreparation = false;

    setUp(() async {
      coordinator.dispose();
      canApply = true;
      revokeDuringPreparation = false;
      repo.candidate['automaticInstall'] = true;
      coordinator = UpdateCoordinator(
        store: store,
        adapter: adapter,
        identity: const InstalledIdentity(
          applicationId: 'io.shifter.test',
          platform: 'windows',
          architecture: 'x64',
          version: '1.0.0',
          build: 10,
          osVersion: '10.0.0',
        ),
        repository: repo,
        capabilities: const UpdateCapabilities(install: true),
        canPrompt: () => true,
        canAutomaticallyInstall: () => canApply,
        prepareConnection: (handoff) => handoff(),
        prepareAutomaticConnection: (handoff) async {
          if (revokeDuringPreparation) {
            repo.candidate['automaticInstall'] = false;
          }
          await handoff();
        },
      );
      await coordinator.check();
      coordinator.phase = UpdatePhase.ready;
    });

    test('opt-in and disconnected runtime are required', () async {
      await coordinator.install(automatic: true);
      expect(adapter.installed, 0);
      await coordinator.setAutomaticInstall(true);
      canApply = false;
      await coordinator.install(automatic: true);
      expect(adapter.installed, 0);
      canApply = true;
      await coordinator.install(automatic: true);
      expect(adapter.installed, 1);
    });

    test(
      'removing automatic permission before handoff stops installation',
      () async {
        await coordinator.setAutomaticInstall(true);
        revokeDuringPreparation = true;
        await coordinator.install(automatic: true);
        expect(adapter.installed, 0);
        expect(coordinator.phase, UpdatePhase.ready);
        expect(store.read('pending'), isNull);
      },
    );
  });

  test('required policy bypasses rollout and a deferred prompt', () async {
    await coordinator.check(automatic: true);
    expect(coordinator.promptRequested, isTrue);
    await coordinator.later();
    repo.candidate['rolloutPercentage'] = 0;
    repo.minimumVersion = '1.1.0';

    await coordinator.check(automatic: true);

    expect(coordinator.requiredVersion, '1.1.0');
    expect(coordinator.release?.version, '1.1.0');
    expect(coordinator.promptRequested, isFalse);
  });

  test(
    'required policy stays active after failure and rejects lower releases',
    () async {
      repo.minimumVersion = '1.2.0';
      await coordinator.check();
      expect(coordinator.phase, UpdatePhase.unavailable);
      expect(coordinator.release, isNull);
      expect(store.read('minimumVersion'), '1.2.0');

      repo.minimumVersion = null;
      await coordinator.check();
      expect(coordinator.requiredVersion, '1.2.0');
      expect(coordinator.release, isNull);

      repo.minimumVersion = '1.0.0';
      await coordinator.check(automatic: true);
      expect(coordinator.requiredVersion, isNull);
    },
  );

  test('Update now downloads, verifies, and restarts', () async {
    coordinator.dispose();
    coordinator = UpdateCoordinator(
      store: store,
      adapter: adapter,
      identity: identity,
      repository: repo,
      capabilities: const UpdateCapabilities(download: true, install: true),
      canPrompt: () => false,
      prepareConnection: (handoff) => handoff(),
    );
    repo.minimumVersion = '1.1.0';
    await coordinator.check();
    await coordinator.updateNow();
    expect(coordinator.phase, UpdatePhase.handingOff);
    expect(adapter.installed, 1);
  });
}
