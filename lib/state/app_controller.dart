import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../data/api.dart';
import '../data/format.dart';
import '../data/geo_catalog.dart';
import '../data/mock_api.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../proxy/proxy_engine.dart';
import '../proxy/system_proxy.dart';

enum AuthPhase { booting, signedOut, signedIn }

const _rejectedMessage = 'Shifter rejected the proxy login. Check your plan is active and has traffic left.';

/// Residential exits can change under the same session (the peer goes away,
/// a rotating session gets a new IP per request), so while connected the
/// exit is re-checked and the shown IP / flag follow it.
const _exitCheckEvery = Duration(seconds: 15);

/// App state for one running app instance: the extension's AppState
/// (src/ui/state/AppState.tsx) plus its background worker
/// (src/entrypoints/background.ts), minus routing, which lives in the
/// responsive shell.
class AppController extends ChangeNotifier {
  /// Defaults to the in-memory mock backend (preview studio, tests); the
  /// real app passes [HttpShifterApi], [PersistentStore] and [LocalProxyEngine].
  AppController({ShifterApi? api, Store? store, ProxyEngine? engine, this.demoKey, this.demoConnected = false})
      : api = api ?? MockShifterApi(),
        store = store ?? MemoryStore(),
        engine = engine ?? MockProxyEngine(delay: demoConnected ? Duration.zero : const Duration(milliseconds: 1100)) {
    _rejectedSub = this.engine.rejected.listen((_) => _onRejected());
    _boot();
  }

  final ShifterApi api;
  final Store store;
  final ProxyEngine engine;

  /// Preview only: sign in with this key on start (skips the login screen).
  final String? demoKey;

  /// Preview only: connect right after the demo sign-in.
  final bool demoConnected;

  AuthPhase phase = AuthPhase.booting;
  Session? session;
  List<Membership>? memberships;
  String? membershipsError;
  String? activeId;
  Map<String, Target> _targets = {};
  List<ResidentialTarget> recentTargets = [];
  ProxySettings settings = const ProxySettings();
  ProxyConnection connection = const ProxyConnection.disconnected();

  /// Login currently applied; its sid is kept when settings re-apply.
  GatewayEndpoint? _endpoint;

  /// Bumped by every connect / disconnect so a slow, superseded attempt
  /// doesn't overwrite the newer state.
  int _generation = 0;
  bool _loginRejected = false;
  Future<void> _queue = Future.value();
  Timer? _exitTimer;
  bool _checking = false;
  StreamSubscription<void>? _rejectedSub;
  bool _disposed = false;

  Future<void> _boot() async {
    // Warm the location catalog so the picker opens instantly.
    unawaited(GeoCatalog.load());
    final key = demoKey;
    if (key != null) return _bootDemo(key);

    // A crash or force-quit while connected must not leave the OS pointing
    // at a proxy that is gone.
    final started = DateTime.now();
    await engine.recover();
    final (stored, saved, active, targets, recent) = await (
      store.readSession(),
      store.readSettings(),
      store.readActiveMembership(),
      store.readTargets(),
      store.readRecentTargets(),
    ).wait;
    settings = saved;
    activeId = active;
    _targets = targets;
    recentTargets = recent;

    // Let the splash breathe instead of flashing.
    final wait = const Duration(milliseconds: 500) - DateTime.now().difference(started);
    if (wait > Duration.zero) await Future<void>.delayed(wait);

    if (stored == null) {
      phase = AuthPhase.signedOut;
      return _notify();
    }
    api.useSession(stored);
    session = stored;
    phase = AuthPhase.signedIn;
    _notify();
    // Refresh name and wallet balance once per launch.
    unawaited(api.me().then((user) async {
      if (session?.apiKey != stored.apiKey) return;
      session = stored.copyWith(user: user);
      await store.writeSession(session);
      _notify();
    }, onError: (_) {}));
    await _routeAfterAuth(activeId);
    if (settings.autoConnect && activeMembership != null && phase == AuthPhase.signedIn) await connect();
  }

  Future<void> _bootDemo(String key) async {
    final s = await api.verifyApiKey(key);
    await signIn(s);
    final m = activeMembership;
    if (demoConnected && m != null) {
      if (m is IspMembership) {
        final ips = await api.ispIps(m.id);
        if (ips.isNotEmpty) _targets[m.id] = IspTarget(ips.first);
      } else {
        _targets[m.id] = const ResidentialTarget(
          country: GeoCountry('us', 'United States'),
          region: GeoRegion('new_york', 'New York'),
          city: GeoCity('new_york', 'New York', regionSlug: 'new_york'),
        );
      }
      await connect();
    }
  }

  // ── Auth ──────────────────────────────────────────────────────────────

  Future<void> signIn(Session s) async {
    api.useSession(s);
    session = s;
    phase = AuthPhase.signedIn;
    await store.writeSession(s);
    _notify();
    await _routeAfterAuth(null);
  }

