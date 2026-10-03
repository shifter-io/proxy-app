import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api.dart';
import 'geo_catalog.dart';
import 'models.dart';
import 'store.dart';

const shifterBaseUrl = String.fromEnvironment('SHIFTER_BASE_URL', defaultValue: 'https://shifter.io');

const _day = Duration(days: 1);

/// proxy-config is reused between the plan list, the ISP picker and connect.
const _proxyConfigTtl = Duration(minutes: 1);

/// A plan with no renewal that ends within this window shows as "Expiring soon".
const _expiringWindow = Duration(days: 3);

const _timeout = Duration(seconds: 20);

/// Live backend: the Shifter API (Proxy Extension repo,
/// shifter_docs/shifter-extension-api.md). Port of the extension's
/// src/lib/api/http/index.ts.
///
/// - `/api/v1/user/*` take the key as `Authorization: Bearer` and wrap
///   bodies in `{ error, code, data }`.
/// - Locations come from the bundled catalog. The geo endpoints
///   (`X-Api-Key`, plain arrays, day cache) only name ISP carriers the
///   catalog doesn't know.
/// - Any 401 surfaces as ApiException(unauthorized); the app signs out.
///
/// Uses its own HttpClient, which never goes through the system proxy, so
/// the API stays reachable while connected (shifter.io is bypassed as well).
class HttpShifterApi implements ShifterApi {
  HttpShifterApi({this.baseUrl = shifterBaseUrl, Store? store, HttpClient? client})
      : _store = store, // ignore: prefer_initializing_formals
        _client = client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 12));

  final String baseUrl;
  final Store? _store;
  final HttpClient _client;

  String? _apiKey;
  ({DateTime at, String key, Future<Map<String, dynamic>> value})? _proxyConfigCache;

  @override
  void useSession(Session? session) {
    if (session?.apiKey != _apiKey) _proxyConfigCache = null;
    _apiKey = session?.apiKey;
  }

  @override
  Future<Session> verifyApiKey(String apiKey) async {
    final key = apiKey.trim();
    final me = await _user<Map<String, dynamic>>('/api/v1/user/me', key: key);
    final session = Session(user: _toUser(me), apiKey: key, createdAt: DateTime.now());
    useSession(session);
    return session;
  }

  @override
  Future<User> me() async => _toUser(await _user<Map<String, dynamic>>('/api/v1/user/me'));

  @override
  Future<List<Membership>> memberships() async {
    final (plans, usage, config) = await (
      _user<Object?>('/api/v1/user/memberships'),
      _user<Object?>('/api/v1/user/usage'),
      _proxyConfig(fresh: true),
    ).wait.onError<ParallelWaitError>((e, _) => throw _firstError(e.errors));

    final usageById = {
      for (final u in _list((usage as Map?)?['memberships'])) u['id'] as String: u,
    };
    final liveByHash = {for (final p in _list(config['plans'])) p['hash'] as String: p};

    // The panel returns `[]` instead of `{}` when there are no plans.
    final entries = plans is Map ? plans.cast<String, dynamic>().entries : const <MapEntry<String, dynamic>>[];
    return [
      for (final e in entries)
        ?_toMembership(e.key, e.value as Map<String, dynamic>, liveByHash[e.key], usageById[e.key], baseUrl),
    ];
  }

  // ── Locations: the bundled catalog, not the geo endpoints ──

  @override
  Future<List<GeoCountry>> countries() async => (await GeoCatalog.load()).countries;

  @override
  Future<List<GeoRegion>> regions(String country) async => (await GeoCatalog.load()).regions(country);

  @override
  Future<List<GeoCity>> cities(String country, {String? region}) async =>
      (await GeoCatalog.load()).cities(country, region: region);

  @override
  Future<List<GeoAsn>> asns(String country, {String? region, String? city}) async =>
      (await GeoCatalog.load()).isps(country, region: region, city: city);

  @override
  Future<List<GeoSearchResult>> searchGeo(String query) async => (await GeoCatalog.load()).search(query);

  // ── ISP + gateway ───────────────────────────────────────────────────

  @override
  Future<List<IspIp>> ispIps(String membershipId) async {
    final plan = _list((await _proxyConfig())['plans'])
        .where((p) => p['hash'] == membershipId && p['type'] == 'isp')
        .firstOrNull;
    if (plan == null) return const [];
    final proxies = _list(plan['proxies']);

    // proxy-config has the ASN number only. Names come from the catalog,
    // else from the country's ASN list on the geo API (day cache).
    final catalog = await GeoCatalog.load();
    final names = <int, String>{};
    final missing = <String>{};
    for (final p in proxies) {
      final asn = (p['asn'] as num?)?.toInt();
      if (asn == null || names.containsKey(asn)) continue;
      final name = catalog.asnName(asn);
      if (name != null) {
        names[asn] = name;
      } else {
        missing.add((p['country'] as String).toLowerCase());
      }
    }
    await Future.wait(missing.map((country) async {
      final list = await _geo('asns', {'country': country}).catchError((_) => const <dynamic>[]);
      for (final a in list.whereType<Map<String, dynamic>>()) {
        final asn = (a['asn'] as num?)?.toInt();
        if (asn != null) names.putIfAbsent(asn, () => a['name'] as String? ?? 'AS$asn');
      }
    }));

    return numberIspIps([
      for (final p in proxies)
        IspIp(
          id: p['username'] as String,
          country: (p['country'] as String).toLowerCase(),
          city: p['city'] as String?,
          asn: (p['asn'] as num?)?.toInt(),
          isp: switch ((p['asn'] as num?)?.toInt()) {
            null => 'ISP proxy',
            final asn => names[asn] ?? 'AS$asn',
          },
        ),
    ]);
  }

  @override
  Future<ProxyCredentials> credentials(String membershipId) async {
    final plan = _list((await _proxyConfig(fresh: true))['plans']).where((p) => p['hash'] == membershipId).firstOrNull;
    if (plan == null) throw ApiException('This plan is not active on the gateway yet.', code: ApiErrorCode.validation);
    final protocol = (plan['protocol'] as String?)?.toLowerCase();
    if (protocol != null && protocol != 'http') {
      throw ApiException("This plan uses ${protocol.toUpperCase()}, which the app can't connect to yet.", code: ApiErrorCode.validation);
    }
    final residential = plan['type'] == 'residential';
    return ProxyCredentials(
      type: residential ? ProductType.residential : ProductType.isp,
      host: plan['host'] as String,
      port: (plan['port'] as num).toInt(),
      username: residential ? plan['username'] as String : '',
      password: plan['password'] as String,
      entryPoints: residential ? _list(plan['entry_points']).map(_toEntryPoint).toList() : const [],
      stickySessions: residential && ((plan['targeting'] as Map?)?['sticky_session'] as bool? ?? true),
    );
  }

  // ── Transport ───────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _proxyConfig({bool fresh = false}) {
    final key = _apiKey ?? '';
    final c = _proxyConfigCache;
    if (!fresh && c != null && c.key == key && DateTime.now().difference(c.at) < _proxyConfigTtl) return c.value;
    final value = _user<Map<String, dynamic>?>('/api/v1/user/proxy-config').then((d) => {'plans': d?['plans'] ?? const []});
    final entry = (at: DateTime.now(), key: key, value: value);
    _proxyConfigCache = entry;
    value.catchError((_) {
      if (identical(_proxyConfigCache, entry)) _proxyConfigCache = null;
      return const <String, dynamic>{};
    });
    return value;
  }

  Future<T> _user<T>(String path, {String? key}) async {
    key ??= _apiKey;
    if (key == null) throw ApiException('Not signed in', code: ApiErrorCode.unauthorized);
    final body = await _request(path, {'Authorization': 'Bearer $key'});
    if (body is! Map<String, dynamic>) throw ApiException('Unexpected response from Shifter.');
    final error = body['error'];
    if (error != null) {
      throw ApiException('$error', code: body['code'] == 401 ? ApiErrorCode.unauthorized : ApiErrorCode.server);
    }
    return body['data'] as T;
  }

  Future<List<dynamic>> _geo(String kind, Map<String, String> params) async {
    final key = _apiKey;
    if (key == null) throw ApiException('Not signed in', code: ApiErrorCode.unauthorized);
    final qs = Uri(queryParameters: params).query;
    final cacheKey = 'geo:$kind:$qs';
    final cached = await _store?.readCache(cacheKey);
    if (cached != null && DateTime.now().difference(cached.at) < _day) return cached.data as List<dynamic>;
    try {
      final data = await _request('/api/v1/residential/geo/$kind${qs.isEmpty ? '' : '?$qs'}', {'X-Api-Key': key});
      final list = data is List ? data : const <dynamic>[];
      await _store?.writeCache(cacheKey, list);
      return list;
    } catch (e) {
      // A stale list beats an empty picker when the API is briefly down.
      if (cached != null && !(e is ApiException && e.unauthorized)) return cached.data as List<dynamic>;
      rethrow;
    }
  }

  Future<Object?> _request(String path, Map<String, String> headers) async {
    final HttpClientResponse res;
    final String text;
    try {
      final req = await _client.getUrl(Uri.parse(baseUrl + path)).timeout(_timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      headers.forEach(req.headers.set);
      res = await req.close().timeout(_timeout);
      text = await res.transform(utf8.decoder).join().timeout(_timeout);
    } on TimeoutException {
      throw ApiException("Couldn't reach Shifter. Check your connection and try again.", code: ApiErrorCode.network);
    } on IOException {
      throw ApiException("Couldn't reach Shifter. Check your connection and try again.", code: ApiErrorCode.network);
    }
    if (res.statusCode == 401) throw ApiException('Invalid API key', code: ApiErrorCode.unauthorized);
    if (res.statusCode == 429) {
      throw ApiException('Too many requests. Wait a minute and try again.', code: ApiErrorCode.rateLimited);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException('Shifter returned ${res.statusCode}. Try again later.');
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      throw ApiException('Unexpected response from Shifter.');
    }
  }
}

