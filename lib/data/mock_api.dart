import 'dart:async';

import 'api.dart';
import 'format.dart';
import 'geo_catalog.dart';
import 'models.dart';

/// In-memory backend for the preview studio and tests, with the same scenarios as the extension, chosen by the
/// API key's prefix: single / country / nongeo / isp / none / invalid.
/// Any other key of 32+ letters/digits gets the full set of plans.
class MockShifterApi implements ShifterApi {
  MockShifterApi({this.scenario = ''});
  String scenario;

  Future<void> _delay([int ms = 350]) => Future.delayed(Duration(milliseconds: ms));

  @override
  Future<Session> verifyApiKey(String apiKey) async {
    await _delay(750);
    final key = apiKey.trim();
    if (!apiKeyPattern.hasMatch(key) || key.toLowerCase().startsWith('invalid')) {
      throw ApiException('Invalid API key', code: ApiErrorCode.unauthorized);
    }
    scenario = scenarioOf(key);
    return Session(user: _user(), apiKey: key, createdAt: DateTime.now());
  }

  static String scenarioOf(String key) {
    final k = key.toLowerCase();
    for (final p in const ['single', 'country', 'nongeo', 'isp', 'none']) {
      if (k.startsWith(p)) return p;
    }
    return '';
  }

  @override
  void useSession(Session? session) {
    if (session != null) scenario = scenarioOf(session.apiKey);
  }

  @override
  Future<User> me() async => _user();

  @override
  Future<ProxyCredentials> credentials(String membershipId) async {
    await _delay(200);
    final m = Fixtures.memberships.firstWhere((m) => m.id == membershipId);
    return ProxyCredentials(
      type: m.type,
      host: m is IspMembership ? 'isp.shifter.io' : 'p.shifter.io',
      port: 443,
      username: m is IspMembership ? '' : 'customer-mock',
      password: 'mock',
      stickySessions: m is ResidentialMembership,
    );
  }

  User _user() => User(id: 'u_mock', email: scenario.isEmpty ? 'you@example.com' : '$scenario@example.com', name: 'Example User');

  @override
  Future<List<Membership>> memberships() async {
    await _delay(600);
    final all = Fixtures.memberships;
    return switch (scenario) {
      'single' => all.where((m) => m.id == 'm_res_1').toList(),
      'country' => all.where((m) => m.id == 'm_res_country').toList(),
      'nongeo' => all.where((m) => m.id == 'm_res_nongeo').toList(),
      'isp' => all.where((m) => m.id == 'm_isp_us').toList(),
      'none' => all.where((m) => m.status == MembershipStatus.expired).toList(),
      _ => all,
    };
  }

  // Geo comes from the real catalog (names only), so the picker shows every
  // place and ISP customers can target.
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

  @override
  Future<List<IspIp>> ispIps(String membershipId) async {
    await _delay(320);
    return Fixtures.ispIps[membershipId] ?? const [];
  }
}

abstract final class Fixtures {
  static const _gbBytes = 1000000000;
  static DateTime _days(int n) => DateTime.now().add(Duration(days: n, hours: 2));

  static final memberships = <Membership>[
    ResidentialMembership(
      id: 'm_res_1', planName: 'Pro', pool: ResidentialPool.full, status: MembershipStatus.active,
      expiresAt: _days(23), renewsAt: _days(23), traffic: Traffic(totalBytes: 50 * _gbBytes, usedBytes: (17.6 * _gbBytes).round()),
    ),
    IspMembership(
      id: 'm_isp_us', planName: '25 ISP Proxies', status: MembershipStatus.active,
      expiresAt: _days(11), renewsAt: _days(11), ipCount: 25, countries: const ['us'],
    ),
    IspMembership(
      id: 'm_isp_eu', planName: '50 ISP Proxies', status: MembershipStatus.expiring,
      expiresAt: _days(2), ipCount: 50, countries: const ['de', 'gb', 'nl'],
    ),
    ResidentialMembership(
      id: 'm_res_country', planName: 'Starter', pool: ResidentialPool.country, status: MembershipStatus.active,
      expiresAt: _days(17), renewsAt: _days(17), traffic: Traffic(totalBytes: 10 * _gbBytes, usedBytes: (3.2 * _gbBytes).round()),
    ),
    ResidentialMembership(
      id: 'm_res_nongeo', planName: 'Spark', pool: ResidentialPool.nonGeo, status: MembershipStatus.active,
      expiresAt: _days(29), renewsAt: _days(29), traffic: Traffic(totalBytes: 5 * _gbBytes, usedBytes: (4.4 * _gbBytes).round()),
    ),
    IspMembership(
      id: 'm_isp_expired', planName: '100 ISP Proxies', status: MembershipStatus.expired,
      expiresAt: _days(-6), ipCount: 100, countries: const ['us'],
    ),
  ];

  static List<IspIp> _ips(String country, String city, int asn, String isp, int count) => [
        for (var i = 0; i < count; i++)
          IspIp(id: '$country-${slugify(city)}-as$asn-${i.toRadixString(36).padLeft(5, 'x')}', country: country, city: city, asn: asn, isp: isp),
      ];

  static final ispIps = <String, List<IspIp>>{
    'm_isp_us': numberIspIps([
      ..._ips('us', 'New York', 7922, 'Comcast', 8),
      ..._ips('us', 'Los Angeles', 7018, 'AT&T', 7),
      ..._ips('us', 'Dallas', 701, 'Verizon', 6),
      ..._ips('us', 'Miami', 20115, 'Spectrum', 4),
    ]),
    'm_isp_eu': numberIspIps([
      ..._ips('de', 'Frankfurt', 3320, 'Deutsche Telekom', 20),
      ..._ips('gb', 'London', 5089, 'Virgin Media', 20),
      ..._ips('nl', 'Amsterdam', 1136, 'KPN', 10),
    ]),
  };
}
