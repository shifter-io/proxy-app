import 'dart:convert';

enum UpdatePhase {
  idle,
  checking,
  current,
  available,
  unavailable,
  downloading,
  verifying,
  ready,
  preparingInstall,
  awaitingSystemConsent,
  handingOff,
  error,
}

enum Distribution { desktop, play, direct, appStore, development }

class UpdateFailure implements Exception {
  const UpdateFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Stable releases only. Android builds are compared separately as integers.
int compareVersions(String a, String b) {
  List<int> parts(String s) {
    if (!RegExp(r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')
        .hasMatch(s)) {
      throw const UpdateFailure('Invalid stable release version.');
    }
    return s.split('.').map(int.parse).toList();
  }

  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final result = x[i].compareTo(y[i]);
    if (result != 0) return result;
  }
  return 0;
}

/// Apple's public marketing version can omit trailing zero components.
int comparePublicVersions(String a, String b) {
  String normalize(String value) {
    if (!RegExp(r'^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}$').hasMatch(value)) {
      throw const UpdateFailure('Invalid public release version.');
    }
    return [
      ...value.split('.'),
      ...List.filled(3 - value.split('.').length, '0'),
    ].join('.');
  }

  return compareVersions(normalize(a), normalize(b));
}

class InstalledIdentity {
  const InstalledIdentity({
    required this.applicationId,
    required this.platform,
    required this.architecture,
    required this.distribution,
    required this.version,
    required this.build,
    required this.osVersion,
    this.storefront,
  });
  final String applicationId, platform, architecture, version, osVersion;
  final int build;
  final Distribution distribution;
  final String? storefront;
  String get feedPath =>
      '${distribution.name}/$platform/$architecture/stable.json';
  bool newer(Release release) => platform == 'android'
      ? release.build > build
      : (platform == 'ios'
                ? comparePublicVersions(release.version, version)
                : compareVersions(release.version, version)) >
            0;
}

class UpdateCapabilities {
  const UpdateCapabilities({
    this.download = false,
    this.cancel = false,
    this.install = false,
    this.store = false,
    this.reason,
  });
  final bool download, cancel, install, store;
  final String? reason;
}

class Release {
  Release(this.json) {
    for (final key in [
      'releaseId',
      'applicationId',
      'displayVersion',
      'minimumOs',
      'notes',
    ]) {
      if (json[key] is! String) {
        throw const UpdateFailure('Invalid release metadata.');
      }
    }
    comparePublicVersions(version, version);
    if (json['build'] is! int ||
        build < 1 ||
        json['enabled'] is! bool ||
        json['rolloutPercentage'] is! int ||
        rollout < 0 ||
        rollout > 100 ||
        utf8.encode(notes).length > 8192) {
      throw const UpdateFailure('Invalid release metadata.');
    }
  }
  final Map<String, dynamic> json;
  String get id => json['releaseId'] as String;
  String get applicationId => json['applicationId'] as String;
  String get version => json['displayVersion'] as String;
  int get build => json['build'] as int;
  String get notes => json['notes'] as String;
  String get minimumOs => json['minimumOs'] as String;
  bool get enabled => json['enabled'] == true;
  int get rollout => json['rolloutPercentage'] as int;
  Map<String, dynamic>? get artifact =>
      (json['artifact'] as Map?)?.cast<String, dynamic>();
  Map<String, dynamic>? get store =>
      (json['store'] as Map?)?.cast<String, dynamic>();
  String get path => artifact!['relativePath'] as String;
  String get sha256 => artifact!['sha256'] as String;
  int get byteLength => artifact!['byteLength'] as int;
  bool sameArtifact(Release other) =>
      id == other.id &&
      version == other.version &&
      build == other.build &&
      jsonEncode(artifact) == jsonEncode(other.artifact);
}

class VerifiedFeed {
  const VerifiedFeed(
    this.releases,
    this.expiresAt,
    this.sequence,
    this.digest,
    this.envelope,
  );
  final List<Release> releases;
  final DateTime expiresAt;
  final int sequence;
  final String digest, envelope;
}
