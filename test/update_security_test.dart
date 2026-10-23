import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/update/strict_json.dart';
import 'package:shifter_app/update/update_config.dart';
import 'package:shifter_app/update/update_models.dart';
import 'package:shifter_app/update/update_repository.dart';
import 'package:shifter_app/update/update_store.dart';

const identity = InstalledIdentity(
  applicationId: 'io.shifter.test',
  platform: 'android',
  architecture: 'universal',
  distribution: Distribution.direct,
  version: '1.0.0',
  build: 10,
  osVersion: '35',
);
Map<String, dynamic> releaseJson() => {
  'releaseId': 'release-11',
  'applicationId': identity.applicationId,
  'displayVersion': '1.1.0',
  'build': 11,
  'minimumOs': '29',
  'notes': 'A release',
  'enabled': true,
  'rolloutPercentage': 100,
  'artifact': {
    'relativePath': 'releases/11/Shifter.apk',
    'format': 'apk',
    'expectedSigner': 'a' * 64,
    'byteLength': 3,
    'sha256': hashes.sha256.convert(utf8.encode('abc')).toString(),
  },
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 14);
  late SimpleKeyPair key;
  late UpdateRepository repo;
  late Map<String, dynamic> payload;
  Future<String> envelope(Map<String, dynamic> value, {String? raw}) async {
    final bytes = utf8.encode(raw ?? jsonEncode(value));
    final signature = await Ed25519().sign(bytes, keyPair: key);
    return jsonEncode({
      'keyId': 'test',
      'payloadBase64': base64Encode(bytes),
      'signatureBase64': base64Encode(signature.bytes),
    });
  }

  setUp(() async {
    key = await Ed25519().newKeyPair();
    repo = UpdateRepository(
      UpdateConfig(
        origin: Uri.parse('https://updates.example.test'),
        keys: {'test': (await key.extractPublicKey()).bytes},
      ),
      identity,
      UpdateStore(null),
      proxy: () => 'DIRECT',
      clock: () => now,
    );
    payload = {
      'schemaVersion': 1,
      'environment': 'production',
      'feedSequence': 1,
      'generatedAt': now.toIso8601String(),
      'expiresAt': now.add(const Duration(hours: 48)).toIso8601String(),
      'distribution': 'direct',
      'channel': 'stable',
      'platform': 'android',
      'architecture': 'universal',
      'releases': [releaseJson()],
    };
  });
  test(
    'valid signature, exact-byte replay and monotonic feed acceptance',
    () async {
      final first = await envelope(payload);
      expect((await repo.verify(first)).sequence, 1);
      expect((await repo.verify(first)).sequence, 1);
      payload['feedSequence'] = 2;
      await repo.verify(await envelope(payload));
      await expectLater(repo.verify(first), throwsA(isA<UpdateFailure>()));
    },
  );
  test(
    'same sequence with different authenticated bytes is rejected',
    () async {
      await repo.verify(await envelope(payload));
      payload['releases'] = [];
      await expectLater(
        repo.verify(await envelope(payload)),
        throwsA(isA<UpdateFailure>()),
      );
    },
  );
  test('tampered signature and unknown signing root are rejected', () async {
    final signed = jsonDecode(await envelope(payload)) as Map;
    signed['signatureBase64'] = base64Encode(List.filled(64, 0));
    await expectLater(
      repo.verify(jsonEncode(signed)),
      throwsA(isA<UpdateFailure>()),
    );
    signed['keyId'] = 'attacker';
    await expectLater(
      repo.verify(jsonEncode(signed)),
      throwsA(isA<UpdateFailure>()),
    );
  });
  for (final field in [
    'distribution',
    'platform',
    'architecture',
    'channel',
    'environment',
    'schemaVersion',
  ]) {
    test('rejects wrong $field', () async {
      payload[field] = 'wrong';
      await expectLater(
        repo.verify(await envelope(payload)),
        throwsA(isA<UpdateFailure>()),
      );
    });
  }
  test('rejects expired and excessively long validity windows', () async {
    payload['expiresAt'] = now.toIso8601String();
    await expectLater(
      repo.verify(await envelope(payload)),
      throwsA(isA<UpdateFailure>()),
    );
    payload['expiresAt'] = now.add(const Duration(hours: 49)).toIso8601String();
    await expectLater(
      repo.verify(await envelope(payload)),
      throwsA(isA<UpdateFailure>()),
    );
  });
  test('rejects duplicate fields even inside a valid signature', () async {
    final raw = jsonEncode(
      payload,
    ).replaceFirst('"schemaVersion":1', '"schemaVersion":1,"schemaVersion":1');
    await expectLater(
      repo.verify(await envelope(payload, raw: raw)),
      throwsFormatException,
    );
    expect(() => strictJson(r'{"a":1,"\u0061":2}'), throwsFormatException);
  });
  test('rejects traversal, encoded and absolute artifact paths', () async {
    for (final path in [
      '../evil.apk',
      '/root/file.apk',
      'https://evil.test/a',
      'releases/%2e%2e/a',
      'a\\b',
      'a//b',
    ]) {
      final r = releaseJson();
      (r['artifact'] as Map)['relativePath'] = path;
      payload['releases'] = [r];
      await expectLater(
        repo.verify(await envelope(payload)),
        throwsA(isA<UpdateFailure>()),
      );
    }
  });
  test(
    'native version comparisons reject downgrades and malformed versions',
    () {
      expect(identity.newer(Release(releaseJson()..['build'] = 9)), isFalse);
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(comparePublicVersions('1.2', '1.2.0'), 0);
      expect(comparePublicVersions('1.3', '1.2.9'), greaterThan(0));
      expect(
        () => compareVersions('1.0.0-beta', '1.0.0'),
        throwsA(isA<UpdateFailure>()),
      );
    },
  );
  test('file verification rejects corruption, truncation and symlinks', () async {
    final base = Directory(
      '${Platform.environment['HOME']}/Library/Caches/shifter-vpn/build/application-updates/security-tests',
    );
    await base.create(recursive: true);
    final directory = await base.createTemp('package-');
    try {
      final file = File('${directory.path}/artifact');
      final release = Release(releaseJson());
      await file.writeAsString('abc');
      await UpdateRepository.verifyFile(release, file);
      await file.writeAsString('abd');
      await expectLater(
        UpdateRepository.verifyFile(release, file),
        throwsA(isA<UpdateFailure>()),
      );
      await file.writeAsString('ab');
      await expectLater(
        UpdateRepository.verifyFile(release, file),
        throwsA(isA<UpdateFailure>()),
      );
      await file.writeAsString('abc');
      final link = Link('${directory.path}/link');
      await link.create(file.path);
      await expectLater(
        UpdateRepository.verifyFile(release, File(link.path)),
        throwsA(isA<UpdateFailure>()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
