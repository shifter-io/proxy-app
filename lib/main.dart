import 'package:flutter/material.dart';

import 'data/models.dart';
import 'data/store.dart';
import 'i18n/i18n.dart';
import 'shifter_app.dart';

/// The real app: phones, tablets and desktop all start here. Resize the
/// desktop window to see the compact → medium → expanded layouts.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The language picked in Settings, else the device language, before the first frame.
  final saved = await PersistentStore().readSettings().catchError((_) => const ProxySettings());
  await I18n.load(code: saved.language);
  runApp(const ShifterApp(live: true));
}
