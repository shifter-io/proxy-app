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

/// Runs [controller] as a loop only while [ambientMotion] allows and [on].
/// A paused loop keeps its current frame.
void syncLoop(AnimationController controller, {bool on = true, bool reverse = false}) {
  if (on && ambientMotion.value) {
    if (!controller.isAnimating) controller.repeat(reverse: reverse);
  } else {
    controller.stop();
  }
}
