import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bypass.dart';
import 'file_limit.dart';

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

/// Bytes read from a socket at a time; also the most a tunnel holds in
/// memory per direction (the OS socket buffers absorb the rest).
const _chunk = 64 * 1024;

final _established = ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n');

/// A small HTTP proxy on 127.0.0.1 that the OS proxy settings point at. It
/// forwards every request to the Shifter gateway with the current login
/// added, and sends bypassed hosts direct.
///
/// Holding the login here (instead of handing it to every app) means a new
/// username (location, New IP, strict, session) applies to the very next
/// connection: there is no per-app login cache to fight, which is what the
/// extension has to work around in Chrome and Firefox.
///
/// Bytes are moved with [RawSocket]: each write goes straight to the OS and
/// a peer stops reading while the other side can't take more, so a tunnel
/// holds at most one chunk per direction, whatever the speed difference
/// between the app and the site. Idle, it costs no CPU (no timers).
class LocalProxy {
  LocalProxy({this.onRejected});

  /// Called when the gateway answers 407: the login was refused.
  void Function()? onRejected;

  RawServerSocket? _server;
  GatewayEndpoint? _endpoint;
  final _viaGateway = <_Tunnel>{};
  final _all = <_Tunnel>{};

  int? get port => _server?.port;
  bool get running => _server != null;
  GatewayEndpoint? get endpoint => _endpoint;

  /// Open client connections (diagnostics, tests).
  int get openConnections => _all.length;

