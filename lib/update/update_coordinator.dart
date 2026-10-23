import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'adapters/update_adapter.dart';
import 'update_models.dart';
import 'update_repository.dart';
import 'update_store.dart';

class UpdateCoordinator extends ChangeNotifier {
  UpdateCoordinator({
    required this.store,
    required this.adapter,
    required this.identity,
    required this.repository,
    required this.prepareConnection,
    required this.canPrompt,
    this.capabilities = const UpdateCapabilities(),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final UpdateStore store;
  final UpdateAdapter adapter;
  final InstalledIdentity identity;
  final UpdateRepository? repository;
  final Future<void> Function(Future<void> Function()) prepareConnection;
  final bool Function() canPrompt;
  final UpdateCapabilities capabilities;
  final DateTime Function() clock;
  UpdatePhase phase = UpdatePhase.idle;
  Release? release;
  String? error;
  double? progress;
  bool promptRequested = false;
  bool _disposed = false;
  bool _cancelled = false;
  File? _artifact;
  Future<void>? _operation;
  Timer? _nativePoll;
  String? _operationId;
  bool get busy => _operation != null;
  DateTime? get lastCheck => store.time('lastSuccess');
  bool get ready => phase == UpdatePhase.ready;
  bool get canDownload =>
      release != null &&
      capabilities.download &&
      !busy &&
      !ready &&
      (_artifact == null || phase == UpdatePhase.error) &&
      phase != UpdatePhase.awaitingSystemConsent &&
      phase != UpdatePhase.handingOff;
  bool get canInstall =>
      release != null &&
      capabilities.install &&
      !busy &&
      (ready || (phase == UpdatePhase.error && _artifact != null));
  String get status => switch (phase) {
    UpdatePhase.idle =>
      repository == null
          ? 'Updates are not configured for this build.'
          : 'Check for a newer version of Shifter.',
    UpdatePhase.checking => 'Checking for updates…',
    UpdatePhase.current => 'You are up to date.',
    UpdatePhase.available => 'Shifter ${release?.version ?? ''} is available.',
    UpdatePhase.unavailable =>
      error ??
          capabilities.reason ??
          'Update availability could not be confirmed for this installation.',
    UpdatePhase.downloading => 'Downloading update…',
    UpdatePhase.verifying => 'Verifying update…',
    UpdatePhase.ready => 'Update ready to install.',
    UpdatePhase.preparingInstall => 'Preparing to update…',
    UpdatePhase.awaitingSystemConsent =>
      'Finish the update in the system installer.',
    UpdatePhase.handingOff => 'The update has been handed to the installer.',
    UpdatePhase.error => error ?? 'Could not check for updates. Please retry.',
  };
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _run(Future<void> Function() task) {
    if (_operation != null) return _operation!;
    // Schedule after assigning the lock, so synchronous notifications see it.
    final future = Future<void>.microtask(() async {
      RandomAccessFile? processLock;
      try {
        if (identity.distribution == Distribution.desktop &&
            repository != null) {
          final path = '${(await _directory()).path}/transaction.lock';
          final type = await FileSystemEntity.type(path, followLinks: false);
          if (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.file) {
            throw const UpdateFailure('Unsafe update lock.');
          }
          processLock = await File(path).open(mode: FileMode.append);
          try {
            await processLock.lock(FileLock.exclusive);
          } catch (_) {
            throw const UpdateFailure(
              'Another Shifter window is updating. Finish that update first.',
            );
          }
        }
        error = null;
        _cancelled = false;
        await task();
      } catch (e) {
        if (_cancelled) {
          phase = release == null ? UpdatePhase.idle : UpdatePhase.available;
        } else {
          phase = UpdatePhase.error;
          error = e is UpdateFailure
              ? e.message
              : e is PlatformException
              ? (e.message ?? 'The installer could not complete the update.')
              : 'The update could not be completed. Please retry.';
        }
      } finally {
        await processLock?.close();
        _operation = null;
        _notify();
      }
    });
    _operation = future;
    _notify();
    return future;
  }

  Future<void> initialize() async {
    await _run(() async {
      final pending = store.object('pending');
      if (pending != null) {
        _operationId = pending['operationId'] as String?;
        final target = Release(
          (pending['release'] as Map).cast<String, dynamic>(),
        );
        if (!identity.newer(target)) {
          await store.write('pending', null);
          await store.write('staged', null);
        } else {
          // The journal is a hint only; install still requires fresh signed metadata.
          release = target;
        }
      }
      final staged = store.object('staged');
      if (staged != null && repository != null) {
        try {
          final feed = await repository!.verify(staged['envelope'] as String);
          final r = feed.releases
              .where(
                (r) =>
                    r.id == staged['releaseId'] &&
                    r.enabled &&
                    identity.newer(r),
              )
              .firstOrNull;
          if (r != null) {
            final f = await _file(r, partial: false);
            if (clock().difference((await f.stat()).modified) >
                    const Duration(hours: 24) &&
                pending == null) {
              await f.delete();
              await store.write('staged', null);
            } else {
              await UpdateRepository.verifyFile(r, f);
              release = r;
              _artifact = f;
              phase = UpdatePhase.ready;
            }
          }
        } catch (_) {
          await store.write('staged', null);
        }
      }
      await _cleanup();
      await _reconcileNative();
    });
    if (phase != UpdatePhase.ready &&
        phase != UpdatePhase.awaitingSystemConsent) {
      await check(automatic: true);
    }
  }

  Future<void> check({bool automatic = false}) {
    if (busy) return _operation!;
    if (phase == UpdatePhase.ready ||
        phase == UpdatePhase.downloading ||
        phase == UpdatePhase.awaitingSystemConsent ||
        phase == UpdatePhase.handingOff) {
      return Future.value();
    }
    final last = store.time('lastAttempt');
    if (automatic &&
        last != null &&
        clock().difference(last).abs() < const Duration(hours: 6)) {
      return Future.value();
    }
    return _run(() async {
      if (repository == null) {
        error = 'Updates are not configured for this build.';
        phase = UpdatePhase.unavailable;
        return;
      }
      if (automatic) {
        await store.write('lastAttempt', clock().toUtc().toIso8601String());
      }
      phase = UpdatePhase.checking;
      _notify();
      final feed = await repository!.fetch();
      final cohort = await store.cohort();
      final candidates =
          feed.releases
              .where(
                (r) =>
                    r.enabled &&
                    identity.newer(r) &&
                    (!automatic || cohort < r.rollout),
              )
              .toList()
            ..sort(
              (a, b) => identity.platform == 'android'
                  ? b.build.compareTo(a.build)
                  : (identity.platform == 'ios'
                        ? comparePublicVersions(b.version, a.version)
                        : compareVersions(b.version, a.version)),
            );
      final previousRelease = release;
      release = null;
      for (final candidate in candidates) {
        if (await adapter.eligible(candidate, automatic: automatic)) {
          release = candidate;
          break;
        }
      }
      if (_artifact != null &&
          (release == null ||
              previousRelease == null ||
              !release!.sameArtifact(previousRelease))) {
        if (await _artifact!.exists()) await _artifact!.delete();
        _artifact = null;
        await store.write('staged', null);
      }
      await store.write('lastSuccess', clock().toUtc().toIso8601String());
      phase = release != null
          ? UpdatePhase.available
          : candidates.isEmpty
          ? UpdatePhase.current
          : UpdatePhase.unavailable;
      if (identity.distribution == Distribution.play) await _reconcileNative();
      if (automatic) await considerPrompt();
    });
  }

  Future<void> considerPrompt() async {
    if (_disposed ||
        !canPrompt() ||
        release == null ||
        (phase != UpdatePhase.available && phase != UpdatePhase.ready)) {
      return;
    }
    final now = clock();
    final later = store.time('laterUntil');
    final prompted = store.time('lastPrompt');
    if ((later != null && later.isAfter(now)) ||
        (prompted != null &&
            now.difference(prompted).abs() < const Duration(hours: 24))) {
      return;
    }
    await store.write('lastPrompt', now.toUtc().toIso8601String());
    if (_disposed || !canPrompt()) return;
    promptRequested = true;
    _notify();
  }

  Future<void> later() async {
    promptRequested = false;
    await store.write(
      'laterUntil',
      clock().add(const Duration(days: 7)).toUtc().toIso8601String(),
    );
    _notify();
  }

  void consumePrompt() {
    promptRequested = false;
  }

  Future<Directory> _directory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/updates-v1');
    final type = await FileSystemEntity.type(dir.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const UpdateFailure('Unsafe update staging directory.');
    }
    await dir.create(recursive: true);
    if (Platform.isMacOS || Platform.isLinux) {
      final mode = await Process.run('/bin/chmod', ['700', dir.path]);
      if (mode.exitCode != 0) {
        throw const UpdateFailure('Could not secure update staging.');
      }
    }
    return dir;
  }

  Future<File> _file(Release r, {required bool partial}) async => File(
    '${(await _directory()).path}/${r.sha256}.${partial ? 'partial' : r.artifact!['format']}',
  );
  Future<void> _cleanup() async {
    if (!capabilities.download) return;
    final dir = await _directory();
    // A native installer may still hold the staged package after process death.
    if (store.object('pending') != null) return;
    await for (final entry in dir.list(followLinks: false)) {
      if (entry.path == _artifact?.path ||
          entry.path.endsWith('/transaction.lock') ||
          entry is! File) {
        continue;
      }
      if (clock().difference((await entry.stat()).modified) >
          const Duration(hours: 24)) {
        await entry.delete();
      }
    }
  }

  Future<Release> _revalidate(Release selected) async {
    final feed = await repository!.fetch();
    final fresh = feed.releases
        .where(
          (r) => r.enabled && r.sameArtifact(selected) && identity.newer(r),
        )
        .firstOrNull;
    if (fresh == null || !await adapter.eligible(fresh, automatic: false)) {
      throw const UpdateFailure(
        'This release is no longer available for this device. Check again later.',
      );
    }
    return fresh;
  }

  Future<void> download() {
    if (!canDownload) return Future.value();
    return _run(() async {
      _cancelled = false;
      final selected = await _revalidate(release!);
      final file = await _file(selected, partial: true);
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await file.delete();
      }
      phase = UpdatePhase.downloading;
      progress = 0;
      _notify();
      try {
        await repository!.download(selected, file, (received, total) {
          progress = received / total;
          _notify();
        });
        if (_cancelled) throw const UpdateFailure('Download canceled.');
        phase = UpdatePhase.verifying;
        _notify();
        await adapter.prepare(selected, file.path);
        final finalFile = await _file(selected, partial: false);
        if (await FileSystemEntity.type(finalFile.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          await finalFile.delete();
        }
        _artifact = await file.rename(finalFile.path);
        final feed = await repository!.fetch();
        if (!feed.releases.any((r) => r.enabled && r.sameArtifact(selected))) {
          throw const UpdateFailure('This release was withdrawn.');
        }
        await store.write(
          'staged',
          jsonEncode({'envelope': feed.envelope, 'releaseId': selected.id}),
        );
        phase = UpdatePhase.ready;
      } finally {
        if (await file.exists()) await file.delete();
      }
    });
  }

  void cancelDownload() {
    if (phase == UpdatePhase.downloading && capabilities.cancel) {
      _cancelled = true;
      repository?.cancel();
    }
  }

  void routeChanged() {
    repository?.cancel();
  }

  void backgrounded() {
    if (identity.distribution == Distribution.direct) cancelDownload();
  }

  Future<void> startPlayDownload() {
    if (release == null || identity.distribution != Distribution.play || busy) {
      return Future.value();
    }
    return _run(() async {
      await _revalidate(release!);
      _operationId = '${clock().microsecondsSinceEpoch}';
      await store.write(
        'pending',
        jsonEncode({'operationId': _operationId, 'release': release!.json}),
      );
      await adapter.startStoreDownload(_operationId!, release!);
      phase = UpdatePhase.downloading;
      _nativePoll ??= Timer.periodic(const Duration(seconds: 2), (_) {
        if (!busy) unawaited(resume());
      });
    });
  }

  Future<void> install() {
    if (!canInstall) return Future.value();
    return _run(() async {
      phase = UpdatePhase.preparingInstall;
      _notify();
      await prepareConnection(() async {
        final selected = await _revalidate(release!);
        if (capabilities.download) {
          if (_artifact == null) {
            throw const UpdateFailure('Download the update again.');
          }
          await UpdateRepository.verifyFile(selected, _artifact!);
        }
        await adapter.prepare(selected, _artifact?.path);
        // Play keeps the download's native operation ID through completion.
        // Replacing it here would discard later failure/cancellation callbacks.
        if (identity.distribution != Distribution.play ||
            _operationId == null) {
          _operationId = '${clock().microsecondsSinceEpoch}';
        }
        await store.write(
          'pending',
          jsonEncode({'operationId': _operationId, 'release': selected.json}),
        );
        await store.write('suppressReconnect', 'true');
        await adapter.install(selected, _artifact?.path, _operationId!);
        phase = identity.distribution == Distribution.direct
            ? UpdatePhase.awaitingSystemConsent
            : UpdatePhase.handingOff;
      });
    });
  }

  Future<void> openStore() => _run(() async {
    await prepareConnection(() async {
      await store.write('suppressReconnect', 'true');
      await adapter.openStore();
    });
  });
  Future<void> _reconcileNative() async {
    if (identity.distribution != Distribution.play &&
        identity.distribution != Distribution.direct) {
      return;
    }
    final native = await adapter.reconcile();
    final operation = native['operationId'];
    if (operation != null &&
        _operationId != null &&
        operation != _operationId) {
      return;
    }
    if (native['state'] == 'ready' &&
        release != null &&
        native['build'] == release!.build) {
      phase = UpdatePhase.ready;
      _nativePoll?.cancel();
      _nativePoll = null;
    }
    if (native['state'] == 'downloading') {
      phase = UpdatePhase.downloading;
      _nativePoll ??= Timer.periodic(const Duration(seconds: 2), (_) {
        if (!busy) unawaited(resume());
      });
      progress = (native['progress'] as num?)?.toDouble();
    }
    if ((native['state'] == 'failed' || native['state'] == 'canceled') &&
        store.object('pending') != null) {
      _nativePoll?.cancel();
      _nativePoll = null;
      await store.write('pending', null);
      throw const UpdateFailure(
        'Installation did not complete. You can retry the update.',
      );
    }
    if (native['state'] == 'awaitingSystemConsent' &&
        store.object('pending') != null) {
      phase = UpdatePhase.awaitingSystemConsent;
    }
  }

  Future<void> resume() async {
    if (busy) return;
    final previousError = error;
    await _run(_reconcileNative);
    if (phase == UpdatePhase.error && error == null) {
      error = previousError;
      _notify();
    }
    if (phase != UpdatePhase.downloading && phase != UpdatePhase.error) {
      await check(automatic: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _nativePoll?.cancel();
    repository?.cancel();
    super.dispose();
  }
}
