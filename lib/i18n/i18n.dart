import 'dart:convert';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;

/// App translations. The English string is the catalog key, the same
/// convention as the Shifter website and panel: wrap a user-facing string in
/// [tr] (or [trf] when it has `{placeholders}`), add the English key to every
/// catalog in `assets/i18n/<locale>.json`, and `test/i18n_catalog_test.dart`
/// fails until each locale has it.
///
/// Languages: the website's eight. The device language picks one at start
/// (any Chinese gets Simplified Chinese, any Portuguese gets Brazilian
/// Portuguese) and the app follows the device when it changes; anything else
/// falls back to English, which needs no catalog.
abstract final class I18n {
  /// Catalog codes, in the website's order. `en` has no catalog.
  static const codes = ['en', 'es', 'zh-Hans', 'de', 'fr', 'ja', 'ko', 'pt-BR'];

  static const supportedLocales = [
    Locale('en'),
    Locale('es'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale('de'),
    Locale('fr'),
    Locale('ja'),
    Locale('ko'),
    Locale('pt', 'BR'),
  ];

  /// Each language name in its own language, for the picker in Settings.
  static const names = {
    'en': 'English',
    'es': 'Español',
    'zh-Hans': '简体中文',
    'de': 'Deutsch',
    'fr': 'Français',
    'ja': '日本語',
    'ko': '한국어',
    'pt-BR': 'Português (Brasil)',
  };

  /// Flag shown next to each language in the picker (assets/flags/<cc>.png).
  static const flags = {
    'en': 'us',
    'es': 'es',
    'zh-Hans': 'cn',
    'de': 'de',
    'fr': 'fr',
    'ja': 'jp',
    'ko': 'kr',
    'pt-BR': 'br',
  };

  /// Tells the app root to rebuild after the language changes.
  static final changes = ValueNotifier<String>('en');

  static String _code = 'en';
  static Map<String, String> _catalog = const {};

  /// The active catalog code (`en`, `de`, `zh-Hans`...).
  static String get code => _code;

  /// The active locale, for MaterialApp.
  static Locale get locale => supportedLocales[codes.indexOf(_code)];

  /// The catalog code for a device locale, or null when we don't have it.
  static String? codeFor(Locale l) {
    switch (l.languageCode) {
      case 'zh':
        return 'zh-Hans';
      case 'pt':
        return 'pt-BR';
      default:
        return codes.contains(l.languageCode) ? l.languageCode : null;
    }
  }

  /// First of the device's preferred languages that we have, else English.
  static String pick(List<Locale> preferred) {
    for (final l in preferred) {
      final c = codeFor(l);
      if (c != null) return c;
    }
    return 'en';
  }

  /// Loads the catalog for the device language (or [code] when given).
  /// Returns true when the language changed.
  static Future<bool> load({String? code, List<Locale>? preferred}) async {
    final next = code ?? pick(preferred ?? PlatformDispatcher.instance.locales);
    if (next == _code && (next == 'en' || _catalog.isNotEmpty)) return false;
    var catalog = const <String, String>{};
    if (next != 'en') {
      try {
        final raw = jsonDecode(await rootBundle.loadString('assets/i18n/$next.json')) as Map<String, dynamic>;
        catalog = raw.map((k, v) => MapEntry(k, v as String));
      } catch (_) {
        // A missing or broken catalog shows English rather than failing.
      }
    }
    _code = next;
    _catalog = catalog;
    changes.value = next;
    return true;
  }

  /// Uses [catalog] directly (tests).
  static void useCatalog(String code, Map<String, String> catalog) {
    _code = code;
    _catalog = catalog;
  }
}

/// The translation of [en] in the active language (English when missing).
String tr(String en) => I18n._catalog[en] ?? en;

/// [tr] with `{name}` placeholders filled from [args].
String trf(String en, Map<String, Object?> args) {
  var s = tr(en);
  args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}
