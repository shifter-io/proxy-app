import 'dart:math';

import 'models.dart';

/// Formatting + targeting helpers, ported from the extension
/// (src/lib/format.ts, pools.ts, proxy/slug.ts, proxy/username.ts).

/// Decimal units, same as the panel and the API (1 GB = 1,000,000,000 bytes).
const _gb = 1000000000;
const _mb = 1000000;

String _trim(double n, int digits) {
  final s = n.toStringAsFixed(digits);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

String formatBytes(num bytes, {int digits = 1}) {
  final gb = bytes / _gb;
  if (gb >= 1000) return '${_trim(gb / 1000, digits)} TB';
  if (gb >= 1) return '${_trim(gb, digits)} GB';
  return '${_trim(bytes / _mb, 0)} MB';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String formatDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

/// "in 23 days", "tomorrow", "6 days ago"
String relativeDays(DateTime d) {
  final diff = (d.difference(DateTime.now()).inHours / 24).round();
  if (diff == 0) return 'today';
  if (diff == 1) return 'tomorrow';
  if (diff == -1) return 'yesterday';
  return diff > 0 ? 'in $diff days' : '${-diff} days ago';
}

String formatDuration(int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${(seconds / 60).round()} min';
  return '${_trim(seconds / 3600, 1)} h';
}

String formatUptime(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

/// Traffic left on a metered plan; null when the plan has no cap to show.
({int left, double ratio, int total})? trafficLeft(ResidentialMembership m) {
  final t = m.traffic;
  if (t == null) return null;
  final left = max(0, t.remainingBytes);
  final ratio = t.totalBytes > 0 ? (left / t.totalBytes).clamp(0.0, 1.0) : 0.0;
  return (left: left, ratio: ratio, total: t.totalBytes);
}

/// "Unlimited" for unmetered plans, "—" while usage isn't known yet.
String noTrafficLabel(ResidentialMembership m) => m.unmetered ? 'Unlimited' : '—';

/// "New York · AS7922"
String ispIpPlace(IspIp ip) => [ip.city ?? ip.country.toUpperCase(), if (ip.asn != null) 'AS${ip.asn}'].join(' · ');

String productLabel(ProductType t) => t == ProductType.residential ? 'Residential' : 'ISP';

String poolLabel(ResidentialPool p) => switch (p) {
      ResidentialPool.full => 'Full Geo',
      ResidentialPool.country => 'Country Geo',
      ResidentialPool.nonGeo => 'Non-Geo',
    };

/// Shown above the full A–Z list in the location picker.
const popularCountries = ['us', 'gb', 'de', 'fr', 'ca'];

// ── Pools ───────────────────────────────────────────────────────────────

/// What each Residential pool can target (panel: ResidentialPools).
({bool country, bool subCountry}) poolTargeting(ResidentialPool p) => switch (p) {
      ResidentialPool.full => (country: true, subCountry: true),
      ResidentialPool.country => (country: true, subCountry: false),
      ResidentialPool.nonGeo => (country: false, subCountry: false),
    };

String? poolLimitNote(ResidentialPool p) => switch (p) {
      ResidentialPool.full => null,
      ResidentialPool.country =>
        'Your Country Geo plan targets by country. Full Geo adds state, city and ISP targeting.',
      ResidentialPool.nonGeo =>
        'Non-Geo plans use random IPs worldwide. Upgrade to Country Geo or Full Geo to pick a location.',
    };

/// Drops any level the pool can't serve.
ResidentialTarget clampTarget(ResidentialTarget t, ResidentialPool pool) {
  final caps = poolTargeting(pool);
  if (!caps.country) return ResidentialTarget.worldwide;
  if (!caps.subCountry) return ResidentialTarget(country: t.country);
  return t;
}

// ── Targets ─────────────────────────────────────────────────────────────

/// Primary + secondary label for a target, most specific first.
({String title, String subtitle}) describeTarget(Target? target) {
  switch (target) {
    case null:
      return (title: 'Choose location', subtitle: 'No location selected');
    case IspTarget(:final ip):
      return (title: ip.label, subtitle: ispIpPlace(ip));
    case ResidentialTarget t:
      if (t.country == null) return (title: 'Random location', subtitle: 'Worldwide · best available');
      final title = t.city?.name ?? t.region?.name ?? t.country!.name;
      final trail = [
        if (t.city != null && t.region != null) t.region!.name,
        if (t.city != null || t.region != null) t.country!.name,
      ].join(', ');
      final asn = t.asn?.name ?? '';
      return (title: title, subtitle: [trail.isEmpty ? 'Any city' : trail, asn].where((s) => s.isNotEmpty).join(' · '));
  }
}

String? targetCountryCode(Target? target) => switch (target) {
      IspTarget(:final ip) => ip.country,
      ResidentialTarget(:final country) => country?.code,
      null => null,
    };

bool sameTarget(Target a, Target b) {
  if (a is IspTarget && b is IspTarget) return a.ip.id == b.ip.id;
  if (a is ResidentialTarget && b is ResidentialTarget) {
    return a.country?.code == b.country?.code &&
        a.region?.slug == b.region?.slug &&
        a.city?.slug == b.city?.slug &&
        a.asn?.asn == b.asn?.asn;
  }
  return false;
}

/// Residential defaults to a random worldwide exit; ISP needs an explicit IP.
Target? defaultTarget(Membership m) => m is ResidentialMembership ? ResidentialTarget.worldwide : null;

// ── Gateway ─────────────────────────────────────────────────────────────

/// "Los Angeles" -> "los_angeles", "Île-de-France" -> "ile_de_france"
String slugify(String label) {
  var s = label.trim().toLowerCase().split('').map((c) {
    final i = _accented.indexOf(c);
    return i < 0 ? c : _plain[i];
  }).join();
  s = s.replaceAll(RegExp(r"['’]"), '').replaceAll(RegExp(r'[\s-]+'), '_').replaceAll(RegExp(r'_+'), '_');
  return s.replaceAll(RegExp(r'^_+|_+$'), '');
}

/// Lowercase letters that NFD splits into an ASCII base + accent (what the
/// panel's slug rule strips), generated from Unicode data.
const _accented = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿāăąćĉċčďēĕėęěĝğġģĥĩīĭįĵķĺļľńņňōŏőŕŗřśŝşšţťũūŭůűųŵŷźżžơưǎǐǒǔǖǘǚǜǟǡǧǩǫǭǰǵǹǻȁȃȅȇȉȋȍȏȑȓȕȗșțȟȧȩȫȭȯȱȳḁḃḅḇḉḋḍḏḑḓḕḗḙḛḝḟḡḣḥḧḩḫḭḯḱḳḵḷḹḻḽḿṁṃṅṇṉṋṍṏṑṓṕṗṙṛṝṟṡṣṥṧṩṫṭṯṱṳṵṷṹṻṽṿẁẃẅẇẉẋẍẏẑẓẕẖẗẘẙạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ';
const _plain = 'aaaaaaceeeeiiiinooooouuuuyyaaaccccdeeeeegggghiiiijklllnnnooorrrssssttuuuuuuwyzzzouaiouuuuuaagkoojgnaaaeeiioorruusthaeooooyabbbcdddddeeeeefghhhhhiikkkllllmmmnnnnoooopprrrrsssssttttuuuuuvvwwwwwxxyzzzhtwyaaaaaaaaaaaaeeeeeeeeiioooooooooooouuuuuuuyyyy';

/// Residential gateway username, same grammar as the panel endpoint builder:
/// `<base>[-country-<iso2>][-region-<slug>][-city-<slug>][-asn-<num>][-sid-<id>][-ttl-<s>][-strict-true]`
String buildResidentialUsername(String base, ResidentialTarget t, ProxySettings s, {String? sid}) {
  final parts = [base];
  if (t.country != null) parts.addAll(['country', t.country!.code]);
  if (t.region != null) parts.addAll(['region', t.region!.slug]);
  if (t.city != null) parts.addAll(['city', t.city!.slug]);
  if (t.asn != null) parts.addAll(['asn', '${t.asn!.asn}']);
  if (s.sessionMode == SessionMode.sticky && sid != null) {
    parts.addAll(['sid', sid]);
    if (s.ttlSeconds > 0) parts.addAll(['ttl', '${s.ttlSeconds}']);
  }
  if (s.strict) parts.addAll(['strict', 'true']);
  return parts.join('-');
}
