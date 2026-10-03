// Benchmark stand-ins, one process: an origin that serves N bytes fast, and a
// login-checking HTTP proxy gateway that sends every request to the origin
// (whatever host was asked), like the Shifter gateway would to a site.
//   dart compile exe tool/bench/servers.dart -o /tmp/bench_servers
//   /tmp/bench_servers   -> prints "origin <port> gateway <port>"
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const password = 'bench';
final chunk = Uint8List(256 * 1024);

// Bench infrastructure only: a client resetting mid-transfer must not stop it.
Future<void> main() => runZonedGuarded(_main, (_, _) {})!;

Future<void> _main() async {
  final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0, backlog: 1024);
  origin.listen(_origin);
  final gateway = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0, backlog: 1024);
  gateway.listen((s) => _gateway(s, origin.port));
  stdout.writeln('origin ${origin.port} gateway ${gateway.port}');
}

/// Reads one HTTP head; returns it and the bytes after it, leaving the
/// subscription paused so the caller can take over.
Future<(String, Uint8List, StreamSubscription<Uint8List>)?> _head(Socket s) {
  final done = Completer<(String, Uint8List, StreamSubscription<Uint8List>)?>();
  final buf = BytesBuilder();
  late StreamSubscription<Uint8List> sub;
  sub = s.listen((d) {
    buf.add(d);
    final b = buf.toBytes();
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        sub.pause();
        done.complete((latin1.decode(b.sublist(0, i)), Uint8List.sublistView(b, i + 4), sub));
        return;
      }
    }
  }, onError: (_) {}, onDone: () {
    if (!done.isCompleted) done.complete(null);
  });
  return done.future;
}

/// GET `/bytes/N` -> N bytes; anything else -> "ok". Keep-alive.
Future<void> _origin(Socket s) async {
  s.setOption(SocketOption.tcpNoDelay, true);
  final buf = BytesBuilder();
  var busy = false;
  final pending = <String>[];
  Future<void> serve() async {
    if (busy) return;
    busy = true;
    while (pending.isNotEmpty) {
      final head = pending.removeAt(0);
      final path = head.split(' ').elementAtOrNull(1) ?? '/';
      final n = path.startsWith('/bytes/') ? int.parse(path.substring(7)) : 2;
      final lower = head.toLowerCase();
      final close = lower.contains('connection: close') ||
          (lower.split('\r\n').first.endsWith('http/1.0') && !lower.contains('connection: keep-alive'));
      s.add(ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: $n\r\nContent-Type: application/octet-stream\r\n${close ? 'Connection: close\r\n' : ''}\r\n'));
      if (n == 2) {
        s.add(ascii.encode('ok'));
      } else {
        var left = n;
        while (left > 0) {
          final k = left < chunk.length ? left : chunk.length;
          s.add(Uint8List.sublistView(chunk, 0, k));
          left -= k;
          await s.flush();
        }
      }
      if (close) {
        await s.flush();
        await s.close();
        busy = false;
        return;
      }
    }
    busy = false;
  }

  s.listen((d) {
    buf.add(d);
    var b = buf.toBytes();
    while (true) {
      var end = -1;
      for (var i = 0; i + 3 < b.length; i++) {
        if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
          end = i;
          break;
        }
      }
      if (end < 0) break;
      pending.add(latin1.decode(b.sublist(0, end)));
      b = b.sublist(end + 4);
    }
    buf
      ..clear()
      ..add(b);
    serve();
  }, onError: (_) => s.destroy(), onDone: () => s.destroy());
}

void _pipe(StreamSubscription<Uint8List> from, Socket to, Socket fromSocket) {
  from.onData((d) {
    to.add(d);
    from.pause();
    to.flush().then((_) => from.resume(), onError: (_) => fromSocket.destroy());
  });
  from.onDone(() => to.close().ignore());
  from.onError((_) => to.destroy());
  from.resume();
}

Future<void> _gateway(Socket s, int originPort) async {
  s.setOption(SocketOption.tcpNoDelay, true);
  final h = await _head(s);
  if (h == null) return s.destroy();
  final (head, rest, sub) = h;
  final lines = head.split('\r\n');
  final auth = lines.where((l) => l.toLowerCase().startsWith('proxy-authorization: basic ')).firstOrNull;
  final ok = auth != null && utf8.decode(base64.decode(auth.substring(27).trim())).endsWith(':$password');
  if (!ok) {
    s.add(ascii.encode('HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n'));
    await s.flush();
    return s.destroy();
  }
  final up = await Socket.connect(InternetAddress.loopbackIPv4, originPort);
  up.setOption(SocketOption.tcpNoDelay, true);
  final [method, target, version] = lines.first.split(' ');
  if (method == 'CONNECT') {
    s.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
  } else {
    final uri = Uri.parse(target);
    final kept = lines.skip(1).where((l) => !l.toLowerCase().startsWith('proxy-'));
    up.add(ascii.encode('$method ${uri.path} $version\r\n${kept.join('\r\n')}\r\n\r\n'));
  }
  if (rest.isNotEmpty) up.add(rest);
  _pipe(sub, up, s);
  final upSub = up.listen(null);
  upSub.pause();
  _pipe(upSub, s, up);
}