  /// Picks the plan to show: the remembered one, else the only usable one.
  Future<void> _routeAfterAuth(String? preferredId) async {
    final list = await reloadMemberships();
    if (phase != AuthPhase.signedIn) return;
    final usable = list.where((m) => m.usable).toList();
    final next = usable.any((m) => m.id == preferredId)
        ? preferredId
        : usable.length == 1
            ? usable.first.id
            : null;
    await _setActive(next);
  }

  Future<void> signOut() async {
    await disconnect();
    await _clearSession();
  }

  /// The key was revoked or regenerated: back to sign-in.
  Future<void> _expireSession() async {
    await disconnect();
    await _clearSession();
  }

  Future<void> _clearSession() async {
    api.useSession(null);
    session = null;
    memberships = null;
    membershipsError = null;
    phase = AuthPhase.signedOut;
    await Future.wait([store.writeSession(null), _setActive(null)]);
    _notify();
  }

  Future<List<Membership>> reloadMemberships() async {
    membershipsError = null;
    _notify();
    try {
      final list = await api.memberships();
      if (phase != AuthPhase.signedIn) return const [];
      memberships = list;
      _notify();
      return list;
    } on ApiException catch (e) {
      if (e.unauthorized) {
        await _expireSession();
        return const [];
      }
      membershipsError = e.code == ApiErrorCode.network || e.code == ApiErrorCode.rateLimited
          ? e.message
          : 'Could not load your memberships.';
      _notify();
      return const [];
    } catch (_) {
      membershipsError = 'Could not load your memberships.';
      _notify();
      return const [];
    }
  }

  // ── Memberships ───────────────────────────────────────────────────────

  Membership? get activeMembership => memberships?.where((m) => m.id == activeId).firstOrNull;

  List<Membership> get usableMemberships => memberships?.where((m) => m.usable).toList() ?? const [];

  Future<void> _setActive(String? id) async {
    activeId = id;
    _notify();
    await store.writeActiveMembership(id);
  }

  Future<void> selectMembership(String id) async {
    if (connection.status != ConnectionStatus.disconnected && connection.membershipId != id) {
      await disconnect();
    }
    await _setActive(id);
  }

  // ── Targets ───────────────────────────────────────────────────────────

  Target? _fit(String membershipId, Target t) {
    final m = memberships?.where((x) => x.id == membershipId).firstOrNull;
    if (m is ResidentialMembership && t is ResidentialTarget) return clampTarget(t, m.pool);
    return t;
  }

  Target? targetFor(String membershipId) {
    final t = _targets[membershipId];
    return t == null ? null : _fit(membershipId, t);
  }

  /// The target Connect will use: the picked one or the plan's default.
  Target? currentTarget(Membership m) => targetFor(m.id) ?? defaultTarget(m);

  Future<void> setTarget(String membershipId, Target picked) async {
    final target = _fit(membershipId, picked)!;
    _targets = {..._targets, membershipId: target};
    if (target is ResidentialTarget && target.country != null) {
      recentTargets = [target, ...recentTargets.where((t) => !sameTarget(t, target))].take(5).toList();
    }
    _notify();
    await Future.wait([store.writeTargets(_targets), store.writeRecentTargets(recentTargets)]);
    // Switching location while connected re-connects to the new exit.
    if ((isConnected || isConnecting) && connection.membershipId == membershipId) {
      await _run(membershipId, target);
    }
  }

  // ── Settings ──────────────────────────────────────────────────────────

  /// Session, TTL, strict, entry point and bypass list apply live, on the same sticky session.
  Future<void> updateSettings(ProxySettings next) async {
    settings = next;
    _notify();
    await store.writeSettings(next);
    final c = connection;
    if (c.status == ConnectionStatus.connected) await _run(c.membershipId!, c.target!, keepSid: true);
  }

  // ── Connection ────────────────────────────────────────────────────────

  bool get isConnected => connection.status == ConnectionStatus.connected;
  bool get isConnecting => connection.status == ConnectionStatus.connecting;

  /// False on devices that can't route other apps yet (phones, tablets).
  bool get canConnect => engine.supported;

  Future<void> connect() async {
    final m = activeMembership;
    if (m == null) return;
    final target = currentTarget(m);
    if (target == null) return;
    await _run(m.id, target);
  }

  /// A fresh session id pins a new exit IP (residential only).
  Future<void> newIp() async {
    final c = connection;
    if (c.status != ConnectionStatus.connected) return;
    await _run(c.membershipId!, c.target!);
  }

  Future<void> disconnect() {
    final gen = ++_generation;
    _watchExit(false);
    if (connection.status != ConnectionStatus.disconnected) {
      connection = const ProxyConnection.disconnected();
      _notify();
    }
    return _serial(() async {
      if (gen != _generation) return;
      _endpoint = null;
      await engine.clear().catchError((_) {});
    });
  }

  Future<void> toggleConnection() async {
    if (isConnected || isConnecting) return disconnect();
    return connect();
  }

  /// App is quitting: put the OS proxy back before the process ends.
  Future<void> shutdown() async {
    await disconnect();
    await _queue;
  }

  /// Serializes connect / disconnect so quick taps can't interleave.
  Future<void> _serial(Future<void> Function() task) {
    final next = _queue.then((_) => task(), onError: (_) => task());
    _queue = next.catchError((_) {});
    return next;
  }

