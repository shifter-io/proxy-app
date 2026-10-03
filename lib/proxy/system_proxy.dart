import 'dart:io';

import '../data/store.dart';

class SystemProxyException implements Exception {
  SystemProxyException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Points the operating system's HTTP/HTTPS proxy at the local proxy, and
/// puts the user's own settings back afterwards. The previous settings are
/// saved in [Store] before the first change, so a crash or force-quit is
/// undone on the next launch ([restoreIfNeeded]).
abstract class SystemProxy {
  static SystemProxy forPlatform(Store store) {
    if (Platform.isMacOS) return MacSystemProxy(store);
    if (Platform.isWindows) return WindowsSystemProxy(store);
    if (Platform.isLinux) return LinuxSystemProxy(store);
    return const UnsupportedSystemProxy();
  }

  bool get supported => true;

  Future<void> enable(String host, int port, List<String> bypass);
  Future<void> disable();

  /// Undo a proxy left behind by a run that didn't disconnect.
  Future<void> restoreIfNeeded() => disable();
}

/// Phones and tablets need an OS VPN / network extension to route other
/// apps; not built yet.
class UnsupportedSystemProxy implements SystemProxy {
  const UnsupportedSystemProxy();
  @override
  bool get supported => false;
  @override
  Future<void> enable(String host, int port, List<String> bypass) =>
      throw SystemProxyException("Connecting isn't available on this device yet. Use the Shifter app on your computer.");
  @override
  Future<void> disable() async {}
  @override
  Future<void> restoreIfNeeded() async {}
}

Future<String> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    throw SystemProxyException('Could not change the system proxy (${exe.split('/').last} ${args.first}: ${'${r.stderr}'.trim()})');
  }
  return '${r.stdout}';
}

// ── macOS ───────────────────────────────────────────────────────────────

/// `networksetup` on every enabled network service that is up, so it keeps
/// working when the Mac moves between Wi-Fi and Ethernet. Needs the app to
/// run outside the App Sandbox; an admin account needs no password.
class MacSystemProxy extends SystemProxy {
  MacSystemProxy(this.store);
  final Store store;
  static const _ns = '/usr/sbin/networksetup';

  /// Enabled services whose interface is up (Wi-Fi, Ethernet, USB tethering…).
  Future<List<String>> _services() async {
    final order = await _run(_ns, ['-listnetworkserviceorder']);
    final up = (await _run('/sbin/ifconfig', ['-lu'])).trim().split(RegExp(r'\s+')).toSet();
    final services = <String>[];
    String? name;
    for (final line in order.split('\n')) {
      final m = RegExp(r'^\(\d+\)\s+(.+)$').firstMatch(line.trim());
      if (m != null) {
        name = m[1];
        continue;
      }
      final dev = RegExp(r'Device:\s*([^)\s]+)').firstMatch(line)?[1];
      if (name != null && dev != null && up.contains(dev)) services.add(name);
      name = null;
    }
    return services;
  }

  Future<Map<String, dynamic>> _read(String service) async {
    Map<String, String> kv(String out) => {
          for (final l in out.split('\n'))
            if (l.contains(':')) l.substring(0, l.indexOf(':')).trim(): l.substring(l.indexOf(':') + 1).trim(),
        };
    final (web, secure, bypass) = await (
      _run(_ns, ['-getwebproxy', service]),
      _run(_ns, ['-getsecurewebproxy', service]),
      _run(_ns, ['-getproxybypassdomains', service]),
    ).wait;
    final w = kv(web), s = kv(secure);
    final domains = bypass.trim().split('\n').where((l) => l.isNotEmpty && !l.startsWith('There aren')).toList();
    return {
      'web': {'on': w['Enabled'] == 'Yes', 'host': w['Server'] ?? '', 'port': w['Port'] ?? '0'},
      'secure': {'on': s['Enabled'] == 'Yes', 'host': s['Server'] ?? '', 'port': s['Port'] ?? '0'},
      'bypass': domains,
    };
  }

  @override
  Future<void> enable(String host, int port, List<String> bypass) async {
    final services = await _services();
    if (services.isEmpty) throw SystemProxyException('No active network connection found.');
    final backup = await store.readProxyBackup() ?? {};
    final saved = (backup['services'] as Map?)?.cast<String, dynamic>() ?? {};
    for (final s in services) {
      // Keep the oldest backup: a reconnect must not save our own proxy as "theirs".
      saved[s] ??= await _read(s);
    }
    await store.writeProxyBackup({'platform': 'macos', 'services': saved});
    for (final s in services) {
      await _run(_ns, ['-setwebproxy', s, host, '$port']);
      await _run(_ns, ['-setsecurewebproxy', s, host, '$port']);
      await _run(_ns, ['-setproxybypassdomains', s, ...bypass]);
    }
  }

  @override
  Future<void> disable() async {
    final backup = await store.readProxyBackup();
    final saved = (backup?['services'] as Map?)?.cast<String, dynamic>();
    if (saved == null) return;
    for (final MapEntry(key: s, value: v as Map) in saved.entries) {
      try {
        for (final (kind, set, state) in [
          ('web', '-setwebproxy', '-setwebproxystate'),
          ('secure', '-setsecurewebproxy', '-setsecurewebproxystate'),
        ]) {
          final p = v[kind] as Map;
          // Put their server back (even when off), then their on/off state.
          if ((p['host'] as String).isNotEmpty) await _run(_ns, [set, s, p['host'] as String, '${p['port']}']);
          await _run(_ns, [state, s, p['on'] == true ? 'on' : 'off']);
        }
        final domains = (v['bypass'] as List).cast<String>();
        await _run(_ns, ['-setproxybypassdomains', s, ...(domains.isEmpty ? ['Empty'] : domains)]);
      } on SystemProxyException {
        // The service may be gone (USB tethering unplugged); nothing to restore.
      }
    }
    await store.writeProxyBackup(null);
  }
}

