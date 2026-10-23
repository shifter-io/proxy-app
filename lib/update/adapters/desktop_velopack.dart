import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../update_models.dart';
import 'update_adapter.dart';

String _libraryPath() {
  final executable = File(Platform.resolvedExecutable).parent;
  if (Platform.isMacOS) {
    return '${executable.parent.path}/Frameworks/libshifter_updater.dylib';
  }
  if (Platform.isWindows) return '${executable.path}/shifter_updater.dll';
  return '${executable.path}/lib/libshifter_updater.so';
}

Future<Map<String, dynamic>> _native(Map<String, dynamic> request) async {
  final path = _libraryPath();
  final encoded = jsonEncode(request);
  return Isolate.run(() {
    final library = DynamicLibrary.open(path);
    final call = library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Utf8>)
        >('shifter_update_call');
    final free = library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('shifter_update_free');
    final input = encoded.toNativeUtf8();
    Pointer<Utf8>? output;
    try {
      output = call(input);
      final response = jsonDecode(output.toDartString()) as Map;
      if (response['error'] != null) {
        throw UpdateFailure(response['error'] as String);
      }
      return (response['result'] as Map).cast<String, dynamic>();
    } finally {
      calloc.free(input);
      if (output != null) free(output);
    }
  });
}

class DesktopVelopackAdapter implements UpdateAdapter {
  bool _installed = false;
  String _osVersion = '0.0.0';
  bool _installable = false;
  @override
  Future<InstalledIdentity> identity() async {
    final info = await PackageInfo.fromPlatform();
    String version = info.version;
    try {
      final native = await _native({'method': 'identity'});
      version = native['version'] as String;
      _installed = true;
      _installable = native['install'] == true;
    } catch (_) {
      /* Unpackaged build. */
    }
    final abi = Abi.current().toString();
    String os = '0.0.0';
    if (Platform.isMacOS) {
      os = (await Process.run('/usr/bin/sw_vers', [
        '-productVersion',
      ])).stdout.toString().trim();
    }
    if (Platform.isWindows) {
      os =
          RegExp(r'\d+\.\d+\.\d+')
              .firstMatch(Platform.operatingSystemVersion)
              ?.group(0) ??
          os;
    }
    _osVersion = os;
    return InstalledIdentity(
      applicationId: info.packageName,
      platform: Platform.operatingSystem,
      architecture: abi.contains('arm64')
          ? 'arm64'
          : abi.contains('x64')
          ? 'x64'
          : 'unsupported',
      distribution: Distribution.desktop,
      version: version,
      build: int.tryParse(info.buildNumber) ?? 0,
      osVersion: os,
    );
  }

  @override
  Future<UpdateCapabilities> capabilities() async => UpdateCapabilities(
    download: _installed && _installable,
    cancel: true,
    install: _installable,
    reason: !_installed
        ? 'Install a packaged Shifter release to enable updates.'
        : !_installable
        ? 'Automatic updates are not yet qualified for this Linux installation. Install a newer AppImage manually.'
        : null,
  );
  @override
  Future<bool> eligible(Release release, {required bool automatic}) async {
    if (!_installed || !_installable) return false;
    List<int> parts(String value) => value.split('.').map(int.parse).toList();
    final current = parts(_osVersion), minimum = parts(release.minimumOs);
    for (var i = 0; i < minimum.length; i++) {
      final actual = i < current.length ? current[i] : 0;
      if (actual != minimum[i]) return actual > minimum[i];
    }
    return true;
  }

  @override
  Future<void> prepare(Release release, String? path) async {
    await _native({'method': 'prepare', 'release': release.json, 'path': path});
  }

  @override
  Future<void> install(
    Release release,
    String? path,
    String operationId,
  ) async {
    await _native({
      'method': 'install',
      'release': release.json,
      'path': path,
      'operationId': operationId,
    });
  }

  @override
  Future<Map<String, dynamic>> reconcile() async => {};
  @override
  Future<void> openStore() async =>
      throw const UpdateFailure('This installation does not use an app store.');
  @override
  Future<void> startStoreDownload(String operationId, Release release) =>
      openStore();
}
