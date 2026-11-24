import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/data/models.dart';
import 'package:shifter_app/i18n/i18n.dart';

void main() {
  test('the picked language is stored with the settings and survives a restart', () {
    const s = ProxySettings();
    expect(s.language, isNull, reason: 'new installs follow the device');
    final picked = s.copyWith(language: () => 'de');
    expect(ProxySettings.fromJson(picked.toJson()).language, 'de');
    final automatic = picked.copyWith(language: () => null);
    expect(ProxySettings.fromJson(automatic.toJson()).language, isNull);
    // Other settings are untouched by the language.
    expect(picked.copyWith(strict: true).language, 'de');
  });

  test('every language has a name in its own language', () {
    for (final c in I18n.codes) {
      expect(I18n.names[c], isNotNull, reason: c);
    }
    expect(I18n.names['de'], 'Deutsch');
    expect(I18n.pick(const [Locale('ro')]), 'en');
  });
}
