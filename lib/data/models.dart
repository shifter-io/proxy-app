/// Domain models shared by the UI, the mock API and (later) the HTTP API.
/// Ported from the proxy extension (src/lib/types.ts); shapes follow the
/// Shifter Panel where one exists.
library;

class User {
  const User({required this.id, required this.email, this.name, this.username, this.walletBalance, this.currency = 'USD'});
  final String id;
  final String email;

  /// "First Last", or the username when the panel has no name.
  final String? name;
  final String? username;
  final double? walletBalance;
  final String currency;

  Map<String, dynamic> toJson() =>
      {'id': id, 'email': email, 'name': name, 'username': username, 'walletBalance': walletBalance, 'currency': currency};

  static User fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as String,
        email: j['email'] as String,
        name: j['name'] as String?,
        username: j['username'] as String?,
        walletBalance: (j['walletBalance'] as num?)?.toDouble(),
        currency: j['currency'] as String? ?? 'USD',
      );
}

class Session {
  const Session({required this.user, required this.apiKey, required this.createdAt});
  final User user;

  /// The user's panel API key (users.api_token). Sent on every API call.
  final String apiKey;
  final DateTime createdAt;

  Session copyWith({User? user}) => Session(user: user ?? this.user, apiKey: apiKey, createdAt: createdAt);
}

// ── Memberships ─────────────────────────────────────────────────────────

enum ProductType { residential, isp }

/// Residential pool, see ResidentialPools in the panel.
enum ResidentialPool { full, country, nonGeo }

enum MembershipStatus { active, expiring, expired, suspended }

sealed class Membership {
  const Membership({
    required this.id,
    required this.planName,
    required this.status,
    required this.expiresAt,
    this.renewsAt,
    this.statusLabel,
    this.manageUrl,
  });

  /// The plan's short id (hash) in the panel, e.g. "pqqD".
  final String id;

  /// Plan title exactly as the API returns it ("Pro", "25 ISP Proxies").
  final String planName;
  final MembershipStatus status;

  /// The date the plan is paid until.
  final DateTime expiresAt;

  /// Next automatic renewal; null when the plan does not renew (one-time or cancelled).
  final DateTime? renewsAt;

  /// Panel status text ("Active, Recurring", "Canceled", "Pending Payment"…).
  final String? statusLabel;

  /// Panel page for this plan (renew / manage).
  final String? manageUrl;

  bool get autoRenew => renewsAt != null;

  ProductType get type;
  bool get usable => status == MembershipStatus.active || status == MembershipStatus.expiring;
}

/// Traffic allowance of a metered plan. Bytes are decimal (1 GB = 1e9).
class Traffic {
  const Traffic({required this.totalBytes, required this.usedBytes, int? remainingBytes, this.resetsAt})
      : remainingBytes = remainingBytes ?? (totalBytes - usedBytes);
  final int totalBytes;
  final int usedBytes;
  final int remainingBytes;

  /// When the allowance resets (next billing cycle).
  final DateTime? resetsAt;
}

/// Gateway entry point ("auto" = nearest region).
class EntryPoint {
  const EntryPoint({required this.key, required this.host, this.city, required this.region});
  final String key;
  final String host;
  final String? city;
  final String region;
}

class ResidentialMembership extends Membership {
  const ResidentialMembership({
    required super.id,
    required super.planName,
    required super.status,
    required super.expiresAt,
    super.renewsAt,
    super.statusLabel,
    super.manageUrl,
    required this.pool,
    this.traffic,
    this.unmetered = false,
    this.entryPoints = const [],
    this.stickySessions = true,
  });
  final ResidentialPool pool;

  /// Null when there's nothing to show: see [unmetered].
  final Traffic? traffic;

  /// True only when usage says the plan has no traffic cap ("Unlimited").
  final bool unmetered;

  /// Gateway regions the customer can pin; empty when the plan isn't live yet.
  final List<EntryPoint> entryPoints;

  /// False when the gateway doesn't allow sticky sessions on this plan.
  final bool stickySessions;

  @override
  ProductType get type => ProductType.residential;
}

class IspMembership extends Membership {
  const IspMembership({
    required super.id,
    required super.planName,
    required super.status,
    required super.expiresAt,
    super.renewsAt,
    super.statusLabel,
    super.manageUrl,
    required this.ipCount,
    required this.countries,
  });

  /// ISP is unlimited bandwidth; targeting = pick one of the assigned static IPs.
  final int ipCount;
  final List<String> countries;

