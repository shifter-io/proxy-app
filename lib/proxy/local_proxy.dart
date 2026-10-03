import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bypass.dart';

/// Everything needed to route traffic through one gateway login.
class GatewayEndpoint {
  const GatewayEndpoint({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.bypassList = const [],
    this.sid,
  });
  final String host;
  final int port;

  /// Full gateway username, targeting included.
  final String username;
  final String password;
  final List<String> bypassList;

  /// Sticky session id in the username, kept when settings re-apply the same connection.
  final String? sid;

  String get _auth => 'Basic ${base64.encode(utf8.encode('$username:$password'))}';

  @override
  String toString() => 'GatewayEndpoint($host:$port, <redacted>)';
}

const _maxHead = 64 * 1024;
const _connectTimeout = Duration(seconds: 15);

/// A small HTTP proxy on 127.0.0.1 that the OS proxy settings point at. It
/// forwards every request to the Shifter gateway with the current login
/// added, and sends bypassed hosts direct.
///
/// Holding the login here (instead of handing it to every app) means a new
/// username (location, New IP, strict, session) applies to the very next
/// connection: there is no per-app login cache to fight, which is what the
/// extension has to work around in Chrome and Firefox.
class LocalProxy {
  LocalProxy({this.onRejected});

  /// Called when the gateway answers 407: the login was refused.
  void Function()? onRejected;

  ServerSocket? _server;
  GatewayEndpoint? _endpoint;
  final _viaGateway = <_Tunnel>{};
  final _all = <_Tunnel>{};

  int? get port => _server?.port;
  bool get running => _server != null;
  GatewayEndpoint? get endpoint => _endpoint;

  /// Listens on 127.0.0.1 ([port] 0 = any free port).
  Future<int> start({int port = 0}) async {
    if (_server case final s?) return s.port;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    server.listen(_accept, onError: (_) {});
    return server.port;
  }

  /// Switches the login. Open gateway tunnels keep their old exit, so they
  /// are closed: apps reconnect and get the new one.
  void setEndpoint(GatewayEndpoint? endpoint) {
    _endpoint = endpoint;
    dropGatewayConnections();
  }

  void dropGatewayConnections() {
    for (final t in [..._viaGateway]) {
      t.destroy();
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _endpoint = null;
    await s?.close();
    for (final t in [..._all]) {
      t.destroy();
    }
  }

  Future<void> _accept(Socket client) async {
    final tunnel = _Tunnel(_Peer(client));
    _all.add(tunnel);
    tunnel.onClosed = () {
      _all.remove(tunnel);
      _viaGateway.remove(tunnel);
    };
    try {
      await _handle(tunnel);
    } catch (_) {
      tunnel.destroy();
    }
  }

  Future<void> _handle(_Tunnel t) async {
    final req = await t.client.readHead();
    if (req == null) return t.destroy();
    final lines = req.head.split('\r\n');
    final requestLine = lines.first.split(' ');
    if (requestLine.length < 3) return t.reply(400, 'Bad Request');
    final [method, target, version] = requestLine;
    final headers = lines.skip(1).where((l) => l.isNotEmpty).toList();
    final endpoint = _endpoint;

    if (method.toUpperCase() == 'CONNECT') {
      final (host, port) = _splitHostPort(target, 443);
      if (host == null) return t.reply(400, 'Bad Request');
      if (endpoint == null || isBypassed(host, endpoint.bypassList)) {
        final up = await t.connect(host, port);
        if (up == null) return t.reply(502, 'Bad Gateway');
        t.client.socket.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
        return t.join(req.rest);
      }
      _viaGateway.add(t);
      final up = await t.connect(endpoint.host, endpoint.port);
      if (up == null) return t.reply(502, 'Shifter gateway unreachable');
      up.socket.add(ascii.encode(
        'CONNECT $target HTTP/1.1\r\nHost: $target\r\nProxy-Authorization: ${endpoint._auth}\r\nProxy-Connection: Keep-Alive\r\n\r\n',
      ));
      final res = await up.readHead();
      if (res == null) return t.reply(502, 'Shifter gateway closed the connection');
      final status = _status(res.head);
      if (status == 407) {
        onRejected?.call();
        return t.reply(502, 'Shifter rejected the proxy login');
      }
      if (status != 200) {
        // Pass the gateway's answer on (e.g. no IP for this location).
        t.client.socket.add(ascii.encode('${_stripHopHeaders(res.head)}\r\nConnection: close\r\n\r\n'));
        t.client.socket.add(res.rest);
        return t.closeClient();
      }
      t.client.socket.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      if (res.rest.isNotEmpty) t.client.socket.add(res.rest);
      return t.join(req.rest);
    }

    // Plain HTTP: the request line carries an absolute URL.
    final uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return t.reply(400, 'Bad Request');
    final kept = headers.where((h) => !_hop.contains(h.split(':').first.trim().toLowerCase()));
    // One request per connection: later requests on a kept-alive connection
    // could go to another host, which this proxy doesn't re-route.
    if (endpoint == null || isBypassed(uri.host, endpoint.bypassList)) {
      final up = await t.connect(uri.host, uri.hasPort ? uri.port : 80);
      if (up == null) return t.reply(502, 'Bad Gateway');
      final path = '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
      up.socket.add(ascii.encode('$method $path $version\r\n${kept.join('\r\n')}\r\nConnection: close\r\n\r\n'));
      return t.join(req.rest);
    }
    _viaGateway.add(t);
    final up = await t.connect(endpoint.host, endpoint.port);
    if (up == null) return t.reply(502, 'Shifter gateway unreachable');
    up.socket.add(ascii.encode(
      '$method $target $version\r\n${kept.join('\r\n')}\r\nProxy-Authorization: ${endpoint._auth}\r\nConnection: close\r\n\r\n',
    ));
    // Send the body on while waiting for the answer (uploads, POST).
    if (req.rest.isNotEmpty) up.socket.add(req.rest);
    t.client.pipeTo(up);
    final res = await up.readHead();
    if (res == null) return t.reply(502, 'Shifter gateway closed the connection');
    if (_status(res.head) == 407) {
      onRejected?.call();
      return t.reply(502, 'Shifter rejected the proxy login');
    }
    t.client.socket.add(ascii.encode('${res.head}\r\n\r\n'));
    if (res.rest.isNotEmpty) t.client.socket.add(res.rest);
    up.pipeTo(t.client);
  }
}

/// Request/response headers that belong to one hop only.
const _hop = {'proxy-authorization', 'proxy-connection', 'proxy-authenticate', 'connection', 'keep-alive'};

String _stripHopHeaders(String head) {
  final lines = head.split('\r\n');
  return [lines.first, ...lines.skip(1).where((h) => !_hop.contains(h.split(':').first.trim().toLowerCase()))].join('\r\n');
}

int? _status(String head) => int.tryParse(head.split(' ').elementAtOrNull(1) ?? '');

(String?, int) _splitHostPort(String authority, int fallback) {
  final v6 = RegExp(r'^\[([^\]]+)\](?::(\d+))?$').firstMatch(authority);
  if (v6 != null) return (v6[1], int.tryParse(v6[2] ?? '') ?? fallback);
  final i = authority.lastIndexOf(':');
  if (i < 0) return (authority.isEmpty ? null : authority, fallback);
  return (authority.substring(0, i), int.tryParse(authority.substring(i + 1)) ?? fallback);
}

/// One client connection and, once known, its upstream.
class _Tunnel {
  _Tunnel(this.client) {
    client.onDone = _peerDone;
  }
  final _Peer client;
  _Peer? upstream;
  void Function()? onClosed;
  bool _closed = false;

