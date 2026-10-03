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

class _AtmosphereState extends State<Atmosphere> {
  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: widget.connected ? Sf.success : Sf.accent),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeInOut,
        builder: (_, color, _) {
          final intensity = widget.intensity * (widget.connected ? 0.85 : 1);
          _HaloPainter halo(double t) => _HaloPainter(t: t, color: color ?? Sf.accent, intensity: intensity);
          return Stack(fit: StackFit.expand, children: [
            RepaintBoundary(
              child: reduceMotion
                  ? CustomPaint(painter: halo(0))
                  : ListenableBuilder(
                      listenable: ambientClock,
                      builder: (_, _) => CustomPaint(painter: halo((ambientClock.value / 28) % 1)),
                    ),
            ),
            const RepaintBoundary(child: CustomPaint(painter: _GridPainter())),
          ]);
        },
      ),
    );
  }
}

/// sf-blob-1: a drifting elliptical halo.
class _HaloPainter extends CustomPainter {
  _HaloPainter({required this.t, required this.color, required this.intensity});
  final double t;
  final Color color;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    // translate(0,0) → (40,-30) scale 1.05 → (-30,20) scale .96
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
  }

  @override
  bool shouldRepaint(_HaloPainter old) => old.t != t || old.color != color || old.intensity != intensity;
}

/// 32 px grid fading out from the top centre. The fade is a gradient on the
/// lines themselves (same result as masking a layer, without one).
class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final gridH = math.min(size.height * 0.6, 520.0);
    final path = Path();
    for (double x = (size.width / 2) % 32; x < size.width; x += 32) {
      path
        ..moveTo(x, 0)
        ..lineTo(x, gridH);
    }
    for (double y = 0; y < gridH; y += 32) {
      path
        ..moveTo(0, y)
        ..lineTo(size.width, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = ui.Gradient.radial(
          Offset(size.width / 2, 0),
          gridH,
          const [Color(0x0AFFFFFF), Color(0x06FFFFFF), Color(0x00FFFFFF)],
          const [0, 0.4, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}
