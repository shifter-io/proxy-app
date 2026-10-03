// The connected home screen on mock data (no network, no system proxy), for
// measuring what the UI costs while idle:
//   flutter build macos --release -t tool/bench/ui_idle_main.dart
import 'package:flutter/material.dart';
import 'package:shifter_app/shifter_app.dart';

void main() => runApp(const ShifterApp(demoKey: 'single0000000000000000000000000000000000', demoConnected: true));
