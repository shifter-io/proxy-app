// Stand-in Shifter for tests, a Dart port of the extension's
// e2e/fake-shifter.mjs (Proxy Extension repo):
//   api      the /api/v1 endpoints the app uses
//   gateway  a login-protected HTTP proxy that logs the username of every
//            request. It ignores the requested host and serves everything
//            from [origin], so tests don't need the internet.
// GET /json through the gateway answers like the IP check, with an exit IP
// that changes with the sid (or on every request for rotating sessions).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const fakeKey = 'kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk';
const fakePassword = 'pw-secret';

String _iso(int days) => DateTime.now().toUtc().add(Duration(days: days)).toIso8601String();

class FakeShifter {
  /// [host]: the address clients use to reach this machine (an Android
  /// emulator sees the host Mac as 10.0.2.2); [bind]: where to listen.
  FakeShifter({this.host = '127.0.0.1', InternetAddress? bind}) : bind = bind ?? InternetAddress.loopbackIPv4;
  final String host;
  final InternetAddress bind;

  late HttpServer api;
  late ServerSocket gateway;
  late HttpServer origin;

  /// {user, target} for every request the gateway handled; user "(407)" when refused.
  final log = <({String user, String target})>[];
  final _tunnels = <Socket>{};

  /// Refuse every login (plan out of traffic / suspended).
  bool rejectAll = false;

  /// Device tests: the host side advances this to let the app go on
  /// (GET /_test/step, no login needed).
  int step = 0;
  int _rotation = 0;

  String get apiUrl => 'http://$host:${api.port}';
  int get gatewayPort => gateway.port;

  Map<String, dynamic> get memberships => {
        'pqqD': {
          'name': 'test #pqqD - Spark', 'status': 'Active', 'color': 'success', 'service': 'backconnect',
          'uri': 'backconnect/pqqD/', 'membership_id': 1, 'product': 'Spark', 'category': 'Residential Proxies',
          'is_recurring': true, 'is_trial': false, 'created_at': _iso(-5), 'expires_at': _iso(25),
          'renews_at': _iso(25), 'trial_ends_at': null, 'canceled_at': null, 'pool': 'full', 'pool_label': 'Full Geo',
        },
        'zqJ4': {
          'name': 'test #zqJ4 - 4 ISP Proxies', 'status': 'Active, Recurring', 'color': 'success', 'service': 'isp',
          'uri': 'isp/zqJ4/', 'membership_id': 2, 'product': '4 ISP Proxies', 'category': 'ISP Proxies',
          'is_recurring': true, 'is_trial': false, 'created_at': _iso(-5), 'expires_at': _iso(10),
          'renews_at': _iso(10), 'trial_ends_at': null, 'canceled_at': null,
        },
        // Cancelled and ended: hidden.
        'old1': {
          'name': 'test #old1 - Pro', 'status': 'Canceled', 'color': 'danger', 'service': 'backconnect',
          'uri': 'backconnect/old1/', 'membership_id': 3, 'product': 'Pro', 'category': 'Residential Proxies',
          'is_recurring': false, 'is_trial': false, 'created_at': _iso(-60), 'expires_at': _iso(-30),
          'renews_at': null, 'trial_ends_at': null, 'canceled_at': _iso(-40), 'pool': 'full',
        },
        // Unpaid: shown, not usable.
        'unpd': {
          'name': 'test #unpd - Starter', 'status': 'Pending Payment', 'color': 'warning', 'service': 'backconnect',
          'uri': 'backconnect/unpd/', 'membership_id': 4, 'product': 'Starter', 'category': 'Residential Proxies',
          'is_recurring': true, 'is_trial': false, 'created_at': _iso(-1), 'expires_at': _iso(29),
          'renews_at': _iso(29), 'trial_ends_at': null, 'canceled_at': null, 'pool': 'country',
        },
        // Another product line: hidden.
        'serp': {
          'name': 'test #serp - SERP', 'status': 'Active', 'color': 'success', 'service': 'serp', 'uri': 'serp/serp/',
          'membership_id': 5, 'product': 'SERP API', 'category': 'Scraping', 'is_recurring': true, 'is_trial': false,
          'created_at': _iso(-5), 'expires_at': _iso(25), 'renews_at': _iso(25), 'trial_ends_at': null, 'canceled_at': null,
        },
      };

