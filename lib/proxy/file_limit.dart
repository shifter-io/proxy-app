import 'dart:ffi';
import 'dart:io';

/// Every connection through the local proxy uses two open files (the app's
/// side and the gateway's). Apps started from the Dock or Finder get a soft
/// limit of 256 open files on macOS, which caps the proxy at roughly 70-120
/// simultaneous connections; past that, connections fail. Shifter itself
/// has no connection limit, so lift ours: raise the soft limit as far as the
/// system allows. Allowed for any process (it only raises its own limit up
/// to the hard limit); no-op on Windows, which has no such limit.
///
/// Returns the soft limit in effect afterwards, or null where it doesn't apply.
int? raiseOpenFileLimit() {
  if (!Platform.isMacOS && !Platform.isLinux) return null;
  try {
    final libc = DynamicLibrary.process();
    final getrlimit = libc.lookupFunction<Int32 Function(Int32, Pointer<Uint64>), int Function(int, Pointer<Uint64>)>('getrlimit');
    final setrlimit = libc.lookupFunction<Int32 Function(Int32, Pointer<Uint64>), int Function(int, Pointer<Uint64>)>('setrlimit');
    final resource = Platform.isMacOS ? 8 : 7; // RLIMIT_NOFILE
    // struct rlimit { rlim_t rlim_cur; rlim_t rlim_max; }, rlim_t = uint64.
    final limit = _alloc(2);
    try {
      if (getrlimit(resource, limit) != 0) return null;
      final hard = limit[1];
      // macOS refuses values above kern.maxfilesperproc (or "unlimited"),
      // so step down until one is accepted.
      for (final want in [1048576, 245760, 65536, 24576, 10240]) {
        if (want <= limit[0]) break;
        if (want > hard) continue;
        limit[0] = want;
        if (setrlimit(resource, limit) == 0) break;
        getrlimit(resource, limit);
      }
      getrlimit(resource, limit);
      return limit[0];
    } finally {
      _free(limit);
    }
  } catch (_) {
    return null; // never fatal: the proxy works, with a lower ceiling
  }
}

final _libc = DynamicLibrary.process();
final _malloc = _libc.lookupFunction<Pointer<Uint64> Function(IntPtr), Pointer<Uint64> Function(int)>('malloc');
final _freeFn = _libc.lookupFunction<Void Function(Pointer<Uint64>), void Function(Pointer<Uint64>)>('free');
Pointer<Uint64> _alloc(int count) => _malloc(count * 8);
void _free(Pointer<Uint64> p) => _freeFn(p);