  Future<_Peer?> connect(String host, int port) async {
    try {
      final s = await Socket.connect(host, port, timeout: _connectTimeout);
      s.setOption(SocketOption.tcpNoDelay, true);
      if (_closed) {
        s.destroy();
        return null;
      }
      final peer = _Peer(s)..onDone = _peerDone;
      upstream = peer;
      return peer;
    } catch (_) {
      return null;
    }
  }

  /// Pipe both ways until either side is done.
  void join(Uint8List clientRest) {
    final up = upstream!;
    if (clientRest.isNotEmpty) up.socket.add(clientRest);
    client.pipeTo(up);
    up.pipeTo(client);
  }

  void reply(int code, String reason) {
    final body = utf8.encode('$reason\n');
    client.socket.add(ascii.encode(
      'HTTP/1.1 $code $reason\r\nContent-Type: text/plain\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n',
    ));
    client.socket.add(body);
    closeClient();
  }

  void closeClient() {
    client.socket.flush().then((_) => destroy(), onError: (_) => destroy());
  }

  void _peerDone() {
    if (client.done && (upstream?.done ?? true)) destroy();
  }

  void destroy() {
    if (_closed) return;
    _closed = true;
    client.destroy();
    upstream?.destroy();
    onClosed?.call();
  }
}

/// A socket with a single subscription that can first read an HTTP head
/// and then forward everything else to another peer, with backpressure.
class _Peer {
  _Peer(this.socket) {
    _sub = socket.listen(_onData, onError: (_) => _finish(), onDone: _finish, cancelOnError: true);
  }
  final Socket socket;
  late final StreamSubscription<Uint8List> _sub;
  final _buf = BytesBuilder(copy: false);
  Completer<void>? _more;
  _Peer? _target;
  bool done = false;
  void Function()? onDone;

  void _onData(Uint8List data) {
    final t = _target;
    if (t == null) {
      _buf.add(data);
      _more?.complete();
      _more = null;
      return;
    }
    _forward(t, data);
  }

  void _forward(_Peer t, List<int> data) {
    try {
      t.socket.add(data);
    } catch (_) {
      return destroy();
    }
    _sub.pause();
    t.socket.flush().then((_) => _sub.resume(), onError: (_) => destroy());
  }

  void _finish() {
    if (done) return;
    done = true;
    _more?.complete();
    _more = null;
    // Half-close: tell the other side nothing more is coming.
    _target?.socket.close().catchError((_) {});
    onDone?.call();
  }

  /// Bytes up to the blank line, plus whatever came after it.
  Future<({String head, Uint8List rest})?> readHead() async {
    while (true) {
      final bytes = _buf.toBytes();
      final end = _indexOfBlankLine(bytes);
      if (end >= 0) {
        _buf.clear();
        return (head: latin1.decode(bytes.sublist(0, end)), rest: Uint8List.sublistView(bytes, end + 4));
      }
      if (done || bytes.length > _maxHead) return null;
      await (_more = Completer<void>()).future.timeout(_connectTimeout, onTimeout: () => done = true);
    }
  }

  void pipeTo(_Peer t) {
    _target = t;
    if (_buf.isNotEmpty) _forward(t, _buf.takeBytes());
    if (done) t.socket.close().catchError((_) {});
  }

  void destroy() {
    _sub.cancel();
    socket.destroy();
  }
}

int _indexOfBlankLine(Uint8List b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
  }
  return -1;
}