  Map<String, dynamic> get usage => {
        'memberships': [
          {
            'id': 'pqqD', 'plan': 'Spark', 'service': 'backconnect', 'status': 'Active', 'metered': true,
            'quota_bytes': 5000000000, 'used_bytes': 1250000000, 'remaining_bytes': 3750000000, 'overage_bytes': 0,
            'used_percent': 25, 'resets_at': _iso(25), 'overage_billed': false, 'overage_rate_per_gb': null,
            'wallet_balance': 10, 'wallet_covers_gb': null,
          },
          {
            'id': 'zqJ4', 'plan': '4 ISP Proxies', 'service': 'isp', 'status': 'Active', 'metered': false,
            'quota_bytes': null, 'used_bytes': null, 'remaining_bytes': null, 'overage_bytes': null, 'used_percent': null,
            'resets_at': null, 'overage_billed': false, 'overage_rate_per_gb': null, 'wallet_balance': 10, 'wallet_covers_gb': null,
          },
        ],
      };

  Map<String, dynamic> get proxyConfig => {
        'plans': [
          {
            'membership_id': 1, 'hash': 'pqqD', 'product': 'Spark', 'status': 'Active', 'protocol': 'http',
            'type': 'residential', 'pool': 'full', 'pool_label': 'Full Geo', 'host': host, 'port': gatewayPort,
            'entry_points': [
              {'key': 'auto', 'host': host, 'city': null, 'region': 'Automatic'},
              {'key': 'fra', 'host': 'fra.localhost', 'city': 'Frankfurt', 'region': 'Europe'},
            ],
            'username': 'customer-test', 'password': fakePassword,
            'targeting': {'country': true, 'region': true, 'city': true, 'asn': true, 'sticky_session': true},
            'username_format': 'customer-{username}[-country-{iso2}]…',
          },
          {
            'membership_id': 2, 'hash': 'zqJ4', 'product': '4 ISP Proxies', 'status': 'Active, Recurring',
            'protocol': 'http', 'type': 'isp', 'host': host, 'port': gatewayPort, 'password': fakePassword,
            'proxies': [
              {'username': 'us-new_york-new_york-as7922-AAAAA', 'country': 'US', 'city': 'New York', 'asn': 7922},
              {'username': 'us-new_york-new_york-as7922-BBBBB', 'country': 'US', 'city': 'New York', 'asn': 7922},
              {'username': 'ro-bucharest-bucharest-as999999-CCCCC', 'country': 'RO', 'city': 'Bucharest', 'asn': 999999},
            ],
          },
        ],
      };

  Future<void> start({int apiPort = 0}) async {
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen(_onOrigin);
    api = await HttpServer.bind(bind, apiPort);
    api.listen(_onApi);
    gateway = await ServerSocket.bind(bind, 0);
    gateway.listen(_onGateway);
  }

  Future<void> stop() async {
    dropTunnels();
    await Future.wait([api.close(force: true), origin.close(force: true), gateway.close()]);
  }

  /// Close every open tunnel (like a network change).
  void dropTunnels() {
    for (final s in _tunnels) {
      s.destroy();
    }
    _tunnels.clear();
  }

