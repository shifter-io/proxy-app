import 'dart:async';
import 'dart:isolate';

import 'local_proxy.dart';

/// Runs [LocalProxy] on its own isolate (its own thread), so traffic never
/// competes with drawing the UI, and UI work never delays traffic.
class ProxyIsolate {
  ProxyIsolate({this.onRejected});

  /// Called when the gateway refuses the login.
  void Function()? onRejected;

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _events;
  int? _port;
  final _replies = <int, Completer<Object?>>{};
  var _nextId = 0;

  int? get port => _port;

  Future<int> start() async {
    if (_port case final p?) return p;
    final events = ReceivePort();
    _events = events;
    final ready = Completer<SendPort>();
    events.listen((msg) {
      switch (msg) {
        case SendPort commands:
          ready.complete(commands);
        case ('rejected',):
          onRejected?.call();
        case (int id, Object? result):
          _replies.remove(id)?.complete(result);
      }
    });
    _isolate = await Isolate.spawn(_main, events.sendPort, debugName: 'shifter-proxy');
    _commands = await ready.future;
    return _port = (await _call(('start',)))! as int;
  }

  Future<void> setEndpoint(GatewayEndpoint? e) => _call((
        'endpoint',
        e == null ? null : [e.host, e.port, e.username, e.password, e.bypassList, e.sid],
      ));

  Future<void> stop() async {
    if (_isolate == null) return;
    await _call(('stop',)).timeout(const Duration(seconds: 2), onTimeout: () => null);
    _isolate?.kill(priority: Isolate.immediate);
    _events?.close();
    _isolate = null;
    _commands = null;
    _events = null;
    _port = null;
    for (final c in _replies.values) {
      c.complete(null);
    }
    _replies.clear();
  }

  Future<Object?> _call(Record command) {
    final commands = _commands;
    if (commands == null) return Future.value();
    final id = _nextId++;
    final reply = _replies[id] = Completer<Object?>();
    commands.send((id, command));
    return reply.future;
  }

  static void _main(SendPort events) {
    final proxy = LocalProxy(onRejected: () => events.send(('rejected',)));
    final commands = ReceivePort();
    events.send(commands.sendPort);
    commands.listen((msg) async {
      final (int id, Record command) = msg as (int, Record);
      Object? result;
      switch (command) {
        case ('start',):
          result = await proxy.start();
        case ('endpoint', null):
          proxy.setEndpoint(null);
        case ('endpoint', [String host, int port, String user, String pass, List<String> bypass, String? sid]):
          proxy.setEndpoint(GatewayEndpoint(host: host, port: port, username: user, password: pass, bypassList: bypass, sid: sid));
        case ('stop',):
          await proxy.stop();
      }
      events.send((id, result));
    });
  }
}
