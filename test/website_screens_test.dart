// Renders the app screens shown on the website's app pages, screen content
// only (no device frame: the website draws its own), in every app language:
//   flutter test test/website_screens_test.dart
//   WEBSITE_SCREENS_LOCALES=en flutter test test/website_screens_test.dart  (some languages)
// Output: build/website_screens/<phone|desktop>/<locale>/<screen>.png
//
// Screens: plans, location, session, privacy (privacy-ios / privacy-android
// on phones, where the data-use screen differs per platform).
// Demo data: two Residential plans (no ISP), connected with an exit IP from
// the documentation range 203.0.113.0/24.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/data/api.dart';
import 'package:shifter_app/data/geo_catalog.dart';
import 'package:shifter_app/data/mock_api.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/data/store.dart';
import 'package:shifter_app/i18n/i18n.dart';
import 'package:shifter_app/proxy/proxy_engine.dart';
import 'package:shifter_app/state/app_controller.dart';
import 'package:shifter_app/theme/theme.dart';
import 'package:shifter_app/theme/tokens.dart';
import 'package:shifter_app/ui/screens/data_use_screen.dart';
import 'package:shifter_app/ui/screens/home_screen.dart';
import 'package:shifter_app/ui/shell/app_root.dart';
import 'package:shifter_app/ui/widgets/ambient_motion.dart';

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(rootBundle.load('assets/fonts/$f'));
    }
    await loader.load();
  }

  await family('Geist', ['Geist-Light.ttf', 'Geist-Regular.ttf', 'Geist-Medium.ttf', 'Geist-SemiBold.ttf', 'Geist-Bold.ttf']);
  await family('GeistMono', ['GeistMono-Regular.ttf', 'GeistMono-Medium.ttf', 'GeistMono-SemiBold.ttf']);
}

// Geist has no Chinese, Japanese or Korean glyphs; on a device the system
// font fills them in, but the test renderer has no system fallback. Load the
// system CJK fonts (macOS, else Noto CJK on Linux) as the fallback for those
// languages; without them the language is skipped.
const _cjkFonts = <String, List<String>>{
  'zh-Hans': ['/System/Library/Fonts/Hiragino Sans GB.ttc', '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'],
  'ja': ['/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc', '/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc', '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'],
  'ko': ['/System/Library/Fonts/AppleSDGothicNeo.ttc', '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'],
};