  Future<void> _onApi(HttpRequest req) async {
    void send(int code, Object body) {
      req.response
        ..statusCode = code
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body))
        ..close();
    }

    if (req.uri.path == '/_test/step') return send(200, {'step': step});
    final authed = req.headers.value('authorization') == 'Bearer $fakeKey' || req.headers.value('x-api-key') == fakeKey;
    if (!authed) return send(401, {'error': 'Unauthorized', 'code': 401});
    void ok(Object data) => send(200, {'error': null, 'code': 200, 'data': data});
    switch (req.uri.path) {
      case '/api/v1/user/me':
        return ok({
          'user_id': 1, 'username': 'tester', 'first_name': 'Test', 'last_name': 'User', 'email': 't@example.com',
          'wallet_balance': 10, 'currency': 'USD', 'created_at': _iso(-100),
        });
      case '/api/v1/user/memberships':
        return ok(memberships);
      case '/api/v1/user/usage':
        return ok(usage);
      case '/api/v1/user/proxy-config':
        return ok(proxyConfig);
      case '/api/v1/residential/geo/asns':
        return send(200, [
          {'asn': 999999, 'name': 'Test Carrier RO'},
        ]);
      default:
        return send(404, {'error': 'not found', 'code': 404});
    }
  }

  void _onOrigin(HttpRequest req) async {
    // GET /bytes/<n>: n bytes, for transfer tests.
    final size = req.uri.path.startsWith('/bytes/') ? int.tryParse(req.uri.pathSegments.last) : null;
    if (size != null) {
      req.response.contentLength = size;
      final chunk = Uint8List(64 * 1024);
      for (var left = size; left > 0; left -= chunk.length) {
        req.response.add(left >= chunk.length ? chunk : Uint8List(left));
        await req.response.flush();
      }
      return req.response.close();
    }
    final body = await utf8.decoder.bind(req).join();
    req.response
      ..headers.contentType = ContentType.text
      ..write('origin ${req.method} ${req.uri.path} $body')
      ..close();
  }

  String? _userOf(List<String> headers) {
    final h = headers.where((l) => l.toLowerCase().startsWith('proxy-authorization:')).firstOrNull;
    if (h == null) return null;
    final v = h.substring(h.indexOf(':') + 1).trim();
    if (!v.startsWith('Basic ')) return null;
    final decoded = utf8.decode(base64.decode(v.substring(6)));
    final i = decoded.indexOf(':');
    return decoded.substring(i + 1) == fakePassword && !rejectAll ? decoded.substring(0, i) : null;
  }

  /// The exit the IP check reports for this login: stable per sid, new per request without one.
  String exitIpFor(String user) {
    final sid = RegExp(r'-sid-([a-z0-9]+)').firstMatch(user)?[1];
    final seed = sid != null ? sid.hashCode : ++_rotation + user.hashCode;
    return '203.0.113.${(seed % 254) + 1}';
  }

  Future<void> _onGateway(Socket sock) async {
    _tunnels.add(sock);
    sock.done.whenComplete(() => _tunnels.remove(sock)).ignore();
    final buf = BytesBuilder();
    late StreamSubscription<List<int>> sub;
    final headDone = Completer<(String, List<int>)>();
    sub = sock.listen((data) {
      if (headDone.isCompleted) return;
      buf.add(data);
      final bytes = buf.toBytes();
      final s = latin1.decode(bytes);
      final end = s.indexOf('\r\n\r\n');
      if (end >= 0) {
        sub.pause();
        headDone.complete((s.substring(0, end), bytes.sublist(end + 4)));
      }
    }, onError: (_) {}, onDone: () {
      if (!headDone.isCompleted) headDone.completeError('closed');
    });
    final String head;
    final List<int> rest;
    try {
      (head, rest) = await headDone.future;
    } catch (_) {
      return sock.destroy();
    }
    final lines = head.split('\r\n');
    final [method, target, _] = lines.first.split(' ');
    final user = _userOf(lines.skip(1).toList());
    if (user == null) {
      log.add((user: '(407)', target: target));
      sock.write('HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="shifter"\r\nContent-Length: 0\r\n\r\n');
      await sock.flush();
      return sock.destroy();
    }
    log.add((user: user, target: method == 'CONNECT' ? target : 'HTTP $target'));

    final uri = method == 'CONNECT' ? null : Uri.parse(target);
    if (uri != null && uri.path == '/json') {
      final country = RegExp(r'-country-([a-z]{2})').firstMatch(user)?[1] ?? user.split('-').first;
      final body = jsonEncode({'ip': exitIpFor(user), 'country': country.toUpperCase()});
      sock.write('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body');
      await sock.flush();
      return sock.destroy();
    }

    final up = await Socket.connect(InternetAddress.loopbackIPv4, origin.port);
    if (method == 'CONNECT') {
      sock.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    } else {
      final kept = lines.skip(1).where((l) => !l.toLowerCase().startsWith('proxy-'));
      up.write('$method ${uri!.path.isEmpty ? '/' : uri.path} HTTP/1.1\r\n${kept.join('\r\n')}\r\n\r\n');
    }
    if (rest.isNotEmpty) up.add(rest);
    sub.onData(up.add);
    sub.onDone(() => up.close().ignore());
    sub.resume();
    up.listen(sock.add, onDone: () => sock.close().ignore(), onError: (_) => sock.destroy());
  }
}
