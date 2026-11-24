import 'package:flutter/material.dart';

import 'installation_analytics.dart';

class AnalyticsScope extends InheritedNotifier<InstallationAnalytics> {
  const AnalyticsScope({super.key, super.notifier, required super.child});

  static InstallationAnalytics? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AnalyticsScope>()?.notifier;
}

class AnalyticsControl extends StatelessWidget {
  const AnalyticsControl({super.key});

  @override
  Widget build(BuildContext context) {
    final analytics = AnalyticsScope.of(context);
    if (analytics == null || !analytics.available || !analytics.ready) {
      return const SizedBox.shrink();
    }
    return SwitchListTile.adaptive(
      title: const Text('Share app analytics'),
      subtitle: const Text(
        'Send launch and update events with app version and platform.',
      ),
      value: analytics.enabled,
      onChanged: analytics.setEnabled,
    );
  }
}
