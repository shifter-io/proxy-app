import 'package:flutter/material.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'devices.dart';

/// Draws a device (bezel, status bar, island / punch hole, home indicator or
/// a desktop window) and runs [child] inside it with the device's
/// MediaQuery, so the app lays out exactly as it would on that screen.
/// Size and insets animate, so rotating or folding reflows the app live.
class DeviceFrame extends StatelessWidget {
  const DeviceFrame({super.key, required this.device, required this.landscape, required this.child});
  final PreviewDevice device;
  final bool landscape;
  final Widget child;

  static const _chromeH = 30.0;

  double get bezel => switch (device.group) {
        DeviceGroup.phone || DeviceGroup.foldable => device.style == FrameStyle.iphoneClassic ? 14 : 11,
        DeviceGroup.tablet => 16,
        DeviceGroup.desktop => 1,
      };

  /// Outer size including bezel / window chrome (for layout by the studio).
  static Size outerSize(PreviewDevice d, bool landscape) {
    final f = DeviceFrame(device: d, landscape: landscape, child: const SizedBox());
    final s = d.sizeFor(landscape);
    final extraH = d.isDesktop ? _chromeH : 0.0;
    final classic = d.style == FrameStyle.iphoneClassic && !landscape ? 120.0 : 0.0;
    return Size(s.width + f.bezel * 2, s.height + f.bezel * 2 + extraH + classic);
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Size?>(
      tween: SizeTween(end: device.sizeFor(landscape)),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeInOutCubic,
      builder: (context, size, _) => TweenAnimationBuilder<EdgeInsets?>(
        tween: EdgeInsetsTween(end: device.insetsFor(landscape)),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeInOutCubic,
        builder: (context, insets, _) => device.isDesktop ? _desktop(context, size!) : _mobile(context, size!, insets!),
      ),
    );
  }

  Widget _screen(BuildContext context, Size size, EdgeInsets insets) {
    final mq = MediaQuery.of(context).copyWith(
      size: size,
      padding: insets,
      viewPadding: insets,
      viewInsets: EdgeInsets.zero,
      textScaler: TextScaler.noScaling,
    );
    return SizedBox(
      width: size.width,
      height: size.height,
      child: MediaQuery(data: mq, child: child),
    );
  }

  Widget _mobile(BuildContext context, Size size, EdgeInsets insets) {
    final r = device.radius;
    final classic = device.style == FrameStyle.iphoneClassic && !landscape;
    final screen = ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: Stack(children: [
        _screen(context, size, insets),
        // Status bar.
        if (insets.top > 0)
          Positioned(
            top: 0,
            left: insets.left,
            right: insets.right,
            height: insets.top,
            child: IgnorePointer(child: _StatusBar(island: device.style == FrameStyle.iphoneIsland && !landscape, height: insets.top)),
          ),
        if (device.style == FrameStyle.iphoneIsland && !landscape)
          Positioned(
            top: 11,
            left: 0,
            right: 0,
            child: Center(
              child: Container(width: 124, height: 36, decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(20))),
            ),
          ),
        if (device.style == FrameStyle.androidPunch)
          landscape
              ? Positioned(top: 0, bottom: 0, left: 10, child: Center(child: _punch()))
              : Positioned(top: 10, left: 0, right: 0, child: Center(child: _punch())),
        // Home indicator / gesture bar.
        if (insets.bottom > 0)
          Positioned(
            bottom: 8,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: device.style == FrameStyle.androidPunch ? 110 : 134,
                  height: device.style == FrameStyle.androidPunch ? 4 : 5,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(9)),
                ),
              ),
            ),
          ),
        // Hinge shadow on unfolded foldables.
        if (device.group == DeviceGroup.foldable && device.id.endsWith('inner'))
          Positioned(
            top: 0,
            bottom: 0,
            left: size.width / 2 - 14,
            width: 28,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Colors.black.withValues(alpha: 0),
                    Colors.black.withValues(alpha: 0.10),
                    Colors.white.withValues(alpha: 0.025),
                    Colors.black.withValues(alpha: 0),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );

    return Container(
      padding: EdgeInsets.symmetric(horizontal: bezel, vertical: classic ? 60 + bezel : bezel),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(classic ? 46 : r + bezel),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A2F3A), Color(0xFF14171D), Color(0xFF242833)],
        ),
        border: Border.all(color: const Color(0xFF3A404D), width: 1),
        boxShadow: const [
          BoxShadow(color: Color(0xAA000000), blurRadius: 60, spreadRadius: -10, offset: Offset(0, 30)),
          BoxShadow(color: Color(0x14FFFFFF), blurRadius: 0, spreadRadius: 0.5),
        ],
      ),
      child: Stack(clipBehavior: Clip.none, children: [
        screen,
        if (classic)
          Positioned(
            bottom: -48 - bezel / 2,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0xFF3A404D), width: 2)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _punch() => Container(
        width: 11,
        height: 11,
        decoration: const BoxDecoration(color: Colors.black, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Color(0x33FFFFFF), spreadRadius: 0.5)]),
      );

  Widget _desktop(BuildContext context, Size size) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3A404D)),
        boxShadow: const [BoxShadow(color: Color(0xAA000000), blurRadius: 60, spreadRadius: -10, offset: Offset(0, 30))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: size.width,
            height: _chromeH,
            color: const Color(0xFF1B1F27),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              for (final c in const [Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840)])
                Container(margin: const EdgeInsets.only(right: 8), width: 12, height: 12, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              const Spacer(),
              const Text('Shifter', style: TextStyle(decoration: TextDecoration.none, fontFamily: kSans, fontSize: 12.5, color: Sf.textTertiary, fontWeight: FontWeight.w500)),
              const Spacer(),
              const SizedBox(width: 60),
            ]),
          ),
          _screen(context, size, EdgeInsets.zero),
        ]),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.island, required this.height});
  final bool island;
  final double height;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(decoration: TextDecoration.none, fontFamily: kSans, fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white, letterSpacing: -0.2);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: island ? 34 : 18),
      child: Align(
        alignment: island ? const Alignment(0, 0.05) : Alignment.center,
        child: Row(children: [
          const Text('9:41', style: style),
          const Spacer(),
          // Signal bars.
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final h in const [4.0, 6.5, 9.0, 11.5])
              Container(margin: const EdgeInsets.only(left: 1.6), width: 3, height: h, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(1))),
          ]),
          const SizedBox(width: 6),
          // Battery.
          Container(
            width: 24,
            height: 12,
            padding: const EdgeInsets.all(1.6),
            decoration: BoxDecoration(border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 1), borderRadius: BorderRadius.circular(3.5)),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: 0.8,
                child: Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(1.5))),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
