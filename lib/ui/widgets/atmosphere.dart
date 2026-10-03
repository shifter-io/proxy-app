import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'ambient_motion.dart';

/// The panel's `.sf-auth-atmosphere`: a drifting blue halo over a faint grid
/// that fades out downwards. Turns green while connected.
class Atmosphere extends StatefulWidget {
  const Atmosphere({super.key, this.connected = false, this.intensity = 1});
  final bool connected;
  final double intensity;

  @override
  State<Atmosphere> createState() => _AtmosphereState();
}

class _AtmosphereState extends State<Atmosphere> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 28));

  void _sync() => syncLoop(_c);

  @override
  void initState() {
    super.initState();
    ambientMotion.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    ambientMotion.removeListener(_sync);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: widget.connected ? Sf.success : Sf.accent),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeInOut,
        builder: (_, color, _) => AnimatedBuilder(
          animation: _c,
          builder: (_, _) => CustomPaint(
            painter: _AtmospherePainter(
              t: reduceMotion ? 0 : _c.value,
              color: color ?? Sf.accent,
              intensity: widget.intensity * (widget.connected ? 0.85 : 1),
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

class _AtmospherePainter extends CustomPainter {
  _AtmospherePainter({required this.t, required this.color, required this.intensity});
  final double t;
  final Color color;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    // sf-blob-1: translate(0,0) → (40,-30) scale 1.05 → (-30,20) scale .96
    final a = t * 2 * math.pi;
    final dx = 36 * math.sin(a) - 12 * math.sin(2 * a);
    final dy = -24 * math.sin(a + 0.6) + 10 * math.cos(2 * a);
    final scale = 1 + 0.05 * math.sin(a * 1.5);

    final w = math.max(size.width * 1.25, 520.0) * scale;
    final h = math.min(w * 0.7, size.height * 0.75);
    final center = Offset(size.width * 0.42 + dx, -h * 0.12 + dy);
    // Elliptical halo: draw a radial gradient in a horizontally stretched space.
    final radius = h * 0.62;
    final paint = Paint()
      ..shader = ui.Gradient.radial(
        Offset.zero,
        radius,
        [color.withValues(alpha: 0.30 * intensity), color.withValues(alpha: 0.10 * intensity), color.withValues(alpha: 0)],
        const [0, 0.45, 1],
      );
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(w / h, 1);
    canvas.drawCircle(Offset.zero, radius, paint);
    canvas.restore();

    // Grid, 32px, masked by a radial fade from the top.
    final gridH = math.min(size.height * 0.6, 520.0);
    final gridRect = Rect.fromLTWH(0, 0, size.width, gridH);
    canvas.saveLayer(gridRect, Paint());
    final line = Paint()
      ..color = const Color(0x0AFFFFFF)
      ..strokeWidth = 1;
    for (double x = (size.width / 2) % 32; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, gridH), line);
    }
    for (double y = 0; y < gridH; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    final mask = Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = ui.Gradient.radial(
        Offset(size.width / 2, 0),
        gridH,
        [const Color(0xFFFFFFFF), const Color(0x99FFFFFF), const Color(0x00FFFFFF)],
        const [0, 0.4, 1],
      );
    canvas.drawRect(gridRect, mask);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AtmospherePainter old) => old.t != t || old.color != color || old.intensity != intensity;
}