  /// Connects (or re-connects) to [target]. A fresh sticky session id means
  /// a fresh exit IP; [keepSid] re-applies the same session.
  Future<void> _run(String membershipId, Target target, {bool keepSid = false}) {
    final gen = ++_generation;
    _watchExit(false);
    connection = ProxyConnection.connecting(membershipId, target);
    _notify();
    return _serial(() async {
      if (gen != _generation) return;
      try {
        final credentials = await api.credentials(membershipId);
        if (gen != _generation) return;
        final previousSid = _endpoint?.sid;
        final sid = keepSid && previousSid != null ? previousSid : newSid();
        final endpoint = toEndpoint(credentials, target, settings, sid);
        _loginRejected = false;
        await engine.apply(endpoint);
        _endpoint = endpoint;
        final exit = await engine.checkExit().then<ExitInfo?>((e) => e, onError: (_) => null);
        if (gen != _generation) return;
        if (exit == null) {
          throw _ConnectFailure(_loginRejected
              ? _rejectedMessage
              : target is ResidentialTarget && target.country != null
                  ? 'No IP is available for this location right now. Try a wider area.'
                  : 'The Shifter gateway did not respond. Check your plan has traffic left.');
        }
        connection = ProxyConnection.connected(membershipId, target, DateTime.now(), exit.ip, exitCountry: exit.country);
        _notify();
        _watchExit(true);
      } catch (e) {
        // A failed switch must not leave a half-applied proxy behind.
        _endpoint = null;
        await engine.clear().catchError((_) {});
        if (e is ApiException && e.unauthorized) {
          await _clearSession();
        }
        if (gen != _generation) return;
        connection = ProxyConnection.error(switch (e) {
          _ConnectFailure(:final message) => message,
          ApiException(:final message) => message,
          SystemProxyException(:final message) => message,
          _ => 'Could not connect. Try again.',
        });
        _notify();
      }
    });
  }

  void _onRejected() {
    _loginRejected = true;
    if (!isConnected) return;
    final gen = ++_generation;
    _watchExit(false);
    connection = const ProxyConnection.error(_rejectedMessage);
    _notify();
    unawaited(_serial(() async {
      if (gen != _generation) return;
      _endpoint = null;
      await engine.clear().catchError((_) {});
    }));
  }

  void _watchExit(bool on) {
    if (on) {
      _exitTimer ??= Timer.periodic(_exitCheckEvery, (_) => recheckExit());
    } else {
      _exitTimer?.cancel();
      _exitTimer = null;
    }
  }

  /// Re-runs the exit-IP check; a failed check keeps the last IP (one slow
  /// response isn't a dead connection).
  Future<void> recheckExit() async {
    if (_checking || !isConnected) return;
    _checking = true;
    try {
      final before = connection;
      final exit = await engine.checkExit().then<ExitInfo?>((e) => e, onError: (_) => null);
      if (exit == null || _disposed) return;
      final now = connection;
      // Only if nothing changed meanwhile (a reconnect or disconnect wins).
      if (now.status != ConnectionStatus.connected || now.since != before.since) return;
      if (now.exitIp == exit.ip && now.exitCountry == exit.country) return;
      connection = now.withExit(exit.ip, exit.country);
      _notify();
    } finally {
      _checking = false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _exitTimer?.cancel();
    _rejectedSub?.cancel();
    unawaited(engine.clear().catchError((_) {}));
    super.dispose();
  }
}

class _ConnectFailure implements Exception {
  _ConnectFailure(this.message);
  final String message;
}

/// The gateway login for [target] (background.ts `toEndpoint`).
GatewayEndpoint toEndpoint(ProxyCredentials c, Target target, ProxySettings settings, String sid) {
  switch (target) {
    case IspTarget(:final ip):
      // Each ISP IP has its own username on the plan's host.
      return GatewayEndpoint(host: c.host, port: c.port, username: ip.id, password: c.password, bypassList: settings.bypassList);
    case ResidentialTarget():
      final entry = settings.entryPoint == null ? null : c.entryPoints.where((e) => e.key == settings.entryPoint).firstOrNull;
      final sticky = settings.sessionMode == SessionMode.sticky && c.stickySessions;
      return GatewayEndpoint(
        host: entry?.host ?? c.host,
        port: c.port,
        username: buildResidentialUsername(
          c.username,
          target,
          settings.copyWith(sessionMode: sticky ? SessionMode.sticky : SessionMode.rotating),
          sid: sid,
        ),
        password: c.password,
        bypassList: settings.bypassList,
        sid: sticky ? sid : null,
      );
  }
}

final _rng = Random.secure();
const _alnum = 'abcdefghijklmnopqrstuvwxyz0123456789';

/// Fresh opaque session id (letters and digits only); a new one pins a new exit IP.
String newSid() => List.generate(12, (_) => _alnum[_rng.nextInt(_alnum.length)]).join();

/// Provides the [AppController] to the widget tree and rebuilds dependents
/// whenever it notifies.
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({super.key, required AppController controller, required super.child})
      : super(notifier: controller);

  static AppController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Read without subscribing (for callbacks).
  static AppController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