  /// Listens on 127.0.0.1 ([port] 0 = any free port).
  Future<int> start({int port = 0}) async {
    if (_server case final s?) return s.port;
    raiseOpenFileLimit();
    // A page load opens dozens of connections at once; don't refuse any.
    final server = await RawServerSocket.bind(InternetAddress.loopbackIPv4, port, backlog: 1024);
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

  void _accept(RawSocket client) {
    client.setOption(SocketOption.tcpNoDelay, true);
    final tunnel = _Tunnel(client);
    _all.add(tunnel);
    tunnel.onClosed = () {
      _all.remove(tunnel);
      _viaGateway.remove(tunnel);
    };
    _handle(tunnel).catchError((_) => tunnel.destroy());
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
        if (await t.connect(host, port) == null) return t.reply(502, 'Bad Gateway');
        t.client.send(_established);
        return t.join(req.rest);
      }
      _viaGateway.add(t);
      final up = await t.connect(endpoint.host, endpoint.port);
      if (up == null) return t.reply(502, 'Shifter gateway unreachable');
      up.send(ascii.encode(
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
        t.client.send(ascii.encode('${_stripHopHeaders(res.head)}\r\nConnection: close\r\n\r\n'));
        t.client.send(res.rest);
        return t.client.closeWhenSent();
      }
      t.client.send(_established);
      t.client.send(res.rest);
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
      up.send(ascii.encode('$method $path $version\r\n${kept.join('\r\n')}\r\nConnection: close\r\n\r\n'));
      return t.join(req.rest);
    }
    _viaGateway.add(t);
    final up = await t.connect(endpoint.host, endpoint.port);
    if (up == null) return t.reply(502, 'Shifter gateway unreachable');
    up.send(ascii.encode(
      '$method $target $version\r\n${kept.join('\r\n')}\r\nProxy-Authorization: ${endpoint._auth}\r\nConnection: close\r\n\r\n',
    ));
    // Send the body on while waiting for the answer (uploads, POST).
    up.send(req.rest);
    t.client.pipeTo(up);
    final res = await up.readHead();
    if (res == null) return t.reply(502, 'Shifter gateway closed the connection');
    if (_status(res.head) == 407) {
      onRejected?.call();
      return t.reply(502, 'Shifter rejected the proxy login');
    }
    t.client.send(ascii.encode('${res.head}\r\n\r\n'));
    t.client.send(res.rest);
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

/// One client connection and, once known, its upstream. Closed as soon as
/// either side fails, or once both sides have finished sending.
class _Tunnel {
  _Tunnel(RawSocket client) {
    this.client = _Peer(client, this);
  }
  late final _Peer client;
  _Peer? upstream;
  void Function()? onClosed;
  bool _closed = false;

  Future<_Peer?> connect(String host, int port) async {
    try {
      final s = await RawSocket.connect(host, port, timeout: _connectTimeout);
      if (_closed) {
        s.close();
        return null;
      }
      s.setOption(SocketOption.tcpNoDelay, true);
      return upstream = _Peer(s, this);
    } catch (_) {
      return null;
    }
  }

  /// Pipe both ways until either side is done.
  void join(Uint8List clientRest) {
    final up = upstream!;
    up.send(clientRest);
    client.pipeTo(up);
    up.pipeTo(client);
  }

  void reply(int code, String reason) {
    final body = utf8.encode('$reason\n');
    client.send(ascii.encode(
      'HTTP/1.1 $code $reason\r\nContent-Type: text/plain\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n',
    ));
    client.send(body);
    client.closeWhenSent();
    upstream?.destroy();
  }

  /// Both sides finished sending and everything was delivered.
  void peerFinished() {
    final up = upstream;
    if (client.finished && (up == null || up.finished)) destroy();
  }

  void destroy() {
    if (_closed) return;
    _closed = true;
    client.destroy();
    upstream?.destroy();
    onClosed?.call();
  }
}

/// A [RawSocket] that can first read an HTTP head, then pump everything it
/// reads into another peer with backpressure.
class _Peer {
  _Peer(this.socket, this.tunnel) {
    socket.writeEventsEnabled = false;
    _sub = socket.listen(_onEvent, onError: (_) => tunnel.destroy(), onDone: tunnel.destroy, cancelOnError: true);
  }
  final RawSocket socket;
  final _Tunnel tunnel;
  late final StreamSubscription<RawSocketEvent> _sub;

  // Head mode: bytes collected until the blank line.
  final _head = BytesBuilder(copy: false);
  Completer<void>? _more;

  /// Where what this peer reads goes, once piping.
  _Peer? _target;

  /// Whoever is waiting for this peer to accept more (paused while it can't).
  _Peer? _source;

  /// Bytes queued to be written into this socket.
  final _out = <Uint8List>[];
  int _outOffset = 0;

  bool _readClosed = false;
  bool _closeWhenSent = false;
  bool _sendShut = false;
  bool _destroyed = false;

  /// This side sent everything it will ever send, and it all reached the other side.
  /// Only once piping: before that, the request handler decides when to close.
  bool get finished => _readClosed && _target != null && _target!._out.isEmpty;

  void _onEvent(RawSocketEvent e) {
    switch (e) {
      case RawSocketEvent.read:
        _onReadable();
      case RawSocketEvent.write:
        _drain();
      case RawSocketEvent.readClosed:
        _readClosed = true;
        _more?.complete();
        _more = null;
        // Half-close: tell the other side nothing more is coming.
        _target?._shutdownWhenSent();
        tunnel.peerFinished();
      case RawSocketEvent.closed:
        tunnel.destroy();
    }
  }

  void _onReadable() {
    final t = _target;
    if (t == null) {
      final d = socket.read();
      if (d == null) return;
      _head.add(d);
      _more?.complete();
      _more = null;
      if (_head.length > _maxHead) socket.readEventsEnabled = false; // readHead gives up
      return;
    }
    if (t._out.isNotEmpty) {
      t._source = this; // resumed by t._drain
      socket.readEventsEnabled = false;
      return;
    }
    final d = socket.read(_chunk);
    if (d != null) t._write(d, from: this);
  }

  /// Queues [data] and writes as much as the OS takes right now.
  void send(Uint8List data) => _write(data);

  void _write(Uint8List data, {_Peer? from}) {
    if (_destroyed || data.isEmpty) return;
    _out.add(data);
    _drain();
    if (_out.isNotEmpty && from != null) {
      // Can't take more: stop reading the source until this drains.
      _source = from;
      from.socket.readEventsEnabled = false;
    }
  }

  void _drain() {
    if (_destroyed) return;
    try {
      while (_out.isNotEmpty) {
        final first = _out.first;
        final n = socket.write(first, _outOffset);
        _outOffset += n;
        if (_outOffset < first.length) {
          socket.writeEventsEnabled = true; // wait for room
          return;
        }
        _out.removeAt(0);
        _outOffset = 0;
      }
    } catch (_) {
      return tunnel.destroy();
    }
    socket.writeEventsEnabled = false;
    final src = _source;
    _source = null;
    if (src != null && !src._destroyed) src.socket.readEventsEnabled = true;
    if (_closeWhenSent) return tunnel.destroy();
    if (_sendShut) _shutdownNow();
    // A finished source may have been waiting for this drain.
    tunnel.peerFinished();
  }

  void _shutdownWhenSent() {
    _sendShut = true;
    if (_out.isEmpty) _shutdownNow();
  }

  void _shutdownNow() {
    try {
      socket.shutdown(SocketDirection.send);
    } catch (_) {}
  }

  /// Close the whole tunnel once what's queued has been written.
  void closeWhenSent() {
    _closeWhenSent = true;
    if (_out.isEmpty) tunnel.destroy();
  }

  /// Bytes up to the blank line, plus whatever came after it.
  Future<({String head, Uint8List rest})?> readHead() async {
    final deadline = DateTime.now().add(_connectTimeout);
    while (true) {
      final bytes = _head.toBytes();
      final end = _indexOfBlankLine(bytes);
      if (end >= 0) {
        _head.clear();
        return (head: latin1.decode(Uint8List.sublistView(bytes, 0, end)), rest: Uint8List.sublistView(bytes, end + 4));
      }
      final left = deadline.difference(DateTime.now());
      if (_readClosed || _destroyed || bytes.length > _maxHead || left <= Duration.zero) return null;
      await (_more = Completer<void>()).future.timeout(left, onTimeout: () {});
    }
  }

  void pipeTo(_Peer t) {
    _target = t;
    final pending = _head.takeBytes();
    if (pending.isNotEmpty) t._write(pending, from: this);
    if (_readClosed) t._shutdownWhenSent();
    if (t._out.isEmpty) {
      socket.readEventsEnabled = true;
    } else {
      t._source = this;
      socket.readEventsEnabled = false;
    }
  }

  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _out.clear();
    _more?.complete();
    _more = null;
    _sub.cancel();
    try {
      socket.close();
    } catch (_) {}
  }
}

int _indexOfBlankLine(Uint8List b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
  }
  return -1;
}
