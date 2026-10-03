import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../state/app_controller.dart';
import 'isp_picker.dart';
import 'residential_picker.dart';

/// Picks the right targeting UI for the active membership. Keyed by plan so
/// switching plans resets the picker.
class LocationScreen extends StatelessWidget {
  const LocationScreen({super.key, this.onBack, required this.onApplied, this.embedded = false});
  final VoidCallback? onBack;
  final VoidCallback onApplied;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final m = AppScope.of(context).activeMembership;
    return switch (m) {
      null => const SizedBox.shrink(),
      IspMembership() => IspPicker(key: ValueKey(m.id), m: m, onBack: onBack, onApplied: onApplied, embedded: embedded),
      ResidentialMembership() => ResidentialPicker(key: ValueKey(m.id), m: m, onBack: onBack, onApplied: onApplied, embedded: embedded),
    };
  }
}
