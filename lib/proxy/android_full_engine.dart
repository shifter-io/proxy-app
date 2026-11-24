import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'local_proxy.dart';
import 'proxy_engine.dart';
import 'socks_login.dart';
import 'system_proxy.dart' show SystemProxyException;

/// Android full-device mode: the VPN slot routes every packet, TCP and UDP,
/// through the gateway's SOCKS5 (android/.../FullTunnel.kt). Shifter itself
/// is outside the VPN, so the exit check goes through SOCKS5 here too.
class AndroidFullEngine implements ProxyEngine {
  AndroidFullEngine({this.checkUrl = ipCheckUrl}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopped') _stopped.add(null);
    });
  }

  static const _channel = MethodChannel('shifter/vpn');
  final String checkUrl;
  final _rejected = StreamController<void>.broadcast();
  final _stopped = StreamController<void>.broadcast();
  Map<String, Object>? _login;

  @override
  bool get supported => true;
  @override
  Stream<void> get rejected => _rejected.stream;
  @override
  Stream<void> get stopped => _stopped.stream;

  /// The VPN slot closes with the app's process, so nothing can be left behind.
  @override
  Future<void> recover() async {}

  @override
  Future<void> apply(GatewayEndpoint endpoint) async {
    final login = socksLogin(endpoint);
    if (login == null) throw SystemProxyException('This build has no full-device login.');
    try {
      await _channel.invokeMethod('start', {'host': '127.0.0.1', 'port': 0, 'bypass': <String>[], 'socks': login});
      _login = login;
    } on PlatformException catch (e) {
      throw SystemProxyException(e.message ?? 'Could not start the connection.');
    }
  }

  @override
  Future<void> clear() async {
    await _channel.invokeMethod('stop');
    _login = null;
  }

  @override
  Future<ExitInfo> checkExit() async {
    final login = _login;
    if (login == null) throw StateError('Not connected');
    return checkExitThroughSocks(login, checkUrl);
  }
}

/// Asks the IP service at [url] for the exit address through the gateway's
/// SOCKS5 with [login] (same session, so the same exit as the device).
Future<ExitInfo> checkExitThroughSocks(Map<String, Object> login, String url) async {
  const timeout = Duration(seconds: 12);
  final uri = Uri.parse(url);
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  final socket = await RawSocket.connect(login['host'] as String, login['port'] as int, timeout: timeout);
  final conn = _RawConn(socket);
  RawSocket? secure;
  try {
    conn.write([5, 1, 2]);
    if ((await conn.read(2).timeout(timeout))[1] != 2) throw const HttpException('Login method refused');
    final user = utf8.encode(login['username'] as String), pass = utf8.encode(login['password'] as String);
    conn.write([1, user.length, ...user, pass.length, ...pass]);
    if ((await conn.read(2).timeout(timeout))[1] != 0) throw const HttpException('Login refused');
    final host = utf8.encode(uri.host);
    conn.write([5, 1, 0, 3, host.length, ...host, port >> 8, port & 0xff]);
    final head = await conn.read(4).timeout(timeout);
    if (head[1] != 0) throw HttpException('Gateway could not reach ${uri.host} (${head[1]})');
    final addrLen = switch (head[3]) { 1 => 4, 4 => 16, _ => (await conn.read(1).timeout(timeout))[0] };
    await conn.read(addrLen + 2).timeout(timeout);

    final RawSocket stream;
    final RawConnTarget target;
    if (uri.scheme == 'https') {
      if (conn.hasLeftover) throw const HttpException('Unexpected data before TLS');
      secure = await RawSecureSocket.secure(socket, subscription: conn.subscription, host: uri.host)
          .timeout(timeout);
      stream = secure;
      target = _RawConn(secure);
    } else {
      stream = socket;
      target = conn;
    }
    target.write(utf8.encode('GET ${uri.path.isEmpty ? '/' : uri.path} HTTP/1.1\r\nHost: ${uri.host}\r\n'
        'Cache-Control: no-store\r\nConnection: close\r\n\r\n'));
    final text = utf8.decode(await target.readToEnd().timeout(timeout), allowMalformed: true);
    stream.shutdown(SocketDirection.both);
    final split = text.indexOf('\r\n\r\n');
    if (!text.startsWith('HTTP/1.1 200') || split < 0) throw const HttpException('IP check failed');
    var body = text.substring(split + 4);
    if (text.substring(0, split).toLowerCase().contains('transfer-encoding: chunked')) body = _unchunk(body);
    final json = jsonDecode(body) as Map<String, dynamic>;
    final ip = json['ip'] as String?;
    if (ip == null || ip.isEmpty) throw const HttpException('IP check returned no address');
    return ExitInfo(ip, country: (json['country'] as String?)?.toLowerCase());
  } finally {
    secure?.close();
    socket.close();
  }
}

String _unchunk(String body) {
  final out = StringBuffer();
  var i = 0;
  while (i < body.length) {
    final end = body.indexOf('\r\n', i);
    if (end < 0) break;
    final size = int.tryParse(body.substring(i, end).split(';').first.trim(), radix: 16) ?? 0;
    if (size == 0) break;
    out.write(body.substring(end + 2, end + 2 + size));
    i = end + 2 + size + 2;
  }
  return out.toString();
}

typedef RawConnTarget = _RawConn;

/// Exact-length reads and full writes over a [RawSocket] (or the TLS socket
/// on top of it) for the short SOCKS5 + HTTP exchange.
class _RawConn {
  _RawConn(this.socket) {
    subscription = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final data = socket.read();
        if (data != null) _buffer.add(data);
      } else if (event == RawSocketEvent.write) {
        _flush();
      } else if (event == RawSocketEvent.readClosed || event == RawSocketEvent.closed) {
        _closed = true;
      }
      _wake?.complete();
      _wake = null;
    }, onError: (Object e) {
      _closed = true;
      _wake?.complete();
      _wake = null;
    });
  }

  final RawSocket socket;
  late final StreamSubscription<RawSocketEvent> subscription;
  final _buffer = BytesBuilder();
  final _pending = <int>[];
  bool _closed = false;
  Completer<void>? _wake;

  void write(List<int> bytes) {
    _pending.addAll(bytes);
    _flush();
  }

  void _flush() {
    while (_pending.isNotEmpty) {
      final n = socket.write(_pending);
      if (n <= 0) {
        socket.writeEventsEnabled = true;
        return;
      }
      _pending.removeRange(0, n);
    }
  }

  Future<Uint8List> read(int count) async {
    while (_buffer.length < count && !_closed) {
      await (_wake ??= Completer<void>()).future;
    }
    final all = _buffer.takeBytes();
    if (all.length < count) throw const SocketException('Closed during handshake');
    _buffer.add(all.sublist(count));
    return Uint8List.sublistView(all, 0, count);
  }

  Future<Uint8List> readToEnd() async {
    while (!_closed) {
      await (_wake ??= Completer<void>()).future;
    }
    return _buffer.takeBytes();
  }

  /// Bytes received but not consumed (the gateway sends none before TLS).
  bool get hasLeftover => _buffer.isNotEmpty;
}