Future<void> _loadCjkFonts() async {
  for (final MapEntry(key: code, value: paths) in _cjkFonts.entries) {
    final files = paths.map(File.new).where((f) => f.existsSync()).toList();
    if (files.isEmpty) continue;
    final loader = FontLoader('Cjk-$code');
    for (final f in files) {
      loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
  }
}

/// Fallback families for the active language.
List<String>? get _fallback => _cjkFonts.containsKey(I18n.code) ? ['Cjk-${I18n.code}'] : null;

/// A screen form on the website: logical size, safe-area insets, pixel ratio.
class _Form {
  const _Form(this.name, this.size, this.insets);
  final String name;
  final Size size;
  final EdgeInsets insets;
}

// iPhone 15 Pro (status bar and home indicator are drawn by the website).
const _phone = _Form('phone', Size(440, 956), EdgeInsets.only(top: 62, bottom: 34)); // iPhone 16 Pro Max
// A small desktop window: the wide layout with sidebar and docked picker.
const _desktop = _Form('desktop', Size(1024, 700), EdgeInsets.zero);
const _pixelRatio = 2.0;

/// Fixed uptime shown on the connected screens.
const _uptime = Duration(minutes: 27, seconds: 31);

const _gb = 1000000000;

/// The mock backend with the website's demo plans: Residential only.
class _WebsiteApi extends MockShifterApi {
  @override
  Future<User> me() async => const User(id: 'u_demo', email: 'alex@example.com', name: 'Alex Morgan');

  @override
  Future<Session> verifyApiKey(String apiKey) async =>
      Session(user: await me(), apiKey: apiKey, createdAt: DateTime.now());

  static DateTime _days(int n) => DateTime.now().add(Duration(days: n, hours: 2));

  static final plans = <Membership>[
    ResidentialMembership(
      id: 'm_business', planName: 'Business', pool: ResidentialPool.full, status: MembershipStatus.active,
      expiresAt: _days(12), renewsAt: _days(12), traffic: Traffic(totalBytes: 200 * _gb, usedBytes: (63.4 * _gb).round()),
    ),
    ResidentialMembership(
      id: 'm_starter', planName: 'Starter', pool: ResidentialPool.country, status: MembershipStatus.active,
      expiresAt: _days(19), renewsAt: _days(19), traffic: Traffic(totalBytes: 50 * _gb, usedBytes: (31.8 * _gb).round()),
    ),
  ];

  @override
  Future<MembershipCatalog> memberships() async => MembershipCatalog(memberships: plans);

  @override
  Future<ProxyCredentials> credentials(String membershipId) async => const ProxyCredentials(
        type: ProductType.residential, host: 'p.shifter.io', port: 443, username: 'customer-demo', password: 'demo', stickySessions: true);
}

/// Connects instantly with a fixed exit.
class _WebsiteEngine extends MockProxyEngine {
  _WebsiteEngine() : super(delay: Duration.zero);
  @override
  Future<ExitInfo> checkExit() async => const ExitInfo('203.0.113.42', country: 'us');
}

/// Signed in on the Business plan, New York picked (as after a restart).
MemoryStore _store() => MemoryStore()
  ..session = Session(
      user: const User(id: 'u_demo', email: 'alex@example.com', name: 'Alex Morgan'),
      apiKey: 'website0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN',
      createdAt: DateTime.now())
  ..activeMembership = 'm_business'
  ..targets = {
    'm_business': const ResidentialTarget(
      country: GeoCountry('us', 'United States'),
      region: GeoRegion('new_york', 'New York'),
      city: GeoCity('new_york', 'New York', regionSlug: 'new_york'),
    ),
  };

class _WebsiteController extends AppController {
  _WebsiteController() : super(api: _WebsiteApi(), engine: _WebsiteEngine(), store: _store());

  /// Backdates the connection so the uptime reads [_uptime].
  void backdate() {
    final c = connection;
    if (c.status != ConnectionStatus.connected) return;
    connection = ProxyConnection.connected(c.membershipId!, c.target!, DateTime.now().subtract(_uptime + const Duration(milliseconds: 200)), c.exitIp!,
        exitCountry: c.exitCountry);
    notifyListeners();
  }
}

Future<void> _settle(WidgetTester tester, {int frames = 12, Duration step = const Duration(milliseconds: 150)}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
}

Future<void> _shot(WidgetTester tester, GlobalKey boundary, _Form form, String locale, String name) async {
  await tester.runAsync(() async {
    final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await ro.toImage(pixelRatio: _pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/website_screens/${form.name}/$locale')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

ThemeData _theme() {
  final t = buildShifterTheme();
  final f = _fallback;
  if (f == null) return t;
  return t.copyWith(textTheme: t.textTheme.apply(fontFamilyFallback: f), primaryTextTheme: t.primaryTextTheme.apply(fontFamilyFallback: f));
}

/// Pumps [child] at the form's exact screen size, with its insets.
Future<GlobalKey> _pump(WidgetTester tester, _Form form, Widget child, {AppController? controller}) async {
  await tester.binding.setSurfaceSize(form.size);
  final boundary = GlobalKey();
  Widget app = MaterialApp(
    key: ValueKey(I18n.code),
    debugShowCheckedModeBanner: false,
    locale: I18n.locale,
    supportedLocales: I18n.supportedLocales,
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: _theme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        size: form.size,
        padding: form.insets,
        viewPadding: form.insets,
        viewInsets: EdgeInsets.zero,
        textScaler: TextScaler.noScaling,
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(fontFamilyFallback: _fallback),
        child: ColoredBox(color: Sf.bgDeepest, child: child!),
      ),
    ),
    home: child,
  );
  if (controller != null) app = AppScope(controller: controller, child: app);
  await tester.pumpWidget(RepaintBoundary(key: boundary, child: app));
  await _settle(tester, frames: 16);
  return boundary;
}

Future<(GlobalKey, _WebsiteController)> _pumpApp(WidgetTester tester, _Form form) async {
  final controller = _WebsiteController();
  addTearDown(controller.dispose);
  final b = await _pump(tester, form, const AmbientMotionScope(child: AppRoot()), controller: controller);
  unawaited(controller.connect());
  await _settle(tester, frames: 10);
  return (b, controller);
}

Future<void> _connectedShot(WidgetTester tester, GlobalKey b, _WebsiteController c, _Form form, String locale, String name) async {
  c.backdate();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(milliseconds: 50));
  await _shot(tester, b, form, locale, name);
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    await GeoCatalog.load();
    await _loadCjkFonts();
  });
  // Freeze the decorative loops so every language gets the same frame.
  setUp(() => ambientMotion.value = false);

  // WEBSITE_SCREENS_LOCALES=en,de limits the languages (default: all).
  final only = Platform.environment['WEBSITE_SCREENS_LOCALES']?.split(',').map((c) => c.trim()).toSet();
  for (final locale in I18n.codes.where((c) => only == null || only.contains(c))) {
    final skip = _cjkFonts.containsKey(locale) && !_cjkFonts[locale]!.any((p) => File(p).existsSync())
        ? 'no $locale system font found for the CJK fallback'
        : null;
    group(locale, skip: skip, () {
      setUp(() async => I18n.load(code: locale));

      // ── Phone ────────────────────────────────────────────────────────
      testWidgets('phone · plans', (tester) async {
        final (b, c) = await _pumpApp(tester, _phone);
        await tester.tap(find.byType(PlanSwitcherButton));
        await _settle(tester, frames: 10);
        await _connectedShot(tester, b, c, _phone, locale, 'plans');
      });

      testWidgets('phone · location', (tester) async {
        final (b, c) = await _pumpApp(tester, _phone);
        await tester.tap(find.byType(LocationCard));
        await _settle(tester, frames: 10);
        await _connectedShot(tester, b, c, _phone, locale, 'location');
      });

      testWidgets('phone · session', (tester) async {
        final (b, c) = await _pumpApp(tester, _phone);
        await tester.tap(find.byTooltip(tr('Settings')).hitTestable().first);
        await _settle(tester, frames: 10);
        await _connectedShot(tester, b, c, _phone, locale, 'session');
      });

      for (final ios in [true, false]) {
        testWidgets('phone · privacy · ${ios ? 'ios' : 'android'}', (tester) async {
          final b = await _pump(tester, _phone, DataUseScreen(ios: ios, onAccept: () {}));
          await _shot(tester, b, _phone, locale, ios ? 'privacy-ios' : 'privacy-android');
        });
      }

      // ── Desktop ──────────────────────────────────────────────────────
      testWidgets('desktop · plans', (tester) async {
        final (b, c) = await _pumpApp(tester, _desktop);
        await tester.tap(find.text(tr('Plans')).hitTestable().first);
        await _settle(tester, frames: 10);
        await _connectedShot(tester, b, c, _desktop, locale, 'plans');
      });

      testWidgets('desktop · location', (tester) async {
        final (b, c) = await _pumpApp(tester, _desktop);
        await _connectedShot(tester, b, c, _desktop, locale, 'location');
      });

      testWidgets('desktop · session', (tester) async {
        final (b, c) = await _pumpApp(tester, _desktop);
        await tester.tap(find.text(tr('Settings')).hitTestable().first);
        await _settle(tester, frames: 10);
        await _connectedShot(tester, b, c, _desktop, locale, 'session');
      });

      testWidgets('desktop · privacy', (tester) async {
        final (b, c) = await _pumpApp(tester, _desktop);
        await tester.tap(find.text(tr('Settings')).hitTestable().first);
        await _settle(tester, frames: 10);
        // Bring "How traffic is routed" and the bypass list into view.
        // (Section labels are drawn upper-case, so find the first row instead.)
        final dns = find.text(tr('DNS through Shifter'));
        await tester.dragUntilVisible(dns, find.byType(Scrollable).last, const Offset(0, -120));
        await _settle(tester, frames: 4);
        await tester.drag(find.byType(Scrollable).last, Offset(0, -(tester.getTopLeft(dns).dy - 170)));
        await _settle(tester, frames: 8);
        await _connectedShot(tester, b, c, _desktop, locale, 'privacy');
      });
    });
  }
}
