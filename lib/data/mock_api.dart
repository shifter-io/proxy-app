import 'dart:async';

import 'geo_catalog.dart';
import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.unauthorized = false});
  final String message;
  final bool unauthorized;
}

/// The contract the UI talks to. Today it is backed by [MockShifterApi];
/// the API phase adds an HTTP implementation against shifter.io/api/v1.
abstract class ShifterApi {
  Future<Session> verifyApiKey(String apiKey);
  Future<List<Membership>> memberships();
  Future<List<GeoCountry>> countries();
  Future<List<GeoRegion>> regions(String country);
  Future<List<GeoCity>> cities(String country, {String? region});
  /// ISPs at the most specific level given (country, state or city).
  Future<List<GeoAsn>> asns(String country, {String? region, String? city});
  Future<List<GeoSearchResult>> searchGeo(String query);
  Future<List<IspIp>> ispIps(String membershipId);
}

/// In-memory backend with the same scenarios as the extension, chosen by the
/// API key's prefix: single / country / nongeo / isp / none / invalid.
/// Any other key of 32+ letters/digits gets the full set of plans.
class MockShifterApi implements ShifterApi {
  MockShifterApi({this.scenario = ''});
  String scenario;

  static final keyPattern = RegExp(r'^[A-Za-z0-9]{32,128}$');

  Future<void> _delay([int ms = 350]) => Future.delayed(Duration(milliseconds: ms));

  @override
  Future<Session> verifyApiKey(String apiKey) async {
    await _delay(750);
    final key = apiKey.trim();
    if (!keyPattern.hasMatch(key) || key.toLowerCase().startsWith('invalid')) {
      throw ApiException('Invalid API key', unauthorized: true);
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
  static const _gbBytes = 1024 * 1024 * 1024;
  static DateTime _days(int n) => DateTime.now().add(Duration(days: n, hours: 2));

  static final memberships = <Membership>[
    ResidentialMembership(
      id: 'm_res_1', planName: 'Pro', pool: ResidentialPool.full, status: MembershipStatus.active,
      expiresAt: _days(23), autoRenew: true, trafficTotalBytes: 50 * _gbBytes, trafficUsedBytes: (17.6 * _gbBytes).round(),
    ),
    IspMembership(
      id: 'm_isp_us', planName: '25 ISP Proxies', status: MembershipStatus.active,
      expiresAt: _days(11), autoRenew: true, ipCount: 25, countries: const ['us'],
    ),
    IspMembership(
      id: 'm_isp_eu', planName: '50 ISP Proxies', status: MembershipStatus.expiring,
      expiresAt: _days(2), autoRenew: false, ipCount: 50, countries: const ['de', 'gb', 'nl'],
    ),
    ResidentialMembership(
      id: 'm_res_country', planName: 'Starter', pool: ResidentialPool.country, status: MembershipStatus.active,
      expiresAt: _days(17), autoRenew: true, trafficTotalBytes: 10 * _gbBytes, trafficUsedBytes: (3.2 * _gbBytes).round(),
    ),
    ResidentialMembership(
      id: 'm_res_nongeo', planName: 'Spark', pool: ResidentialPool.nonGeo, status: MembershipStatus.active,
      expiresAt: _days(29), autoRenew: true, trafficTotalBytes: 5 * _gbBytes, trafficUsedBytes: (4.4 * _gbBytes).round(),
    ),
    IspMembership(
      id: 'm_isp_expired', planName: '100 ISP Proxies', status: MembershipStatus.expired,
      expiresAt: _days(-6), autoRenew: false, ipCount: 100, countries: const ['us'],
    ),
  ];

  static List<IspIp> _ips(String prefix, String country, String city, String isp, int count, [int start = 10]) => [
        for (var i = 0; i < count; i++)
          IspIp(id: '$country-$prefix-${start + i}', ip: '$prefix.${start + i}', country: country, city: city, isp: isp),
      ];

  static final ispIps = <String, List<IspIp>>{
    'm_isp_us': [
      ..._ips('104.28.41', 'us', 'New York', 'Comcast', 8),
      ..._ips('172.58.12', 'us', 'Los Angeles', 'AT&T', 7, 40),
      ..._ips('68.183.77', 'us', 'Dallas', 'Verizon', 6, 120),
      ..._ips('73.162.9', 'us', 'Miami', 'Spectrum', 4, 200),
    ],
    'm_isp_eu': [
      ..._ips('91.64.18', 'de', 'Frankfurt', 'Deutsche Telekom', 20, 30),
      ..._ips('86.14.201', 'gb', 'London', 'Virgin Media', 20, 60),
      ..._ips('145.53.8', 'nl', 'Amsterdam', 'KPN', 10, 90),
    ],
  };
}
