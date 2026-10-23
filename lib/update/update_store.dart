import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Separate from account storage. Each transaction is one awaited preference write.
class UpdateStore {
  UpdateStore(this._prefs);
  final SharedPreferences? _prefs;
  final Map<String, Object> _memory = {};
  static const prefix = 'shifter.updates.v1.';
  static Future<UpdateStore> open() async =>
      UpdateStore(await SharedPreferences.getInstance());
  String? read(String key) =>
      _prefs?.getString('$prefix$key') ?? _memory[key] as String?;
  Future<void> write(String key, String? value) async {
    if (value == null) {
      _memory.remove(key);
    } else {
      _memory[key] = value;
    }
    if (_prefs != null) {
      final ok = value == null
          ? await _prefs.remove('$prefix$key')
          : await _prefs.setString('$prefix$key', value);
      if (!ok) throw StateError('Could not save update state.');
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
