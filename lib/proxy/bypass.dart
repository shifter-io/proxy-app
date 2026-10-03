/// Bypass-list rules, shared by Settings (validation), the local proxy
/// (matching) and the OS proxy settings. Port of the extension's
/// src/lib/proxy/bypass.ts, so every client treats an entry the same way.
///
/// Accepted entries:
///   example.com        that host only
///   *.example.com      example.com and all its subdomains
///   192.168.1.10       one IPv4 address
///   192.168.0.0/16     an IPv4 range (CIDR)
library;

/// Always direct: the API must stay reachable, and loopback never goes to a remote gateway.
const alwaysBypass = ['localhost', '*.localhost', '127.0.0.1', '[::1]', 'shifter.io', '*.shifter.io'];

final _host = RegExp(r'^(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)*$');
final _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

/// Cleans what the user typed ("https://Example.com/path" -> "example.com")
/// and returns the rule, or null when it isn't one of the accepted forms.
String? normalizeBypassRule(String input) {
  var v = input.trim().toLowerCase();
  final hadScheme = RegExp(r'^[a-z]+://').hasMatch(v);
  v = v.replaceFirst(RegExp(r'^[a-z]+://'), '');
  // Keep a CIDR suffix ("/16"), drop a URL path.
  final cidr = hadScheme ? null : RegExp(r'^([\d.]+)/(\d{1,2})$').firstMatch(v);
  if (cidr != null) {
    final bits = int.parse(cidr[2]!);
    return _ipv4ToInt(cidr[1]!) != null && bits <= 32 ? '${cidr[1]}/$bits' : null;
  }
  v = v.replaceFirst(RegExp(r'[/?#].*$'), '').replaceFirst(RegExp(r':\d+$'), '');
  if (_ipv4.hasMatch(v)) return _ipv4ToInt(v) != null ? v : null;
  return _host.hasMatch(v) ? v : null;
}

/// Does [host] (a hostname or IP, no port) match [rule]?
bool matchesBypassRule(String host, String rule) {
  final h = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  final r = rule.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  if (r.contains('/')) {
    final [base, bits] = r.split('/');
    final ip = _ipv4ToInt(h);
    final net = _ipv4ToInt(base);
    final n = int.tryParse(bits);
    if (ip == null || net == null || n == null) return false;
    final mask = n == 0 ? 0 : (0xFFFFFFFF << (32 - n)) & 0xFFFFFFFF;
    return (ip & mask) == (net & mask);
  }
  if (r.startsWith('*.')) return h == r.substring(2) || h.endsWith(r.substring(1));
  return h == r;
}

bool isBypassed(String host, List<String> userRules) =>
    [...alwaysBypass, ...userRules].any((rule) => matchesBypassRule(host, rule));

/// Every rule plus, for `*.example.com`, the bare domain too: OS proxy
/// settings treat the wildcard as subdomains only.
List<String> expandedBypassList(List<String> userRules) {
  final out = <String>[];
  for (final rule in [...alwaysBypass, ...userRules]) {
    out.add(rule);
    if (rule.startsWith('*.')) out.add(rule.substring(2));
  }
  return out.toSet().toList();
}

int? _ipv4ToInt(String ip) {
  final m = _ipv4.firstMatch(ip);
  if (m == null) return null;
  final parts = [for (var i = 1; i <= 4; i++) int.parse(m[i]!)];
  if (parts.any((p) => p > 255)) return null;
  return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
}
