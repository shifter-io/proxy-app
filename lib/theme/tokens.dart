import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

/// Shifter design tokens, copied 1:1 from the Shifter Panel / proxy extension
/// (tailwind.config.cjs + globals.css) so the app, panel, extension and
/// shifter.io share one visual language. Change them there first, then here.
abstract final class Sf {
  // ── Surfaces ──────────────────────────────────────────────────────────
  static const bgDeepest = Color(0xFF0B0E17);
  static const bgDeep = Color(0xFF060810);
  static const bgCard = Color(0xFF0F1320);
  static const bgCardHover = Color(0xFF141A2B);
  static const bgElevated = Color(0xFF131927);
  static const bgStripe = Color(0xFF0D111C);
  static const bgInput = Color(0xFF0C0F1A);

  // ── Borders ───────────────────────────────────────────────────────────
  static const borderSubtle = Color(0x0FFFFFFF); // 6%
  static const borderMedium = Color(0x1FFFFFFF); // 12%
  static const borderStrong = Color(0x2EFFFFFF); // 18%
  static const borderInput = Color(0x14FFFFFF); // 8%

  // ── Text ──────────────────────────────────────────────────────────────
  static const textPrimary = Color(0xFFF5F7FA);
  static const textSecondary = Color(0xFFB7BFD0);
  static const textTertiary = Color(0xFF8893A8);
  static const textMuted = Color(0xFF5C6680);
  static const textFaint = Color(0xFF3E4660);

  // ── Brand ─────────────────────────────────────────────────────────────
  static const accent = Color(0xFF2B7FFF);
  static const accentHover = Color(0xFF1554B0);
  static const accentLight = Color(0xFF5BA3FF);
  static const accentSoft = Color(0x142B7FFF); // 8%
  static const accentSofter = Color(0x0A2B7FFF); // 4%
  static const cyan = Color(0xFF06B6D4);
  static const purple = Color(0xFF9B6CFF);

  // ── Status ────────────────────────────────────────────────────────────
  static const success = Color(0xFF3DBA78);
  static const successLight = Color(0xFF62D399);
  static const warning = Color(0xFFE59A30);
  static const warningLight = Color(0xFFF0B461);
  static const danger = Color(0xFFEF4444);
  static const dangerLight = Color(0xFFFCA5A5);
  static const verified = Color(0xFF22C55E);

  static const barTrack = Color(0x0FFFFFFF);

  // ── Radii ─────────────────────────────────────────────────────────────
  static const rSm = 6.0;
  static const rMd = 8.0;
  static const r = 10.0;
  static const rCard = 14.0;

  // ── Shadows ───────────────────────────────────────────────────────────
  static const glow = [
    BoxShadow(color: Color(0x332B7FFF), spreadRadius: 1),
    BoxShadow(color: Color(0x592B7FFF), blurRadius: 32, spreadRadius: -8, offset: Offset(0, 8)),
  ];
  static const cardShadow = [
    BoxShadow(color: Color(0x99000000), blurRadius: 24, spreadRadius: -12, offset: Offset(0, 8)),
  ];
  static const overlayShadow = [
    BoxShadow(color: Color(0xB3000000), blurRadius: 64, spreadRadius: -16, offset: Offset(0, 24)),
  ];

  // ── Motion ────────────────────────────────────────────────────────────
  /// `cubic-bezier(0.16, 1, 0.3, 1)`: the panel's sf-slide-up / sf-ring ease.
  static const easeOutExpo = Cubic(0.16, 1, 0.3, 1);
  static const fast = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 250);
  static const slow = Duration(milliseconds: 500);
}

/// Pill tones, same as `.sf-pill-*` in the panel.
enum SfTone { success, warning, danger, info, neutral, purple }

class SfToneColors {
  const SfToneColors(this.bg, this.fg, this.border);
  final Color bg;
  final Color fg;
  final Color border;

  static SfToneColors of(SfTone tone) => switch (tone) {
        SfTone.success => const SfToneColors(Color(0x1A3DBA78), Sf.successLight, Color(0x383DBA78)),
        SfTone.warning => const SfToneColors(Color(0x1AE59A30), Sf.warningLight, Color(0x38E59A30)),
        SfTone.danger => const SfToneColors(Color(0x1AEF4444), Sf.dangerLight, Color(0x38EF4444)),
        SfTone.info => const SfToneColors(Color(0x1A2B7FFF), Sf.accentLight, Color(0x402B7FFF)),
        SfTone.neutral => const SfToneColors(Color(0x0AFFFFFF), Sf.textSecondary, Color(0x14FFFFFF)),
        SfTone.purple => const SfToneColors(Color(0x1F9B6CFF), Color(0xFFB89BFF), Color(0x3D9B6CFF)),
      };
}