// ── Windows ─────────────────────────────────────────────────────────────

/// WinINet per-user settings (what Edge, Chrome and most apps follow), then
/// a settings-changed broadcast so running apps pick it up.
class WindowsSystemProxy extends SystemProxy {
  WindowsSystemProxy(this.store);
  final Store store;
  static const _key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  Future<String?> _query(String name) async {
    final r = await Process.run('reg', ['query', _key, '/v', name]);
    if (r.exitCode != 0) return null;
    final m = RegExp('$name\\s+REG_\\w+\\s+(.*)').firstMatch('${r.stdout}');
    return m?[1]?.trim();
  }

  Future<void> _set(String name, String type, String value) => _run('reg', ['add', _key, '/v', name, '/t', type, '/d', value, '/f']);

  Future<void> _delete(String name) => Process.run('reg', ['delete', _key, '/v', name, '/f']);

  Future<void> _refresh() => Process.run('powershell', [
        '-NoProfile',
        '-Command',
        r'''$s='[DllImport("wininet.dll")] public static extern bool InternetSetOption(System.IntPtr h,int o,System.IntPtr b,int l);';'''
            r'''$t=Add-Type -MemberDefinition $s -Name W -Namespace S -PassThru;$t::InternetSetOption(0,39,0,0)|Out-Null;$t::InternetSetOption(0,37,0,0)|Out-Null''',
      ]);

  @override
  Future<void> enable(String host, int port, List<String> bypass) async {
    if (await store.readProxyBackup() == null) {
      await store.writeProxyBackup({
        'platform': 'windows',
        'ProxyEnable': await _query('ProxyEnable'),
        'ProxyServer': await _query('ProxyServer'),
        'ProxyOverride': await _query('ProxyOverride'),
      });
    }
    await _set('ProxyServer', 'REG_SZ', '$host:$port');
    await _set('ProxyOverride', 'REG_SZ', [...bypass, '<local>'].join(';'));
    await _set('ProxyEnable', 'REG_DWORD', '1');
    await _refresh();
  }

  @override
  Future<void> disable() async {
    final b = await store.readProxyBackup();
    if (b == null) return;
    for (final (name, type) in [('ProxyServer', 'REG_SZ'), ('ProxyOverride', 'REG_SZ')]) {
      final v = b[name] as String?;
      v == null ? await _delete(name) : await _set(name, type, v);
    }
    final enabled = b['ProxyEnable'] as String?;
    await _set('ProxyEnable', 'REG_DWORD', enabled == null ? '0' : '${int.tryParse(enabled.replaceFirst('0x', ''), radix: 16) ?? 0}');
    await _refresh();
    await store.writeProxyBackup(null);
  }
}

// ── Linux ───────────────────────────────────────────────────────────────

/// GNOME's proxy settings (also read by most GTK apps, Chrome and Firefox
/// set to "use system proxy"). Other desktops aren't covered yet.
class LinuxSystemProxy extends SystemProxy {
  LinuxSystemProxy(this.store);
  final Store store;

  Future<String> _get(String schema, String key) async => (await _run('gsettings', ['get', schema, key])).trim();
  Future<void> _set(String schema, String key, String value) => _run('gsettings', ['set', schema, key, value]);

  static const _keys = [
    ('org.gnome.system.proxy', 'mode'),
    ('org.gnome.system.proxy', 'ignore-hosts'),
    ('org.gnome.system.proxy.http', 'host'),
    ('org.gnome.system.proxy.http', 'port'),
    ('org.gnome.system.proxy.https', 'host'),
    ('org.gnome.system.proxy.https', 'port'),
  ];

  @override
  Future<void> enable(String host, int port, List<String> bypass) async {
    try {
      if (await store.readProxyBackup() == null) {
        await store.writeProxyBackup({
          'platform': 'linux',
          for (final (schema, key) in _keys) '$schema $key': await _get(schema, key),
        });
      }
    } on ProcessException {
      throw SystemProxyException('This Linux desktop has no GNOME proxy settings (gsettings).');
    }
    final ignore = '[${bypass.map((b) => "'$b'").join(', ')}]';
    await _set('org.gnome.system.proxy.http', 'host', host);
    await _set('org.gnome.system.proxy.http', 'port', '$port');
    await _set('org.gnome.system.proxy.https', 'host', host);
    await _set('org.gnome.system.proxy.https', 'port', '$port');
    await _set('org.gnome.system.proxy', 'ignore-hosts', ignore);
    await _set('org.gnome.system.proxy', 'mode', "'manual'");
  }

  @override
  Future<void> disable() async {
    final b = await store.readProxyBackup();
    if (b == null) return;
    for (final (schema, key) in _keys) {
      final v = b['$schema $key'] as String?;
      if (v != null) await _set(schema, key, v).catchError((_) {});
    }
    await store.writeProxyBackup(null);
  }
}