  @override
  ProductType get type => ProductType.isp;
}

// ── Geo catalog (residential) ───────────────────────────────────────────

class GeoCountry {
  const GeoCountry(this.code, this.name);
  final String code; // iso2, lowercase
  final String name;
}

class GeoRegion {
  const GeoRegion(this.slug, this.name);
  final String slug;
  final String name;
}

class GeoCity {
  const GeoCity(this.slug, this.name, {this.regionSlug});
  final String slug;
  final String name;
  final String? regionSlug;
}

class GeoAsn {
  const GeoAsn(this.asn, this.name);
  final int asn;
  final String name;
}

enum GeoHitKind { country, region, city, asn }

/// One hit from the cross-level location search.
class GeoSearchResult {
  const GeoSearchResult(this.kind, this.country, {this.region, this.city, this.asn});
  final GeoHitKind kind;
  final GeoCountry country;
  final GeoRegion? region;
  final GeoCity? city;
  final GeoAsn? asn;
}

// ── ISP ─────────────────────────────────────────────────────────────────

/// One ISP proxy of a plan. proxy-config has no address per proxy, so the
/// exit IP is only shown while connected (from the IP check).
class IspIp {
  const IspIp({required this.id, required this.country, this.city, this.asn, required this.isp, this.seq = 1, this.seqOf = 1});

  /// The proxy's own gateway username (each ISP IP has one). Never rendered.
  final String id;
  final String country; // iso2, lowercase
  final String? city;
  final int? asn;

  /// Carrier / ASN owner, e.g. "Comcast", or "AS9009" when unknown.
  final String isp;

  /// 1-based position among the plan's IPs with the same country, city and ASN.
  final int seq;

  /// How many IPs share that country, city and ASN; no "#n" when 1.
  final int seqOf;

  /// "Comcast #2" when several of the plan's IPs share country, city and ASN.
  String get label => seqOf > 1 ? '$isp #$seq' : isp;

  IspIp numbered(int seq, int seqOf) => IspIp(id: id, country: country, city: city, asn: asn, isp: isp, seq: seq, seqOf: seqOf);
}

// ── Targeting / connection ──────────────────────────────────────────────

sealed class Target {
  const Target();

  Map<String, dynamic> toJson();

  static Target? fromJson(Map<String, dynamic> j) {
    try {
      switch (j['kind']) {
        case 'isp':
          final ip = j['ip'] as Map<String, dynamic>;
          return IspTarget(IspIp(
            id: ip['id'] as String,
            country: ip['country'] as String,
            city: ip['city'] as String?,
            asn: (ip['asn'] as num?)?.toInt(),
            isp: ip['isp'] as String,
            seq: (ip['seq'] as num?)?.toInt() ?? 1,
            seqOf: (ip['seqOf'] as num?)?.toInt() ?? 1,
          ));
        case 'residential':
          Map<String, dynamic>? m(String k) => j[k] as Map<String, dynamic>?;
          final c = m('country'), r = m('region'), ci = m('city'), a = m('asn');
          return ResidentialTarget(
            country: c == null ? null : GeoCountry(c['code'] as String, c['name'] as String),
            region: r == null ? null : GeoRegion(r['slug'] as String, r['name'] as String),
            city: ci == null ? null : GeoCity(ci['slug'] as String, ci['name'] as String, regionSlug: ci['regionSlug'] as String?),
            asn: a == null ? null : GeoAsn((a['asn'] as num).toInt(), a['name'] as String),
          );
      }
    } catch (_) {
      // A target stored by an older build: drop it.
    }
    return null;
  }
}

/// A residential target. Every level below country is optional.
class ResidentialTarget extends Target {
  const ResidentialTarget({this.country, this.region, this.city, this.asn});
  final GeoCountry? country; // null = random worldwide
  final GeoRegion? region;
  final GeoCity? city;
  final GeoAsn? asn;

  static const worldwide = ResidentialTarget();

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'residential',
        if (country != null) 'country': {'code': country!.code, 'name': country!.name},
        if (region != null) 'region': {'slug': region!.slug, 'name': region!.name},
        if (city != null) 'city': {'slug': city!.slug, 'name': city!.name, 'regionSlug': city!.regionSlug},
        if (asn != null) 'asn': {'asn': asn!.asn, 'name': asn!.name},
      };

  ResidentialTarget copyWith({
    GeoCountry? Function()? country,
    GeoRegion? Function()? region,
    GeoCity? Function()? city,
    GeoAsn? Function()? asn,
  }) =>
      ResidentialTarget(
        country: country != null ? country() : this.country,
        region: region != null ? region() : this.region,
        city: city != null ? city() : this.city,
        asn: asn != null ? asn() : this.asn,
      );
}

