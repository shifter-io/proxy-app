import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../update/update_models.dart';

/// Optional first-party measurement. Collects only release and lifecycle data.
class InstallationAnalytics extends ChangeNotifier {
  InstallationAnalytics({required this.canSend})
    : _origin = _readOrigin(),
      _credentialStore = Platform.isMacOS
          ? const FlutterSecureStorage(
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            )
          : const FlutterSecureStorage();

  static const _enabledKey = 'shifter.analytics.v1.enabled';
  static const _stateKey = 'shifter.analytics.v1.state';
  static const _credentialKey = 'shifter.analytics.v1.writeCredential';
  static const _queueLimit = 64;
  final bool Function() canSend;
  final Uri? _origin;
  final FlutterSecureStorage _credentialStore;
  final _preferences = SharedPreferencesAsync();
  InstalledIdentity? _identity;
  Future<void> _writes = Future.value();
  HttpClient? _client;
  Timer? _retry;
  bool _enabled = false;
  bool _initialized = false;
  bool _disposed = false;
  bool _started = false;

  bool get available => _origin != null && _identity != null;
  bool get enabled => _enabled;
  bool get ready => _initialized;

  static Uri? _readOrigin() {
    final uri = Uri.tryParse(
      const String.fromEnvironment('SHIFTER_ANALYTICS_ORIGIN'),
    );
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty &&
            !uri.hasQuery &&
            !uri.hasFragment &&
            (uri.path.isEmpty || uri.path == '/')
        ? uri
        : null;
  }

  Future<void> initialize(InstalledIdentity identity) async {
    if (_origin == null ||
        (identity.distribution != Distribution.desktop &&
            identity.distribution != Distribution.direct)) {
      return;
    }
    _identity = identity;
    await _serialize(() async {
      _enabled = await _preferences.getBool(_enabledKey) ?? false;
      _initialized = true;
      if (!_disposed) notifyListeners();
      if (_enabled) await _recordStart();
    });
    _flush();
  }

  Future<void> setEnabled(bool enabled) async {
    if (!_initialized || _enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) _client?.close(force: true);
    if (!_disposed) notifyListeners();
    await _serialize(() async {
      await _preferences.setBool(_enabledKey, enabled);
      if (enabled && _enabled) {
        await _recordStart();
      } else if (!enabled) {
        final state = await _readState();
        state.remove('queue');
        await _writeState(state);
        _started = false;
      }
    });
    _flush();
  }

  Future<void> _serialize(Future<void> Function() action) {
    _writes = _writes
        .then((_) async {
          if (!_disposed) await action();
        })
        .catchError((Object _) {
          // Analytics and its storage never affect app or proxy startup.
        });
    return _writes;
  }

  Future<Map<String, dynamic>> _readState() async {
    final raw = await _preferences.getString(_stateKey);
    if (raw != null) {
      try {
        return (jsonDecode(raw) as Map).cast<String, dynamic>();
      } on Exception {
        // Corrupted private state can be recreated.
      }
    }
    return {};
  }

  Future<void> _writeState(Map<String, dynamic> state) =>
      _preferences.setString(_stateKey, jsonEncode(state));