Object _firstError(List<Object?> errors) {
  final all = errors.whereType<Object>();
  // An expired key matters more than a parallel network blip.
  return all.where((e) => e is ApiException && e.unauthorized).firstOrNull ?? all.first;
}

List<Map<String, dynamic>> _list(Object? v) => v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

// ── Mapping ─────────────────────────────────────────────────────────────

User _toUser(Map<String, dynamic> me) {
  final name = [me['first_name'], me['last_name']].whereType<String>().where((s) => s.isNotEmpty).join(' ').trim();
  return User(
    id: '${me['user_id']}',
    email: me['email'] as String? ?? '',
    name: name.isNotEmpty ? name : me['username'] as String?,
    username: me['username'] as String?,
    walletBalance: (me['wallet_balance'] as num?)?.toDouble(),
    currency: me['currency'] as String? ?? 'USD',
  );
}

EntryPoint _toEntryPoint(Map<String, dynamic> e) =>
    EntryPoint(key: e['key'] as String, host: e['host'] as String, city: e['city'] as String?, region: e['region'] as String? ?? '');

ProductType? _productType(Map<String, dynamic> m, Map<String, dynamic>? live) {
  if (live != null) return live['type'] == 'isp' ? ProductType.isp : ProductType.residential;
  final category = m['category'] as String? ?? '';
  if (m['pool'] != null || RegExp('residential', caseSensitive: false).hasMatch(category)) return ProductType.residential;
  if (RegExp('^isp', caseSensitive: false).hasMatch(category)) return ProductType.isp;
  return null; // other product lines can't be used from the app
}

