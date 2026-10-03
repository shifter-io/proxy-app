import 'package:flutter/widgets.dart';

enum DeviceGroup { phone, foldable, tablet, desktop }

enum FrameStyle { iphoneIsland, iphoneClassic, androidPunch, tablet, desktop }

/// A simulated screen: logical size (portrait), safe-area insets and frame.
class PreviewDevice {
  const PreviewDevice({
    required this.id,
    required this.name,
    required this.group,
    required this.size,
    required this.style,
    this.safeTop = 0,
    this.safeBottom = 0,
    this.radius = 0,
    this.foldPartner,
    this.note,
  });

  final String id;
  final String name;
  final DeviceGroup group;

  /// Logical pixels (dp / pt), portrait.
  final Size size;
  final FrameStyle style;
  final double safeTop;
  final double safeBottom;
  final double radius;

  /// For foldables: the id of the other screen (cover ↔ inner).
  final String? foldPartner;
  final String? note;

  bool get isDesktop => group == DeviceGroup.desktop;

  Size sizeFor(bool landscape) => landscape && !isDesktop ? Size(size.height, size.width) : size;

  EdgeInsets insetsFor(bool landscape) {
    if (isDesktop) return EdgeInsets.zero;
    if (!landscape) return EdgeInsets.only(top: safeTop, bottom: safeBottom);
    // Landscape: the notch/island moves to the side, the home bar stays at the bottom.
    final side = style == FrameStyle.iphoneIsland ? safeTop : 0.0;
    return EdgeInsets.only(left: side, right: side, top: style == FrameStyle.androidPunch ? 24 : 0, bottom: safeBottom > 0 ? 21 : 0);
  }
}

const previewDevices = <PreviewDevice>[
  // ── Phones ──────────────────────────────────────────────────────────
  PreviewDevice(id: 'iphone-se', name: 'iPhone SE', group: DeviceGroup.phone, size: Size(375, 667), style: FrameStyle.iphoneClassic, safeTop: 20, radius: 0),
  PreviewDevice(id: 'iphone-15', name: 'iPhone 15 Pro', group: DeviceGroup.phone, size: Size(393, 852), style: FrameStyle.iphoneIsland, safeTop: 59, safeBottom: 34, radius: 55),
  PreviewDevice(id: 'iphone-15-max', name: 'iPhone 15 Pro Max', group: DeviceGroup.phone, size: Size(430, 932), style: FrameStyle.iphoneIsland, safeTop: 59, safeBottom: 34, radius: 55),
  PreviewDevice(id: 'galaxy-s24', name: 'Galaxy S24', group: DeviceGroup.phone, size: Size(360, 780), style: FrameStyle.androidPunch, safeTop: 32, safeBottom: 16, radius: 34),
  PreviewDevice(id: 'pixel-8-pro', name: 'Pixel 8 Pro', group: DeviceGroup.phone, size: Size(412, 892), style: FrameStyle.androidPunch, safeTop: 36, safeBottom: 16, radius: 40),

  // ── Foldables ───────────────────────────────────────────────────────
  PreviewDevice(
      id: 'fold1-cover', name: 'Galaxy Fold · cover', group: DeviceGroup.foldable, size: Size(280, 653), style: FrameStyle.androidPunch,
      safeTop: 28, safeBottom: 12, radius: 22, note: 'Narrowest supported screen (1st-gen Fold)'),
  PreviewDevice(
      id: 'zfold5-cover', name: 'Galaxy Z Fold5 · cover', group: DeviceGroup.foldable, size: Size(344, 882), style: FrameStyle.androidPunch,
      safeTop: 30, safeBottom: 14, radius: 30, foldPartner: 'zfold5-inner'),
  PreviewDevice(
      id: 'zfold5-inner', name: 'Galaxy Z Fold5 · open', group: DeviceGroup.foldable, size: Size(690, 829), style: FrameStyle.androidPunch,
      safeTop: 30, safeBottom: 14, radius: 26, foldPartner: 'zfold5-cover'),
  PreviewDevice(
      id: 'pixelfold-cover', name: 'Pixel Fold · cover', group: DeviceGroup.foldable, size: Size(412, 701), style: FrameStyle.androidPunch,
      safeTop: 30, safeBottom: 14, radius: 30, foldPartner: 'pixelfold-inner'),
  PreviewDevice(
      id: 'pixelfold-inner', name: 'Pixel Fold · open', group: DeviceGroup.foldable, size: Size(701, 841), style: FrameStyle.androidPunch,
      safeTop: 30, safeBottom: 14, radius: 24, foldPartner: 'pixelfold-cover'),
  PreviewDevice(id: 'zflip5', name: 'Galaxy Z Flip5', group: DeviceGroup.foldable, size: Size(412, 1004), style: FrameStyle.androidPunch, safeTop: 34, safeBottom: 16, radius: 34),

  // ── Tablets ─────────────────────────────────────────────────────────
  PreviewDevice(id: 'ipad-mini', name: 'iPad mini', group: DeviceGroup.tablet, size: Size(744, 1133), style: FrameStyle.tablet, safeTop: 24, safeBottom: 20, radius: 22),
  PreviewDevice(id: 'ipad-air', name: 'iPad Air 11"', group: DeviceGroup.tablet, size: Size(820, 1180), style: FrameStyle.tablet, safeTop: 24, safeBottom: 20, radius: 18),
  PreviewDevice(id: 'ipad-pro-13', name: 'iPad Pro 13"', group: DeviceGroup.tablet, size: Size(1032, 1376), style: FrameStyle.tablet, safeTop: 24, safeBottom: 20, radius: 18),
  PreviewDevice(id: 'tab-s9', name: 'Galaxy Tab S9', group: DeviceGroup.tablet, size: Size(800, 1280), style: FrameStyle.tablet, safeTop: 24, safeBottom: 16, radius: 16),

  // ── Desktop ─────────────────────────────────────────────────────────
  PreviewDevice(id: 'desk-small', name: 'Small window', group: DeviceGroup.desktop, size: Size(1024, 700), style: FrameStyle.desktop),
  PreviewDevice(id: 'macbook', name: 'MacBook Air 13"', group: DeviceGroup.desktop, size: Size(1280, 800), style: FrameStyle.desktop),
  PreviewDevice(id: 'desktop-hd', name: 'Desktop 1440', group: DeviceGroup.desktop, size: Size(1440, 900), style: FrameStyle.desktop),
];

PreviewDevice deviceById(String id) => previewDevices.firstWhere((d) => d.id == id);

/// The gallery shows one of each kind at once.
const galleryDeviceIds = ['fold1-cover', 'iphone-15', 'zfold5-inner', 'ipad-air', 'macbook'];

/// Mock API scenarios (same key prefixes as the extension's mock).
enum Scenario {
  signedOut('Signed out (login)', null),
  allPlans('All plans', 'demo0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV'),
  single('Single Residential (Full Geo)', 'single0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQR'),
  country('Country Geo plan', 'country0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ'),
  nonGeo('Non-Geo plan', 'nongeo0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQR'),
  isp('ISP plan', 'isp0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVW'),
  none('No active plans', 'none0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV');

  const Scenario(this.label, this.key);
  final String label;
  final String? key;
}