  String _randomId(int bytes) {
    final random = Random.secure();
    return List.generate(
      bytes,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<(Map<String, dynamic>, String)> _installation() async {
    var state = await _readState();
    var credential = await _credentialStore.read(key: _credentialKey);
    if (state['id'] == null || credential == null) {
      credential = _randomId(32);
      state = {'id': _randomId(16)};
      await _credentialStore.write(key: _credentialKey, value: credential);
      await _writeState(state);
    }
    return (state, credential);
  }

  Map<String, dynamic> _event(
    String name,
    String id, {
    String? previousVersion,
  }) {
    final identity = _identity!;
    return {
      'eventId': id,
      'name': name,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
      'platform': identity.platform,
      'architecture': identity.architecture,
      'channel': identity.distribution.name,
      'version': identity.version,
      'build': identity.build,
      'previousVersion': ?previousVersion,
    };
  }

  List<Map<String, dynamic>> _queue(Map<String, dynamic> state) =>
      (state['queue'] as List? ?? []).cast<Map<String, dynamic>>();

  Future<void> _recordStart() async {
    if (_started) return;
    final (state, _) = await _installation();
    final pending = _queue(state);
    if (state['firstAccepted'] != true &&
        !pending.any((event) => event['name'] == 'first_launch')) {
      final event = _event('first_launch', state['id'] as String);
      if (Platform.isWindows) {
        final local = Platform.environment['LOCALAPPDATA'];
        if (local != null) {
          final path = '$local\\Shifter\\install-attribution.txt';
          final file = File(path);
          try {
            if (await FileSystemEntity.type(path, followLinks: false) ==
                    FileSystemEntityType.file &&
                await file.length() <= 36) {
              final token = (await file.readAsString()).trim();
              if (RegExp(r'^[0-9a-f]{32}$').hasMatch(token)) {
                event['attributionToken'] = token;
              }
            }
          } on FileSystemException {
            // An installation can be counted without attribution.
          }
        }
      }
      pending.add(event);
    }
    pending.add(_event('app_started', _randomId(16)));
    await _saveQueue(state, pending);
    _started = true;
  }

  Future<void> recordUpdate(String previousVersion) async {
    if (!_enabled || _identity == null) return;
    await _serialize(() async {
      if (!_enabled) return;
      final (state, _) = await _installation();
      final pending = _queue(state);
      final event = _event(
        'update_applied',
        _randomId(16),
        previousVersion: previousVersion,
      );
      pending.add(event);
      await _saveQueue(state, pending);
    });
    _flush();
  }

  Future<void> _saveQueue(
    Map<String, dynamic> state,
    List<Map<String, dynamic>> pending,
  ) async {
    while (pending.length > _queueLimit) {
      final index = pending.indexWhere(
        (event) => event['name'] == 'app_started',
      );
      pending.removeAt(index >= 0 ? index : 1);
    }
    state['queue'] = pending;
    await _writeState(state);
  }

  void routeChanged() {
    if (!canSend()) {
      _client?.close(force: true);
    } else {
      _flush();
    }
  }

  void _flush() {
    if (_disposed || !_enabled || _client != null || !canSend()) return;
    _retry?.cancel();
    _retry = null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..userAgent = null;
    client.findProxy = (_) => 'DIRECT';
    _client = client;
    unawaited(_send(client));
  }

  Future<void> _send(HttpClient client) async {
    try {
      await _writes;
      final state = await _readState();
      final pending = _queue(state);
      if (pending.isEmpty || !_enabled || !canSend()) return;
      final token = await _credentialStore.read(key: _credentialKey);
      if (token == null) return;
      final id = state['id'] as String;
      await _post(client, '/v1/installations', id, token, const {});
      for (final event in pending) {
        await _post(client, '/v1/events', id, token, event);
        await _serialize(() async {
          final latest = await _readState();
          if (latest['id'] != id) return;
          final queue = _queue(latest)
            ..removeWhere((item) => item['eventId'] == event['eventId']);
          if (event['name'] == 'first_launch') latest['firstAccepted'] = true;
          await _saveQueue(latest, queue);
        });
      }
    } catch (_) {
      // Preserve IDs for retry after an unavailable collector or route change.
    } finally {
      client.close(force: true);
      _client = null;
      try {
        final pending = _queue(await _readState());
        if (!_disposed && _enabled && canSend() && pending.isNotEmpty) {
          _retry = Timer(const Duration(minutes: 1), _flush);
        }
      } catch (_) {
        // A failed analytics preference read is safe to leave until next launch.
      }
    }
  }

  Future<void> _post(
    HttpClient client,
    String path,
    String id,
    String token,
    Map<String, dynamic> body,
  ) async {
    if (!_enabled || !canSend()) throw StateError('Analytics transport paused');
    final request = await client.postUrl(_origin!.resolve(path));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set('X-Shifter-Installation', id);
    final payload = utf8.encode(jsonEncode(body));
    request.contentLength = payload.length;
    request.add(payload);
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != 204) {
      throw const HttpException('Analytics delivery failed');
    }
    await response.drain<void>();
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _client?.close(force: true);
    super.dispose();
  }
}
