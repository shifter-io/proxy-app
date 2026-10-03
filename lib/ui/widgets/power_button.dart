import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../theme/tokens.dart';
import 'icons.dart';
import 'ambient_motion.dart';

/// The big connect button. Blue at rest, an orbiting arc while connecting,
/// green with expanding rings once connected (`sf-ring`).
class PowerButton extends StatefulWidget {
  const PowerButton({super.key, required this.status, required this.onTap, this.size = 132});
  final ConnectionStatus status;
  final VoidCallback onTap;
  final double size;

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton> with TickerProviderStateMixin {
  late final _orbit = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  bool _down = false;

  /// Clock time the rings started, so they always start from the button.
  double _ringsFrom = 0;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(PowerButton old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) {
      _sync();
      if (widget.status == ConnectionStatus.connected) HapticFeedback.mediumImpact();
    }
  }

  void _sync() {
    if (widget.status == ConnectionStatus.connected) _ringsFrom = ambientClock.value;
    // The connecting spinner is progress, not decoration: full frame rate.
    widget.status == ConnectionStatus.connecting ? _orbit.repeat() : _orbit.stop();
  }

  @override
  void dispose() {
    _orbit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final connected = widget.status == ConnectionStatus.connected;
    final connecting = widget.status == ConnectionStatus.connecting;
    final error = widget.status == ConnectionStatus.error;
    final tone = connected
        ? Sf.success
        : error
        ? Sf.danger
        : Sf.accent;

    return Semantics(
      button: true,
      label: connected || connecting ? 'Disconnect' : 'Connect',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: () {
            HapticFeedback.lightImpact();
            widget.onTap();
          },
          child: SizedBox(
            width: s * 1.7,
            height: s * 1.7,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Expanding rings while connected.
                RepaintBoundary(
                  child: connected
                      ? ListenableBuilder(
                          listenable: ambientClock,
                          builder: (_, _) => CustomPaint(
                            size: Size.square(s * 1.7),
                            painter: _RingsPainter(
                              progress: ((ambientClock.value - _ringsFrom) / 2.4) % 1,
                              radius: s / 2,
                              color: Sf.success,
                            ),
                          ),
                        )
                      : SizedBox.square(dimension: s * 1.7),
                ),
                // Soft glow that breathes.
                ListenableBuilder(
                  listenable: ambientClock,
                  builder: (_, _) {
                    final b = breathe(ambientClock.value, 2.6);
                    return TweenAnimationBuilder<Color?>(
                      tween: ColorTween(end: tone),
                      duration: const Duration(milliseconds: 600),
                      builder: (_, c, _) => Container(
                        width: s,
                        height: s,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: c!.withValues(alpha: 0.05 + 0.03 * b),
                              spreadRadius: 8 + 4 * b,
                            ),
                            BoxShadow(
                              color: c.withValues(alpha: 0.30 + 0.15 * b),
                              blurRadius: 44,
                              spreadRadius: -8,
                              offset: const Offset(0, 14),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                AnimatedScale(
                  scale: _down ? 0.94 : 1,
                  duration: Duration(milliseconds: _down ? 100 : 380),
                  curve: _down ? Curves.easeOut : Curves.elasticOut,
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: tone),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeInOut,
                    builder: (_, c, _) => Container(
                      width: s,
                      height: s,
                      // Opaque base so the glow behind never shows through the face.
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Sf.bgElevated),
                      foregroundDecoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: c!.withValues(alpha: connected ? 0.5 : 0.32), width: 1.2),
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            center: const Alignment(0, -0.3),
                            radius: 0.75,
                            colors: connected
                                ? [c.withValues(alpha: 0.32), c.withValues(alpha: 0.08)]
                                : [c.withValues(alpha: 0.24), const Color(0xE6131927)],
                          ),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (connecting)
                              AnimatedBuilder(
                                animation: _orbit,
                                builder: (_, _) => CustomPaint(
                                  size: Size.square(s),
                                  painter: _OrbitPainter(t: _orbit.value, color: Sf.accentLight),
                                ),
                              ),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              transitionBuilder: (w, a) => ScaleTransition(
                                scale: Tween(begin: 0.6, end: 1.0).animate(a),
                                child: FadeTransition(opacity: a, child: w),
                              ),
                              child: SfIcon(
                                SfIcons.power,
                                key: ValueKey(connected),
                                size: s * 0.34,
                                strokeWidth: 2,
                                color: connected
                                    ? Sf.successLight
                                    : connecting
                                    ? Sf.accentLight.withValues(alpha: 0.6)
                                    : Sf.accentLight,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({required this.progress, required this.radius, required this.color});
  final double progress;
  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress < 0) return;
    final center = size.center(Offset.zero);
    for (final offset in const [0.0, 0.5]) {
      final p = (progress + offset) % 1.0;
      final e = Sf.easeOutExpo.transform(p);
      final scale = 0.9 + 0.65 * e;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: 0.55 * (1 - e));
      canvas.drawCircle(center, radius * scale, paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter old) => old.progress != progress;
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter({required this.t, required this.color});
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(5);
    final start = t * 2 * math.pi - math.pi / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [color.withValues(alpha: 0), color, color.withValues(alpha: 0)],
        stops: const [0, 0.45, 0.4501],
        transform: GradientRotation(start),
      ).createShader(rect);
    // A comet: transparent tail → bright head, chasing around the button.
    canvas.drawArc(rect, start, math.pi * 0.9, false, paint);
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.t != t;
}