ResidentialPool? _pool(Object? v) => switch (v) {
      'full' => ResidentialPool.full,
      'country' => ResidentialPool.country,
      'non-geo' => ResidentialPool.nonGeo,
      _ => null,
    };

/// Joins one `/user/memberships` entry with its `/user/usage` row and its
/// `/user/proxy-config` plan (by hash). Null for plans the app can't use or
/// show (other products, and cancelled plans that have ended).
Membership? _toMembership(
  String hash,
  Map<String, dynamic> m,
  Map<String, dynamic>? live,
  Map<String, dynamic>? usage,
  String baseUrl,
) {
  final type = _productType(m, live);
  if (type == null) return null;
  final expiresAt = _date(m['expires_at']) ?? DateTime.now();
  final ended = !expiresAt.isAfter(DateTime.now());
  if (m['canceled_at'] != null && ended) return null;

  final planName = [m['product'], live?['product'], m['name']].whereType<String>().where((s) => s.isNotEmpty).firstOrNull ?? hash;
  final status = _statusOf(m, live != null, ended, expiresAt);
  final renewsAt = _date(m['renews_at']);
  final statusLabel = m['status'] as String?;
  // Panel page: /panel/membership/{hash}. `uri` is an API path.
  final manageUrl = '$baseUrl/panel/membership/$hash';

  if (type == ProductType.isp) {
    final proxies = live?['type'] == 'isp' ? _list(live!['proxies']) : const <Map<String, dynamic>>[];
    return IspMembership(
      id: hash,
      planName: planName,
      status: status,
      expiresAt: expiresAt,
      renewsAt: renewsAt,
      statusLabel: statusLabel,
      manageUrl: manageUrl,
      ipCount: proxies.length,
      countries: {for (final p in proxies) (p['country'] as String).toLowerCase()}.toList(),
    );
  }

  final res = live?['type'] == 'residential' ? live : null;
  final metered = usage?['metered'] == true && usage?['quota_bytes'] != null;
  return ResidentialMembership(
    id: hash,
    planName: planName,
    status: status,
    expiresAt: expiresAt,
    renewsAt: renewsAt,
    statusLabel: statusLabel,
    manageUrl: manageUrl,
    pool: _pool(m['pool']) ?? _pool(res?['pool']) ?? ResidentialPool.full,
    traffic: metered
        ? Traffic(
            totalBytes: (usage!['quota_bytes'] as num).toInt(),
            usedBytes: (usage['used_bytes'] as num?)?.toInt() ?? 0,
            remainingBytes: (usage['remaining_bytes'] as num?)?.toInt(),
            resetsAt: _date(usage['resets_at']),
          )
        : null,
    unmetered: usage?['metered'] == false,
    entryPoints: _list(res?['entry_points']).map(_toEntryPoint).toList(),
    stickySessions: (res?['targeting'] as Map?)?['sticky_session'] as bool? ?? true,
  );
}

/// Usable = listed in proxy-config (live on the gateway) and not past
/// `expires_at`. A cancelled plan keeps working until then, so it reads as
/// "expiring"; unpaid / not-yet-active plans read as "suspended".
MembershipStatus _statusOf(Map<String, dynamic> m, bool live, bool ended, DateTime expiresAt) {
  if (ended) return MembershipStatus.expired;
  if (!live) return MembershipStatus.suspended;
  final endsSoon = m['renews_at'] == null && expiresAt.difference(DateTime.now()) < _expiringWindow;
  if (m['canceled_at'] != null || m['color'] == 'warning' || endsSoon) return MembershipStatus.expiring;
  return MembershipStatus.active;
}
