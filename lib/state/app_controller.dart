import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../data/format.dart';
import '../data/geo_catalog.dart';
import '../data/mock_api.dart';
import '../data/models.dart';

enum AuthPhase { booting, signedOut, signedIn }

/// App state for one running app instance. Mirrors the extension's
/// AppState (src/ui/state/AppState.tsx) minus routing, which lives in the
/// responsive shell. The connect/disconnect calls are mocked: no traffic is
/// routed in the UI phase.
class AppController extends ChangeNotifier {
  AppController({ShifterApi? api, this.demoKey, this.demoConnected = false})
      : api = api ?? MockShifterApi() {
    _boot();
  }

  final ShifterApi api;

  /// Preview only: sign in with this key on start (skips the login screen).
  final String? demoKey;

  /// Preview only: connect right after the demo sign-in.
  final bool demoConnected;

  AuthPhase phase = AuthPhase.booting;
  Session? session;
  List<Membership>? memberships;
  String? membershipsError;
  String? activeId;
  final Map<String, Target> _targets = {};
  List<ResidentialTarget> recentTargets = [];
  ProxySettings settings = const ProxySettings();
  ProxyConnection connection = const ProxyConnection.disconnected();

  Timer? _connectTimer;
  final _rng = Random();
  bool _disposed = false;

  Future<void> _boot() async {
    // Warm the location catalog so the picker opens instantly.
    unawaited(GeoCatalog.load());
    final key = demoKey;
    if (key != null) {
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
        await connect(instant: true);
      }
      return;
    }
    await Future.delayed(const Duration(milliseconds: 900));
    phase = AuthPhase.signedOut;
    _notify();
  }

  // ── Auth ──────────────────────────────────────────────────────────────

  Future<void> signIn(Session s) async {
    session = s;
    phase = AuthPhase.signedIn;
    _notify();
    final list = await reloadMemberships();
    final usable = list.where((m) => m.usable).toList();
    activeId = usable.length == 1 ? usable.first.id : (usable.any((m) => m.id == activeId) ? activeId : null);
    _notify();
  }

  Future<void> signOut() async {
    await disconnect();
    session = null;
    memberships = null;
    activeId = null;
    phase = AuthPhase.signedOut;
    _notify();
  }

  Future<List<Membership>> reloadMemberships() async {
    membershipsError = null;
    _notify();
    try {
      final list = await api.memberships();
      memberships = list;
      _notify();
      return list;
    } catch (_) {
      membershipsError = 'Could not load your memberships.';
      _notify();
      return const [];
    }
  }

  // ── Memberships ───────────────────────────────────────────────────────

  Membership? get activeMembership => memberships?.where((m) => m.id == activeId).firstOrNull;

  List<Membership> get usableMemberships => memberships?.where((m) => m.usable).toList() ?? const [];

  Future<void> selectMembership(String id) async {
    if (connection.status != ConnectionStatus.disconnected && connection.membershipId != id) {
      await disconnect();
    }
    activeId = id;
    _notify();
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
    _targets[membershipId] = target;
    if (target is ResidentialTarget && target.country != null) {
      recentTargets = [target, ...recentTargets.where((t) => !sameTarget(t, target))].take(5).toList();
    }
    _notify();
    // Switching location while connected re-connects to the new exit.
    if (connection.status == ConnectionStatus.connected && connection.membershipId == membershipId) {
      await connect();
    }
  }

  // ── Settings ──────────────────────────────────────────────────────────

  void updateSettings(ProxySettings next) {
    settings = next;
    _notify();
  }

  // ── Connection (mocked) ───────────────────────────────────────────────

  bool get isConnected => connection.status == ConnectionStatus.connected;
  bool get isConnecting => connection.status == ConnectionStatus.connecting;

  Future<void> connect({bool instant = false}) async {
    final m = activeMembership;
    if (m == null) return;
    final target = currentTarget(m);
    if (target == null) return;
    _connectTimer?.cancel();
    connection = ProxyConnection.connecting(m.id, target);
    _notify();
    final done = Completer<void>();
    _connectTimer = Timer(Duration(milliseconds: instant ? 0 : 1500), () {
      connection = ProxyConnection.connected(m.id, target, DateTime.now(), _exitIpFor(target));
      _notify();
      done.complete();
    });
    return done.future;
  }

  /// A fresh session id pins a new exit IP (residential only).
  Future<void> newIp() async {
    if (!isConnected) return;
    await connect();
  }

  Future<void> disconnect() async {
    _connectTimer?.cancel();
    if (connection.status == ConnectionStatus.disconnected) return;
    connection = const ProxyConnection.disconnected();
    _notify();
  }

  Future<void> toggleConnection() async {
    if (isConnected || isConnecting) return disconnect();
    return connect();
  }

  String _exitIpFor(Target t) {
    if (t is IspTarget) return t.ip.ip;
    int o() => _rng.nextInt(254) + 1;
    return '203.0.113.${o()}';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connectTimer?.cancel();
    super.dispose();
  }
}

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
