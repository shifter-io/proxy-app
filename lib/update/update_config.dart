import 'dart:convert';

import 'update_models.dart';

class UpdateConfig {
  UpdateConfig({
    required this.origin,
    required this.keys,
    this.enabled = true,
    this.appStoreId = '',
  }) {
    if (origin.scheme != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/')) {
      throw const UpdateFailure('Updates require a configured HTTPS origin.');
    }
    if (keys.isEmpty || keys.values.any((key) => key.length != 32)) {
      throw const UpdateFailure('Update signing keys are not configured.');
    }
  }
  final Uri origin;
  final Map<String, List<int>> keys;
  final bool enabled;
  final String appStoreId;
  static UpdateConfig? production() {
    if (!const bool.fromEnvironment('SHIFTER_UPDATES_ENABLED')) return null;
    final raw = jsonDecode(
      const String.fromEnvironment(
        'SHIFTER_UPDATE_PUBLIC_KEYS',
        defaultValue: '{}',
      ),
    ) as Map;
    return UpdateConfig(
      origin: Uri.parse(const String.fromEnvironment('SHIFTER_UPDATE_ORIGIN')),
      keys: raw.map(
        (key, value) => MapEntry(key as String, base64Decode(value as String)),
      ),
      appStoreId: const String.fromEnvironment('SHIFTER_APP_STORE_ID'),
    );
  }

  Uri resolve(String path) {
    // No percent encoding, traversal, credentials, absolute paths or alternate origins.
    if (!RegExp(r'^[A-Za-z0-9_-]+(?:[./-][A-Za-z0-9_-]+)*$').hasMatch(path) ||
        path.contains('..')) {
      throw const UpdateFailure('Unsafe update artifact path.');
    }
    final result = origin.resolve('/$path');
    if (result.origin != origin.origin) {
      throw const UpdateFailure('Unexpected update origin.');
    }
    return result;
  }
}
