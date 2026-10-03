import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether decorative loops (background halo, button glow, rings) may run.
/// False while the window isn't the active one: nobody is looking, and each
/// frame redraws the whole window. Driven by [AmbientMotionScope].
final ambientMotion = ValueNotifier<bool>(true);

/// Follows the app lifecycle into [ambientMotion].
class AmbientMotionScope extends StatefulWidget {
  const AmbientMotionScope({super.key, required this.child});
  final Widget child;

  @override
  State<AmbientMotionScope> createState() => _AmbientMotionScopeState();
}

class _AmbientMotionScopeState extends State<AmbientMotionScope> {
  late final _listener = AppLifecycleListener(
    onStateChange: (s) => ambientMotion.value = s == AppLifecycleState.resumed,
  );

  @override
  void initState() {
    super.initState();
    _listener; // start listening
  }

  @override
  void dispose() {
    _listener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Seconds of decorative motion, for loops that don't need every display
/// refresh (the halo moves a few pixels a second; the display may refresh
/// 120 times a second). Ticks 30 times a second, only while someone listens
/// and [ambientMotion] allows; paused, it keeps its value, so loops freeze
/// on their current frame.
final ambientClock = AmbientClock();

class AmbientClock extends ChangeNotifier implements ValueListenable<double> {
  AmbientClock() {
    ambientMotion.addListener(_sync);
  }

  static const _frame = Duration(microseconds: 1000000 ~/ 30);
  final _watch = Stopwatch();
  Timer? _timer;

  @override
  double get value => _watch.elapsedMicroseconds / 1e6;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _sync();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    _sync();
  }

  void _sync() {
    final run = ambientMotion.value && hasListeners;
    if (run && _timer == null) {
      _watch.start();
      _timer = Timer.periodic(_frame, (_) => notifyListeners());
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _watch.stop();
    }
  }
}

/// 0→1→0 over [period] seconds, eased: a breathing loop on [ambientClock].
double breathe(double seconds, double period) {
  final p = (seconds / period) % 2;
  return Curves.easeInOut.transform(p < 1 ? p : 2 - p);
}
