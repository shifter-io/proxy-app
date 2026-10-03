import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

const kSans = 'Geist';
const kMono = 'GeistMono';

/// Text styles used across the app. Sizes follow the extension, scaled up a
/// touch for touch screens (the popup was 380px wide at desktop density).
abstract final class SfText {
  static const _base = TextStyle(fontFamily: kSans, color: Sf.textPrimary, letterSpacing: -0.1, height: 1.3);

  static final display = _base.copyWith(fontSize: 28, fontWeight: FontWeight.w600, letterSpacing: -0.8, height: 1.15);
  static final title = _base.copyWith(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.55, height: 1.2);
  static final heading = _base.copyWith(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.35);
  static final bodyStrong = _base.copyWith(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: -0.2);
  static final body = _base.copyWith(fontSize: 14.5, fontWeight: FontWeight.w500);
  static final bodyMuted = _base.copyWith(fontSize: 13.5, color: Sf.textTertiary, height: 1.5, fontWeight: FontWeight.w400);
  static final small = _base.copyWith(fontSize: 12.5, color: Sf.textTertiary, fontWeight: FontWeight.w400);
  static final micro = _base.copyWith(fontSize: 11.5, color: Sf.textMuted, fontWeight: FontWeight.w400);

  /// `.sf-label`: uppercase micro label.
  static final label = _base.copyWith(
    fontSize: 10.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.5,
    color: Sf.textMuted,
  );

  static final mono = const TextStyle(
    fontFamily: kMono,
    color: Sf.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
    letterSpacing: 0,
  );
}

ThemeData buildShifterTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    fontFamily: kSans,
    scaffoldBackgroundColor: Sf.bgDeepest,
    canvasColor: Sf.bgDeepest,
    splashFactory: InkSparkle.splashFactory,
    colorScheme: const ColorScheme.dark(
      primary: Sf.accent,
      onPrimary: Colors.white,
      secondary: Sf.accentLight,
      surface: Sf.bgCard,
      onSurface: Sf.textPrimary,
      error: Sf.danger,
    ),
  );
  return base.copyWith(
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: Sf.accentLight,
      selectionColor: Sf.accent.withValues(alpha: 0.35),
      selectionHandleColor: Sf.accent,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.12)),
      radius: const Radius.circular(999),
      thickness: const WidgetStatePropertyAll(4),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: Sf.accent, borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontFamily: kSans, fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
      waitDuration: const Duration(milliseconds: 250),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Sf.bgElevated,
      contentTextStyle: const TextStyle(fontFamily: kSans, fontSize: 13.5, color: Sf.textPrimary),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Sf.r),
        side: const BorderSide(color: Sf.borderMedium),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}
