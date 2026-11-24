import 'package:flutter/material.dart';

import 'i18n/i18n.dart';
import 'shifter_app.dart';

/// The real app: phones, tablets and desktop all start here. Resize the
/// desktop window to see the compact → medium → expanded layouts.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The device language, before the first frame.
  await I18n.load();
  runApp(const ShifterApp(live: true));
}
