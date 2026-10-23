import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../update_config.dart';
import '../update_models.dart';
import 'update_adapter.dart';

/// Mobile methods carry a request identity; foreground reconciliation is the
/// authority after Activity/process recreation rather than stale UI callbacks.
class NativeUpdateAdapter implements UpdateAdapter {
  NativeUpdateAdapter(this.config);
  final UpdateConfig? config;
  static const channel = MethodChannel('shifter/updates');
  InstalledIdentity? _identity;
  @override
  Future<InstalledIdentity> identity() async {
    final package = await PackageInfo.fromPlatform();
    final native =
        await channel.invokeMapMethod<String, dynamic>('identity') ?? {};
    return _identity = InstalledIdentity(
      applicationId: package.packageName,
      platform: Platform.operatingSystem,
      architecture: native['architecture'] as String? ?? 'universal',
      distribution: Distribution.values.byName(
        native['distribution'] as String,
      ),
      version: package.version,
      build: int.parse(package.buildNumber),
      osVersion: native['osVersion'] as String,
      storefront: native['storefront'] as String?,
    );
  }

  @override
  Future<UpdateCapabilities> capabilities() async {
    switch (_identity?.distribution) {
      case Distribution.direct:
        return const UpdateCapabilities(
          download: true,
          cancel: true,
          install: true,
        );
      case Distribution.play:
        return const UpdateCapabilities(install: true, store: true);
      case Distribution.appStore:
        return UpdateCapabilities(
          store: RegExp(r'^[0-9]+$').hasMatch(config?.appStoreId ?? ''),
        );
      default:
        return const UpdateCapabilities(
          reason: 'Updates are unavailable for this build.',
        );
    }
  }

  @override
  Future<bool> eligible(Release release, {required bool automatic}) async {
    final id = await identity();
    if (id.distribution == Distribution.play) {
      final state = await reconcile();
      return state['available'] == true && state['build'] == release.build;
    }
    if (id.distribution == Distribution.appStore) {
      final s = release.store;
      if (s == null ||
          s['configuredProductId'] != config?.appStoreId ||
          (automatic && s['broadlyAvailable'] != true)) {
        return false;
      }
      // StoreKit storefront IDs are ISO-3166 alpha-3; publisher uses the same IDs.
      final observation = (s['observations'] as List? ?? [])
          .cast<Map>()
          .where((o) => o['storefront'] == id.storefront)
          .firstOrNull;
      if (observation == null ||
          observation['version'] != release.version ||
          observation['applicationId'] != id.applicationId) {
        return false;
      }
      final observed = DateTime.tryParse(
        observation['observedAt'] as String? ?? '',
      );
      final age = observed == null
          ? null
          : DateTime.now().toUtc().difference(observed);
      if (age == null || age.isNegative || age > const Duration(minutes: 60)) {
        return false;
      }
    }
    return await channel.invokeMethod<bool>('eligible', {
          'release': release.json,
        }) ??
        false;
  }

  @override
  Future<void> prepare(Release release, String? path) =>
      channel.invokeMethod('prepare', {'release': release.json, 'path': path});
  @override
  Future<void> install(Release release, String? path, String operationId) =>
      channel.invokeMethod('install', {
        'release': release.json,
        'path': path,
        'operationId': operationId,
      });
  @override
  Future<void> startStoreDownload(String operationId, Release release) =>
      channel.invokeMethod('download', {
        'operationId': operationId,
        'build': release.build,
      });
  @override
  Future<Map<String, dynamic>> reconcile() async =>
      await channel.invokeMapMethod<String, dynamic>('reconcile') ?? {};
  @override
  Future<void> openStore() =>
      channel.invokeMethod('openStore', {'productId': config?.appStoreId});
}
