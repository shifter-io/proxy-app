// Shared by the device end to end host scripts (android_e2e.dart, ios_e2e.dart).
import 'dart:async';
import 'dart:io';

Future<void> until(Future<bool> Function() ok, String what, {int seconds = 120}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!await ok()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

/// PASS/FAIL lines as the run goes, and the exit code at the end.
class Checks {
  final failures = <String>[];

  void check(bool ok, String what) {
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $what');
    if (!ok) failures.add(what);
  }

  Never finish(String device) {
    stdout.writeln(failures.isEmpty ? '\nAll checks passed on $device.' : '\n${failures.length} check(s) failed on $device.');
    exit(failures.isEmpty ? 0 : 1);
  }
}
