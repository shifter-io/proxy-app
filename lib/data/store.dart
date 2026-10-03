import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// What the app keeps between launches (the extension's src/lib/storage.ts).
/// The API key lives in the OS keychain; everything else is plain
/// preferences. Gateway passwords are never stored: they're fetched on
/// every connect.
abstract class Store {
  Future<Session?> readSession();
  Future<void> writeSession(Session? session);

  Future<ProxySettings> readSettings();
  Future<void> writeSettings(ProxySettings settings);

  /// Membership the user last worked with.
  Future<String?> readActiveMembership();
  Future<void> writeActiveMembership(String? id);

  /// Last chosen target per membership id.
  Future<Map<String, Target>> readTargets();
  Future<void> writeTargets(Map<String, Target> targets);

  /// Most recent residential picks, newest first.
  Future<List<ResidentialTarget>> readRecentTargets();
  Future<void> writeRecentTargets(List<ResidentialTarget> targets);

  /// Opaque JSON the system proxy keeps to restore the user's own proxy
  /// settings, even after a crash.
  Future<Map<String, dynamic>?> readProxyBackup();
  Future<void> writeProxyBackup(Map<String, dynamic>? backup);

  Future<({DateTime at, Object? data})?> readCache(String key);
  Future<void> writeCache(String key, Object? data);
}

class PersistentStore implements Store {
  PersistentStore();

  static const _apiKey = 'apiKey';
  static const _session = 'session';
  static const _settings = 'settings';
  static const _active = 'activeMembership';
  static const _targets = 'targets';
  static const _recent = 'recentTargets';
  static const _proxyBackup = 'systemProxyBackup';

  final _prefs = SharedPreferencesAsync();

  // macOS: the legacy keychain needs no keychain-access-groups entitlement
  // (and so no provisioning profile).
  final _secure = Platform.isMacOS
      ? const FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false))
      : const FlutterSecureStorage();

  Future<Object?> _json(String key) async {
    final s = await _prefs.getString(key);
    if (s == null) return null;
    try {
      return jsonDecode(s);
    } on FormatException {
      return null;
    }
  }

  Future<void> _setJson(String key, Object? value) =>
      value == null ? _prefs.remove(key) : _prefs.setString(key, jsonEncode(value));

  @override
  Future<Session?> readSession() async {
    final key = await _secure.read(key: _apiKey).catchError((_) => null);
    final j = await _json(_session);
    if (key == null || j is! Map<String, dynamic>) return null;
    try {
      return Session(
        user: User.fromJson(j['user'] as Map<String, dynamic>),
        apiKey: key,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeSession(Session? session) async {
    if (session == null) {
      await _secure.delete(key: _apiKey).catchError((_) {});
      await _prefs.remove(_session);
      return;
    }
    await _secure.write(key: _apiKey, value: session.apiKey);
    await _setJson(_session, {'user': session.user.toJson(), 'createdAt': session.createdAt.toIso8601String()});
  }

  @override
  Future<ProxySettings> readSettings() async {
    final j = await _json(_settings);
    return j is Map<String, dynamic> ? ProxySettings.fromJson(j) : const ProxySettings();
  }

  @override
  Future<void> writeSettings(ProxySettings settings) => _setJson(_settings, settings.toJson());

  @override
  Future<String?> readActiveMembership() => _prefs.getString(_active);

  @override
  Future<void> writeActiveMembership(String? id) => id == null ? _prefs.remove(_active) : _prefs.setString(_active, id);

  @override
  Future<Map<String, Target>> readTargets() async {
    final j = await _json(_targets);
    if (j is! Map<String, dynamic>) return {};
    final out = <String, Target>{};
    for (final e in j.entries) {
      final t = e.value is Map<String, dynamic> ? Target.fromJson(e.value as Map<String, dynamic>) : null;
      if (t != null) out[e.key] = t;
    }
    return out;
  }

  @override
  Future<void> writeTargets(Map<String, Target> targets) =>
      _setJson(_targets, targets.map((k, v) => MapEntry(k, v.toJson())));

  @override
  Future<List<ResidentialTarget>> readRecentTargets() async {
    final j = await _json(_recent);
    if (j is! List) return [];
    return j.whereType<Map<String, dynamic>>().map(Target.fromJson).whereType<ResidentialTarget>().toList();
  }

  @override
  Future<void> writeRecentTargets(List<ResidentialTarget> targets) =>
      _setJson(_recent, [for (final t in targets) t.toJson()]);

  @override
  Future<Map<String, dynamic>?> readProxyBackup() async {
    final j = await _json(_proxyBackup);
    return j is Map<String, dynamic> ? j : null;
  }

  @override
  Future<void> writeProxyBackup(Map<String, dynamic>? backup) => _setJson(_proxyBackup, backup);

  @override
  Future<({DateTime at, Object? data})?> readCache(String key) async {
    final j = await _json('cache:$key');
    if (j is! Map<String, dynamic>) return null;
    final at = DateTime.tryParse(j['at'] as String? ?? '');
    return at == null ? null : (at: at, data: j['data']);
  }

  @override
  Future<void> writeCache(String key, Object? data) =>
      _setJson('cache:$key', {'at': DateTime.now().toIso8601String(), 'data': data});
}

/// Keeps everything in memory: the preview studio and tests.
class MemoryStore implements Store {
  Session? session;
  ProxySettings settings = const ProxySettings();
  String? activeMembership;
  Map<String, Target> targets = {};
  List<ResidentialTarget> recentTargets = [];
  Map<String, dynamic>? proxyBackup;
  final cache = <String, ({DateTime at, Object? data})>{};

  @override
  Future<Session?> readSession() async => session;
  @override
  Future<void> writeSession(Session? s) async => session = s;
  @override
  Future<ProxySettings> readSettings() async => settings;
  @override
  Future<void> writeSettings(ProxySettings s) async => settings = s;
  @override
  Future<String?> readActiveMembership() async => activeMembership;
  @override
  Future<void> writeActiveMembership(String? id) async => activeMembership = id;
  @override
  Future<Map<String, Target>> readTargets() async => {...targets};
  @override
  Future<void> writeTargets(Map<String, Target> t) async => targets = {...t};
  @override
  Future<List<ResidentialTarget>> readRecentTargets() async => [...recentTargets];
  @override
  Future<void> writeRecentTargets(List<ResidentialTarget> t) async => recentTargets = [...t];
  @override
  Future<Map<String, dynamic>?> readProxyBackup() async => proxyBackup;
  @override
  Future<void> writeProxyBackup(Map<String, dynamic>? b) async => proxyBackup = b;
  @override
  Future<({DateTime at, Object? data})?> readCache(String key) async => cache[key];
  @override
  Future<void> writeCache(String key, Object? data) async => cache[key] = (at: DateTime.now(), data: data);
}
