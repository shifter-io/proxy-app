/// Domain models shared by the UI, the mock API and (later) the HTTP API.
/// Ported from the proxy extension (src/lib/types.ts); shapes follow the
/// Shifter Panel where one exists.
library;

class User {
  const User({required this.id, required this.email, this.name});
  final String id;
  final String email;
  final String? name;
}

class Session {
  const Session({required this.user, required this.apiKey, required this.createdAt});
  final User user;

  /// The user's panel API key (users.api_token). Sent on every API call.
  final String apiKey;
  final DateTime createdAt;
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
    required this.autoRenew,
  });
  final String id;

  /// Plan title exactly as the API returns it ("Pro", "25 ISP Proxies").
  final String planName;
  final MembershipStatus status;
  final DateTime expiresAt;
  final bool autoRenew;

  ProductType get type;
  bool get usable => status == MembershipStatus.active || status == MembershipStatus.expiring;
}

class ResidentialMembership extends Membership {
  const ResidentialMembership({
    required super.id,
    required super.planName,
    required super.status,
    required super.expiresAt,
    required super.autoRenew,
    required this.pool,
    required this.trafficTotalBytes,
    required this.trafficUsedBytes,
  });
  final ResidentialPool pool;
  final int trafficTotalBytes;
  final int trafficUsedBytes;

  @override
  ProductType get type => ProductType.residential;
}

class IspMembership extends Membership {
  const IspMembership({
    required super.id,
    required super.planName,
    required super.status,
    required super.expiresAt,
    required super.autoRenew,
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

class IspIp {
  const IspIp({required this.id, required this.ip, required this.country, this.city, required this.isp});
  final String id;
  final String ip;
  final String country;
  final String? city;
  final String isp;
}

// ── Targeting / connection ──────────────────────────────────────────────

sealed class Target {
  const Target();
}

/// A residential target. Every level below country is optional.
class ResidentialTarget extends Target {
  const ResidentialTarget({this.country, this.region, this.city, this.asn});
  final GeoCountry? country; // null = random worldwide
  final GeoRegion? region;
  final GeoCity? city;
  final GeoAsn? asn;

  static const worldwide = ResidentialTarget();

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
}

enum SessionMode { sticky, rotating }

class ProxySettings {
  const ProxySettings({
    this.sessionMode = SessionMode.sticky,
    this.ttlSeconds = 600,
    this.strict = false,
    this.autoConnect = false,
    this.bypassList = const ['localhost', '*.local', 'shifter.io'],
  });
  final SessionMode sessionMode;

  /// Sticky session lifetime in seconds (gateway `ttl-` flag).
  final int ttlSeconds;

  /// Fail instead of widening the location when the exact target is unavailable.
  final bool strict;

  /// Connect with the last location when the app starts.
  final bool autoConnect;

  /// Hostnames that always bypass the proxy.
  final List<String> bypassList;

  ProxySettings copyWith({
    SessionMode? sessionMode,
    int? ttlSeconds,
    bool? strict,
    bool? autoConnect,
    List<String>? bypassList,
  }) =>
      ProxySettings(
        sessionMode: sessionMode ?? this.sessionMode,
        ttlSeconds: ttlSeconds ?? this.ttlSeconds,
        strict: strict ?? this.strict,
        autoConnect: autoConnect ?? this.autoConnect,
        bypassList: bypassList ?? this.bypassList,
      );
}

enum ConnectionStatus { disconnected, connecting, connected, error }

class ProxyConnection {
  const ProxyConnection._(this.status, {this.membershipId, this.target, this.since, this.exitIp, this.message});
  const ProxyConnection.disconnected() : this._(ConnectionStatus.disconnected);
  const ProxyConnection.connecting(String membershipId, Target target)
      : this._(ConnectionStatus.connecting, membershipId: membershipId, target: target);
  const ProxyConnection.connected(String membershipId, Target target, DateTime since, String exitIp)
      : this._(ConnectionStatus.connected, membershipId: membershipId, target: target, since: since, exitIp: exitIp);
  const ProxyConnection.error(String message) : this._(ConnectionStatus.error, message: message);

  final ConnectionStatus status;
  final String? membershipId;
  final Target? target;
  final DateTime? since;

  /// Exit IP as reported by an IP check through the proxy.
  final String? exitIp;
  final String? message;
}
