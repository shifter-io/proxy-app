import 'models.dart';

enum ApiErrorCode { unauthorized, rateLimited, network, server, validation }

class ApiException implements Exception {
  ApiException(this.message, {this.code = ApiErrorCode.server});
  final String message;
  final ApiErrorCode code;

  bool get unauthorized => code == ApiErrorCode.unauthorized;

  @override
  String toString() => 'ApiException($code): $message';
}

/// Gateway login for one membership. Never logged, never rendered.
class ProxyCredentials {
  const ProxyCredentials({
    required this.type,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.entryPoints = const [],
    this.stickySessions = false,
  });
  final ProductType type;

  /// Gateway the customer picked in the panel (HTTP, even on port 443).
  final String host;
  final int port;

  /// Residential: base username the targeting is appended to. ISP: empty,
  /// each IP has its own (IspIp.id).
  final String username;
  final String password;

  /// Residential gateway regions; the chosen one replaces [host].
  final List<EntryPoint> entryPoints;

  /// False when the plan doesn't allow `sid-` sticky sessions.
  final bool stickySessions;

  @override
  String toString() => 'ProxyCredentials($type, $host:$port, <redacted>)';
}

/// The contract the UI talks to: [HttpShifterApi] against shifter.io in the
/// real app, [MockShifterApi] in the preview studio and tests. Same shape as
/// the extension's (src/lib/api/types.ts).
abstract class ShifterApi {
  /// Attach (or clear) the signed-in session; the HTTP client sends its key.
  void useSession(Session? session);

  /// Resolves with a session for a valid key, throws ApiException(unauthorized) otherwise.
  Future<Session> verifyApiKey(String apiKey);

  Future<User> me();
  Future<List<Membership>> memberships();

  // Residential locations (bundled catalog, data/geo_catalog.dart).
  Future<List<GeoCountry>> countries();
  Future<List<GeoRegion>> regions(String country);
  Future<List<GeoCity>> cities(String country, {String? region});

  /// ISPs at the most specific level given (country, state or city).
  Future<List<GeoAsn>> asns(String country, {String? region, String? city});
  Future<List<GeoSearchResult>> searchGeo(String query);

  Future<List<IspIp>> ispIps(String membershipId);

  /// Gateway login for a membership.
  Future<ProxyCredentials> credentials(String membershipId);
}

/// Panel API keys: 32+ letters and digits.
final apiKeyPattern = RegExp(r'^[A-Za-z0-9]{32,128}$');

/// Numbers IPs that share country + city + ASN (#1, #2…), in list order.
List<IspIp> numberIspIps(List<IspIp> list) {
  String key(IspIp ip) => '${ip.country}|${ip.city ?? ''}|${ip.asn ?? ''}';
  final totals = <String, int>{};
  for (final ip in list) {
    totals[key(ip)] = (totals[key(ip)] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return [
    for (final ip in list) ip.numbered(seen[key(ip)] = (seen[key(ip)] ?? 0) + 1, totals[key(ip)]!),
  ];
}
