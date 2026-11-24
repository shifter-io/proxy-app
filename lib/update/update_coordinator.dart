import '../i18n/i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

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
    this.prepareAutomaticConnection,
    this.canAutomaticallyInstall = _disabled,
    this.capabilities = const UpdateCapabilities(),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now,
       _minimumVersion = repository == null
           ? null
           : store.read('minimumVersion');
  final UpdateStore store;
  final UpdateAdapter adapter;
  final InstalledIdentity identity;
  final UpdateRepository? repository;
  final Future<void> Function(Future<void> Function()) prepareConnection;
  final bool Function() canPrompt;
  final Future<void> Function(Future<void> Function())?
  prepareAutomaticConnection;
  final bool Function() canAutomaticallyInstall;

  static bool _disabled() => false;
  bool get supportsAutomaticInstall =>
      repository != null &&
      prepareAutomaticConnection != null &&
      capabilities.install;
  bool get automaticInstallEnabled => store.read('automaticInstall') == 'true';

  Future<void> setAutomaticInstall(bool enabled) async {
    await store.write('automaticInstall', enabled ? 'true' : null);
    _notify();
  }

  Uri? get manualDownload {
    final candidate = release;
    if (candidate == null || repository == null || !_meetsMinimum(candidate)) {
      return null;
    }
    final path = candidate.manualDownloadPath;
    return path == null ? null : repository!.config.resolve(path);
  }

  Future<void> openManualDownload() async {
    final uri = manualDownload;
    if (uri == null) return;
    await _run(() async {
      final current = await _revalidate(release!);
      if (current.manualDownloadPath != release!.manualDownloadPath ||
          !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const UpdateFailure('The download link could not be opened.');
      }
    });
  }

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
  String? _minimumVersion;
  String? get requiredVersion {
    final minimum = _minimumVersion;
    return minimum != null && compareVersions(identity.version, minimum) < 0
        ? minimum
        : null;
  }

  bool _meetsMinimum(Release candidate) =>
      requiredVersion == null ||
      compareVersions(candidate.version, requiredVersion!) >= 0;

  Future<bool> _refreshRequiredVersion() async {
    final previous = requiredVersion;
    try {
      final version = await repository!.fetchRequiredVersion();
      if (version != _minimumVersion) {
        _minimumVersion = version;
        _notify();
        await store.write('minimumVersion', version);
      }
    } catch (_) {
      // Keep the last valid minimum across offline, malformed and failed checks.
    }
    return previous != requiredVersion;
  }

  bool get busy => _operation != null;
  DateTime? get lastCheck => store.time('lastSuccess');
  bool get ready => phase == UpdatePhase.ready;
  bool get canDownload =>
      release != null &&
      _meetsMinimum(release!) &&
      capabilities.download &&
      !busy &&
      !ready &&
      (_artifact == null || phase == UpdatePhase.error) &&
      phase != UpdatePhase.handingOff;
  bool get canInstall =>
      release != null &&
      _meetsMinimum(release!) &&
      capabilities.install &&
      !busy &&
      (ready || (phase == UpdatePhase.error && _artifact != null));
  /// Shown to the user, in the app language. [error] and capability reasons
  /// stay in English (tests, logs) and are translated here.
  String get status => switch (phase) {
    UpdatePhase.idle =>
      repository == null
          ? tr('Updates are not configured for this build.')
          : tr('Check for a newer version of Shifter.'),
    UpdatePhase.checking => tr('Checking for updates…'),
    UpdatePhase.current => tr('You are up to date.'),
    UpdatePhase.available => trf('Shifter {version} is available.', {'version': release?.version ?? ''}),
    UpdatePhase.unavailable => tr(
      error ??
          capabilities.reason ??
          'Update availability could not be confirmed for this installation.',
    ),
    UpdatePhase.downloading => tr('Downloading update…'),
    UpdatePhase.verifying => tr('Verifying update…'),
    UpdatePhase.ready => tr('Update ready to install.'),
    UpdatePhase.preparingInstall => tr('Preparing to update…'),
    UpdatePhase.handingOff => tr('The update has been handed to the installer.'),
    UpdatePhase.error => tr(error ?? 'Could not check for updates. Please retry.'),
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
        if (repository != null) {
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
              ? (e.message ?? tr('The installer could not complete the update.'))
              : tr('The update could not be completed. Please retry.');
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
        final target = Release(
          (pending['release'] as Map).cast<String, dynamic>(),
        );
        await store.write('pending', null);
        if (!identity.newer(target)) {
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
    });
    await check(automatic: true, offer: false);
    await _installOnStartup();
    await considerPrompt();
  }

  Future<bool> _automaticCandidate() async {
    final target = release;
    if (_disposed ||
        !supportsAutomaticInstall ||
        !automaticInstallEnabled ||
        !canAutomaticallyInstall() ||
        target == null ||
        !target.automaticInstall ||
        !_meetsMinimum(target) ||
        (requiredVersion == null &&
            (store.time('laterUntil')?.isAfter(clock()) ?? false))) {
      return false;
    }
    final cohort = await store.cohort();
    return identical(release, target) && cohort < target.rollout;
  }

  Future<void> _installOnStartup() async {
    if (!await _automaticCandidate()) return;
    if (canDownload) await download();
    if (canInstall && await _automaticCandidate()) {
      await install(automatic: true);
    }
  }

  Future<void> check({bool automatic = false, bool offer = true}) {
    if (busy) return _operation!;
    if (phase == UpdatePhase.handingOff) return Future.value();
    return _run(() async {
      if (repository == null) {
        error = tr('Updates are not configured for this build.');
        phase = UpdatePhase.unavailable;
        return;
      }
      final policyChanged = await _refreshRequiredVersion();
      final last = store.time('lastAttempt');
      final needsRequiredRelease =
          requiredVersion != null &&
          (release == null || !_meetsMinimum(release!));
      if (automatic &&
          !policyChanged &&
          !needsRequiredRelease &&
          (phase == UpdatePhase.ready ||
              (last != null &&
                  clock().difference(last).abs() < const Duration(hours: 6)))) {
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
                    _meetsMinimum(r) &&
                    (!automatic ||
                        requiredVersion != null ||
                        cohort < r.rollout),
              )
              .toList()
            ..sort((a, b) => compareVersions(b.version, a.version));
      final previousRelease = release;
      release = null;
      for (final candidate in candidates) {
        if (await adapter.eligible(
          candidate,
          automatic: automatic && requiredVersion == null,
        )) {
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
      if (release == null && requiredVersion != null) {
        error = tr('The required update is unavailable for this installation. Try again shortly.');
      }
      phase = release != null
          ? (_artifact != null ? UpdatePhase.ready : UpdatePhase.available)
          : candidates.isEmpty && requiredVersion == null
          ? UpdatePhase.current
          : UpdatePhase.unavailable;
      if (automatic && offer) await considerPrompt();
    });
  }

  Future<void> considerPrompt() async {
    if (_disposed ||
        !canPrompt() ||
        requiredVersion != null ||
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

  Future<File> _file(Release r, {required bool partial}) async {
    final format = r.artifact!['format'];
    final extension = partial ? 'partial' : format;
    return File('${(await _directory()).path}/${r.sha256}.$extension');
  }

  Future<void> _cleanup() async {
    if (!capabilities.download) return;
    final dir = await _directory();
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
          (r) =>
              r.enabled &&
              r.sameArtifact(selected) &&
              identity.newer(r) &&
              _meetsMinimum(r),
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

  Future<void> updateNow() async {
    if (busy || phase == UpdatePhase.handingOff) return;
    if (release == null ||
        phase == UpdatePhase.error ||
        !_meetsMinimum(release!)) {
      await check();
    }
    if (requiredVersion == null) return;
    if (canDownload) await download();
    if (ready && canInstall) {
      await install();
    } else if (!capabilities.install && manualDownload != null) {
      await openManualDownload();
    }
  }

  Future<void> install({bool automatic = false}) {
    if (!canInstall || (automatic && !supportsAutomaticInstall)) {
      return Future.value();
    }
    return _run(() async {
      phase = UpdatePhase.preparingInstall;
      _notify();
      if (automatic && !await _automaticCandidate()) {
        phase = UpdatePhase.ready;
        return;
      }
      final prepare = automatic
          ? prepareAutomaticConnection!
          : prepareConnection;
      await prepare(() async {
        final selected = await _revalidate(release!);
        if (automatic &&
            (!selected.automaticInstall ||
                !automaticInstallEnabled ||
                await store.cohort() >= selected.rollout)) {
          phase = UpdatePhase.ready;
          return;
        }
        if (capabilities.download) {
          if (_artifact == null) {
            throw const UpdateFailure('Download the update again.');
          }
          await UpdateRepository.verifyFile(selected, _artifact!);
        }
        await adapter.prepare(selected, _artifact?.path);
        await store.write('pending', jsonEncode({'release': selected.json}));
        await store.write('suppressReconnect', 'true');
        try {
          await adapter.install(selected, _artifact?.path);
          phase = UpdatePhase.handingOff;
        } catch (_) {
          await store.write('pending', null);
          await store.write('suppressReconnect', null);
          rethrow;
        }
      });
    });
  }

  @override
  void dispose() {
    _disposed = true;
    repository?.cancel();
    super.dispose();
  }
}