class IspTarget extends Target {
  const IspTarget(this.ip);
  final IspIp ip;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'isp',
        'ip': {'id': ip.id, 'country': ip.country, 'city': ip.city, 'asn': ip.asn, 'isp': ip.isp, 'seq': ip.seq, 'seqOf': ip.seqOf},
      };
}

enum SessionMode { sticky, rotating }

class ProxySettings {
  const ProxySettings({
    this.sessionMode = SessionMode.sticky,
    this.ttlSeconds = 600,
    this.strict = false,
    this.autoConnect = false,
    this.entryPoint,
    this.bypassList = defaultBypassList,
  });

  static const defaultBypassList = ['localhost', '127.0.0.1', '*.local', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16'];

  final SessionMode sessionMode;

  /// Sticky session lifetime in seconds (gateway `ttl-` flag).
  final int ttlSeconds;

  /// Fail instead of widening the location when the exact target is unavailable.
  final bool strict;

  /// Connect with the last location when the app starts.
  final bool autoConnect;

  /// Residential gateway entry point key; null = the gateway picked in the panel.
  final String? entryPoint;

  /// Hostnames that always bypass the proxy.
  final List<String> bypassList;

  Map<String, dynamic> toJson() => {
        'sessionMode': sessionMode.name,
        'ttlSeconds': ttlSeconds,
        'strict': strict,
        'autoConnect': autoConnect,
        'entryPoint': entryPoint,
        'bypassList': bypassList,
      };

  /// Stored settings, filled up with defaults for fields added later.
  static ProxySettings fromJson(Map<String, dynamic> j) {
    const d = ProxySettings();
    return ProxySettings(
      sessionMode: SessionMode.values.asNameMap()[j['sessionMode']] ?? d.sessionMode,
      ttlSeconds: (j['ttlSeconds'] as num?)?.toInt() ?? d.ttlSeconds,
      strict: j['strict'] as bool? ?? d.strict,
      autoConnect: j['autoConnect'] as bool? ?? d.autoConnect,
      entryPoint: j['entryPoint'] as String?,
      bypassList: (j['bypassList'] as List?)?.cast<String>() ?? d.bypassList,
    );
  }

  ProxySettings copyWith({
    SessionMode? sessionMode,
    int? ttlSeconds,
    bool? strict,
    bool? autoConnect,
    String? Function()? entryPoint,
    List<String>? bypassList,
  }) =>
      ProxySettings(
        sessionMode: sessionMode ?? this.sessionMode,
        ttlSeconds: ttlSeconds ?? this.ttlSeconds,
        strict: strict ?? this.strict,
        autoConnect: autoConnect ?? this.autoConnect,
        entryPoint: entryPoint != null ? entryPoint() : this.entryPoint,
        bypassList: bypassList ?? this.bypassList,
      );
}

enum ConnectionStatus { disconnected, connecting, connected, error }

class ProxyConnection {
  const ProxyConnection._(this.status, {this.membershipId, this.target, this.since, this.exitIp, this.exitCountry, this.message});
  const ProxyConnection.disconnected() : this._(ConnectionStatus.disconnected);
  const ProxyConnection.connecting(String membershipId, Target target)
      : this._(ConnectionStatus.connecting, membershipId: membershipId, target: target);
  const ProxyConnection.connected(String membershipId, Target target, DateTime since, String exitIp, {String? exitCountry})
      : this._(ConnectionStatus.connected,
            membershipId: membershipId, target: target, since: since, exitIp: exitIp, exitCountry: exitCountry);
  const ProxyConnection.error(String message) : this._(ConnectionStatus.error, message: message);

  /// Same connection with a new exit (the 15 s re-check saw it change).
  ProxyConnection withExit(String ip, String? country) =>
      ProxyConnection._(status, membershipId: membershipId, target: target, since: since, exitIp: ip, exitCountry: country ?? exitCountry);

  final ConnectionStatus status;
  final String? membershipId;
  final Target? target;
  final DateTime? since;

  /// Exit IP as reported by an IP check through the proxy; the only place
  /// an ISP proxy's address is shown.
  final String? exitIp;

  /// iso2 of the exit, from the IP check.
  final String? exitCountry;
  final String? message;
}
