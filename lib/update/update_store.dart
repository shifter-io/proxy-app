import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Separate from account storage. Each transaction is one awaited preference write.
class UpdateStore {
  UpdateStore(this._prefs);
  final SharedPreferencesAsync? _prefs;
  final Map<String, String> _memory = {};
  static const prefix = 'shifter.updates.v1.';
  // Preserve the physical keys written by SharedPreferences on desktop.
  static const _diskPrefix = 'flutter.$prefix';
  static const _androidMigrated = '${prefix}migrated';

  static Future<UpdateStore> open() async {
    // Use the same backend as proxy settings and analytics. On Windows and
    // Linux, independent cached backends can overwrite the entire prefs file.
    final prefs = SharedPreferencesAsync();
    if (Platform.isAndroid && await prefs.getBool(_androidMigrated) != true) {
      // Android's async backend defaults to DataStore. Copy only our keys
      // from the legacy preferences file and preserve any newer values.
      final legacy = await SharedPreferences.getInstance();
      for (final key in legacy.getKeys().where(
        (key) => key.startsWith(prefix),
      )) {
        final value = legacy.getString(key);
        final diskKey = 'flutter.$key';
        if (value != null && !await prefs.containsKey(diskKey)) {
          await prefs.setString(diskKey, value);
        }
      }
      await prefs.setBool(_androidMigrated, true);
    }
    final store = UpdateStore(prefs);
    final keys = (await prefs.getKeys())
        .where((key) => key.startsWith(_diskPrefix))
        .toSet();
    for (final entry in (await prefs.getAll(allowList: keys)).entries) {
      if (entry.value case final String value) {
        store._memory[entry.key.substring(_diskPrefix.length)] = value;
      }
    }
    return store;
  }

  String? read(String key) => _memory[key];
  Future<void> write(String key, String? value) async {
    if (value == null) {
      await _prefs?.remove('$_diskPrefix$key');
      _memory.remove(key);
    } else {
      await _prefs?.setString('$_diskPrefix$key', value);
      _memory[key] = value;
    }
  }

  Map<String, dynamic>? object(String key) {
    final value = read(key);
    return value == null
        ? null
        : (jsonDecode(value) as Map).cast<String, dynamic>();
  }

  DateTime? time(String key) => DateTime.tryParse(read(key) ?? '');
  Future<int> cohort() async {
    final current = int.tryParse(read('cohort') ?? '');
    if (current != null) return current;
    final value = Random.secure().nextInt(100);
    await write('cohort', '$value');
    return value;
  }

  static Future<bool> consumeRestartSuppression() async {
    final store = await open();
    final package = await PackageInfo.fromPlatform();
    final current =
        '${package.packageName}:${package.version}:${package.buildNumber}';
    final previous = store.read('installedIdentity');
    final suppress =
        store.read('suppressReconnect') == 'true' ||
        (previous != null && previous != current);
    await store.write('installedIdentity', current);
    await store.write('suppressReconnect', null);
    return suppress;
  }
}
