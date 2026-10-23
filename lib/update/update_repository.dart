import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import 'strict_json.dart';
import 'update_config.dart';
import 'update_models.dart';
import 'update_store.dart';

class UpdateRepository {
  UpdateRepository(
    this.config,
    this.identity,
    this.store, {
    required this.proxy,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final UpdateConfig config;
  final InstalledIdentity identity;
  final UpdateStore store;

  /// Returns explicit DIRECT or PROXY. Must throw during ambiguous routing.
  final String Function() proxy;
  final DateTime Function() clock;
  HttpClient? _client;
  int _generation = 0;
  void cancel() {
    _generation++;
    _client?.close(force: true);
  }

  Future<T> _request<T>(
    String path,
    int limit,
    Future<T> Function(HttpClientResponse, int) consume,
  ) async {
    final generation = _generation;
    final route = proxy();
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 20)
      ..findProxy = (_) => route;
    _client = client;
    try {
      final request = await client
          .getUrl(config.resolve(path))
          .timeout(const Duration(seconds: 25));
      request.followRedirects =
          false; // All redirects refused, including cross-origin.
      request.headers.set('Accept-Encoding', 'identity');
      request.headers.set('Cache-Control', 'no-cache');
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      if (response.statusCode != 200 ||
          response.contentLength > limit ||
          response.headers.value('content-encoding') != null) {
        throw const UpdateFailure(
          'The update server returned an invalid response.',
        );
      }
      final result = await consume(response, generation);
      if (generation != _generation || proxy() != route) {
        throw const UpdateFailure(
          'The connection changed. Please retry the update.',
        );
      }
      return result;
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  Future<VerifiedFeed> fetch() => _request(identity.feedPath, 262144, (
    response,
    generation,
  ) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 25))) {
      bytes.addAll(chunk);
      if (bytes.length > 262144) {
        throw const UpdateFailure('Update metadata is too large.');
      }
    }
    return verify(utf8.decode(bytes));
  });

  Future<VerifiedFeed> verify(String envelope) async {
    if (utf8.encode(envelope).length > 262144) {
      throw const UpdateFailure('Update metadata is too large.');
    }
    final outer = strictJson(envelope) as Map<String, dynamic>;
    final key = config.keys[outer['keyId']];
    if (key == null) {
      throw const UpdateFailure('The update publisher is not trusted.');
    }
    final payload = base64Decode(outer['payloadBase64'] as String);
    final signature = base64Decode(outer['signatureBase64'] as String);
    if (signature.length != 64 ||
        !await Ed25519().verify(
          payload,
          signature: Signature(
            signature,
            publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
          ),
        )) {
      throw const UpdateFailure('The update signature is invalid.');
    }
    final p = strictJson(utf8.decode(payload)) as Map<String, dynamic>;
    if (p['schemaVersion'] != 1 ||
        p['environment'] != 'production' ||
        p['channel'] != 'stable' ||
        p['platform'] != identity.platform ||
        p['architecture'] != identity.architecture ||
        p['distribution'] != identity.distribution.name) {
      throw const UpdateFailure(
        'This update feed is not for this installation.',
      );
    }
    final now = clock().toUtc();
    final generated = DateTime.parse(p['generatedAt'] as String).toUtc();
    final expires = DateTime.parse(p['expiresAt'] as String).toUtc();
    if (!expires.isAfter(now) ||
        generated.isAfter(now.add(const Duration(minutes: 5))) ||
        !expires.isAfter(generated) ||
        expires.difference(generated) > const Duration(hours: 48)) {
      throw const UpdateFailure(
        'Update metadata has expired or the device clock is incorrect.',
      );
    }
    final sequence = p['feedSequence'];
    if (sequence is! int || sequence < 1) {
      throw const UpdateFailure('Invalid update sequence.');
    }
    final digest = hashes.sha256.convert(payload).toString();
    final high = store.object('high.${identity.feedPath}');
    if (high != null &&
        (sequence < (high['sequence'] as int) ||
            (sequence == high['sequence'] && digest != high['digest']))) {
      throw const UpdateFailure(
        'An older or conflicting update feed was rejected.',
      );
    }
    final releases = (p['releases'] as List)
        .map((r) => Release((r as Map).cast<String, dynamic>()))
        .toList();
    final ids = <String>{};
    for (final r in releases) {
      if (identity.distribution == Distribution.desktop) {
        compareVersions(r.version, r.version);
      }
      if (r.applicationId != identity.applicationId || !ids.add(r.id)) {
        throw const UpdateFailure('Invalid release identity.');
      }
      if (identity.distribution == Distribution.desktop ||
          identity.distribution == Distribution.direct) {
        final a = r.artifact;
        if (a == null ||
            a['byteLength'] is! int ||
            r.byteLength <= 0 ||
            r.byteLength > 4 * 1024 * 1024 * 1024 ||
            a['sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(r.sha256) ||
            a['format'] !=
                (identity.distribution == Distribution.direct
                    ? 'apk'
                    : 'nupkg') ||
            a['expectedSigner'] is! String ||
            (a['expectedSigner'] as String).isEmpty) {
          throw const UpdateFailure('Invalid update artifact.');
        }
        config.resolve(r.path);
      }
    }
    await store.write(
      'high.${identity.feedPath}',
      jsonEncode({'sequence': sequence, 'digest': digest}),
    );
    return VerifiedFeed(releases, expires, sequence, digest, envelope);
  }

  Future<void> download(
    Release release,
    File destination,
    void Function(int, int) progress,
  ) async {
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const UpdateFailure('The update download destination is occupied.');
    }
    final sink = destination.openWrite(mode: FileMode.writeOnly);
    try {
      await _request(release.path, release.byteLength, (
        response,
        generation,
      ) async {
        if (response.contentLength != -1 &&
            response.contentLength != release.byteLength) {
          throw const UpdateFailure('The update size is incorrect.');
        }
        var received = 0;
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (generation != _generation) {
            throw const UpdateFailure('Download canceled.');
          }
          received += chunk.length;
          if (received > release.byteLength) {
            throw const UpdateFailure('The update exceeds its declared size.');
          }
          sink.add(chunk);
          await sink.flush();
          progress(received, release.byteLength);
        }
        if (received != release.byteLength) {
          throw const UpdateFailure('The update download is incomplete.');
        }
      });
    } finally {
      await sink.close();
    }
    await verifyFile(release, destination);
  }

  static Future<void> verifyFile(Release release, File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != release.byteLength ||
        (await hashes.sha256.bind(file.openRead()).first).toString() !=
            release.sha256) {
      throw const UpdateFailure(
        'The update package failed verification. Download it again.',
      );
    }
  }
}
