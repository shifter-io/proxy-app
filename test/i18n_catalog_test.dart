// Every user-facing string must be in every language: a tr()/trf() key with
// no entry in a catalog fails here, the same check the website runs.
// Add missing ones with tool/i18n/translate.mjs (see its header).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:shifter_app/i18n/i18n.dart';

final _call = RegExp(r'''\btrf?\(\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")''');
final _placeholder = RegExp(r'\{[a-zA-Z0-9_]+\}');
// tr(cond ? 'A' : 'B'): both literals are keys.
final _ternary = RegExp(r"\btrf?\(\s*[^'\x22]{1,120}?\?\s*'((?:[^'\\]|\\.)*)'\s*:\s*'((?:[^'\\]|\\.)*)'");

String _unescape(String s) =>
    s.replaceAll(r"\'", "'").replaceAll(r'\"', '"').replaceAll(r'\$', r'$').replaceAll(r'\n', '\n').replaceAll(r'\\', r'\');

Set<String> _keys() {
  final keys = <String>{};
  for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart') || f.path.contains('/preview/')) continue;
    final text = f.readAsStringSync();
    for (final m in _call.allMatches(text)) {
      keys.add(_unescape(m.group(1) ?? m.group(2)!));
    }
    for (final m in _ternary.allMatches(text)) {
      keys..add(_unescape(m.group(1)!))..add(_unescape(m.group(2)!));
    }
  }
  final xml = File('android/app/src/main/res/values/strings.xml').readAsStringSync();
  keys.addAll(RegExp(r'<string name="[^"]+">(.*?)</string>').allMatches(xml).map((m) => _unescape(m.group(1)!)));
  keys.addAll(File('tool/i18n/extra_keys.txt').readAsLinesSync().where((l) => l.trim().isNotEmpty && !l.startsWith('#')));
  final geo = jsonDecode(File('assets/geo/catalog.json').readAsStringSync()) as Map<String, dynamic>;
  for (final c in geo['countries'] as List) {
    keys.add((c as Map<String, dynamic>)['name'] as String);
  }
  return keys;
}

List<String> _placeholders(String s) => _placeholder.allMatches(s).map((m) => m.group(0)!).toList()..sort();

void main() {
  final keys = _keys();

  test('the app has user-facing strings to translate', () {
    expect(keys.length, greaterThan(100));
  });

  for (final code in I18n.codes.where((c) => c != 'en')) {
    test('$code has every key, with the same placeholders and no em dashes', () {
      final catalog = (jsonDecode(File('assets/i18n/$code.json').readAsStringSync()) as Map<String, dynamic>).cast<String, String>();
      final missing = keys.where((k) => !catalog.containsKey(k)).toList();
      expect(missing, isEmpty, reason: '$code is missing ${missing.length} keys, first: ${missing.take(5).toList()}');
      for (final k in keys) {
        expect(_placeholders(catalog[k]!), _placeholders(k), reason: '$code placeholders differ for "$k"');
        expect(catalog[k]!.contains('—') || catalog[k]!.contains('–'), isFalse, reason: '$code uses a dash in "$k"');
      }
    });
  }

  test('device languages map to the website languages', () {
    expect(I18n.pick(const [Locale('de', 'AT')]), 'de');
    expect(I18n.pick(const [Locale('zh', 'TW')]), 'zh-Hans');
    expect(I18n.pick(const [Locale('pt', 'PT')]), 'pt-BR');
    expect(I18n.pick(const [Locale('ro'), Locale('fr')]), 'fr');
    expect(I18n.pick(const [Locale('ro')]), 'en');
  });

  test('tr falls back to English and trf fills placeholders', () {
    I18n.useCatalog('de', {'Connected': 'Verbunden', 'In {n} days': 'In {n} Tagen'});
    addTearDown(() => I18n.useCatalog('en', const {}));
    expect(tr('Connected'), 'Verbunden');
    expect(tr('Not translated'), 'Not translated');
    expect(trf('In {n} days', {'n': 3}), 'In 3 Tagen');
  });

  test('native messages "<lead>: <reason>" translate both halves', () {
    I18n.useCatalog('de', {
      "The connection didn't start: {reason}": 'Die Verbindung wurde nicht gestartet: {reason}',
      "Couldn't reach Shifter. Check your connection and try again.": 'Shifter ist nicht erreichbar.',
    });
    addTearDown(() => I18n.useCatalog('en', const {}));
    expect(trNative("The connection didn't start: Couldn't reach Shifter. Check your connection and try again."),
        'Die Verbindung wurde nicht gestartet: Shifter ist nicht erreichbar.');
    expect(trNative('Something new'), 'Something new');
  });
}
