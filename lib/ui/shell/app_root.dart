import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../../theme/tokens.dart';
import '../screens/home_screen.dart';
import '../screens/location/location_screen.dart';
import '../screens/login_screen.dart';
import '../screens/plans_screen.dart';
import '../screens/settings_screen.dart';
import '../widgets/ambient_motion.dart';
import '../widgets/layout.dart';
import '../widgets/primitives.dart';
import 'wide_shell.dart';

/// Decides what the app shows: splash → login → plan choice → the shell.
/// The shell itself is responsive (phone stack vs. tablet/desktop layout).
class AppRoot extends StatefulWidget {
  const AppRoot({super.key});
  @override
  State<AppRoot> createState() => _AppRootState();
}

enum _Gate { splash, login, loadingPlans, choosePlan, compact, wide }

class _AppRootState extends State<AppRoot> {
  _Gate? _last;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final wide = context.sizeClass != SizeClass.compact;
    final gate = switch (app.phase) {
      AuthPhase.booting => _Gate.splash,
      AuthPhase.signedOut => _Gate.login,
      AuthPhase.signedIn when app.memberships == null && app.membershipsError == null => _Gate.loadingPlans,
      AuthPhase.signedIn when app.activeMembership == null => _Gate.choosePlan,
      _ => wide ? _Gate.wide : _Gate.compact,
    };

    // Anything pushed on top (location, settings…) belongs to the old state:
    // sign-out, plan loss, or a foldable being unfolded into the wide layout.
    if (_last != null && _last != gate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      });
    }
    _last = gate;

    final child = switch (gate) {
      _Gate.splash || _Gate.loadingPlans => const _Splash(key: ValueKey('splash')),
      _Gate.login => const LoginScreen(key: ValueKey('login')),
      _Gate.choosePlan => const PlansScreen(key: ValueKey('plans')),
      _Gate.compact => const _CompactShell(key: ValueKey('compact')),
      _Gate.wide => const WideShell(key: ValueKey('wide')),
    };

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 520),
      switchInCurve: Sf.easeOutExpo,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.985, end: 1.0).animate(a), child: c),
      ),
      child: child,
    );
  }
}

/// Phone: Home with pushed pages and a bottom-sheet plan switcher.
class _CompactShell extends StatelessWidget {
  const _CompactShell({super.key});

  @override
  Widget build(BuildContext context) {
    void push(WidgetBuilder b) => Navigator.of(context).push(CupertinoPageRoute(builder: b));
    return HomeScreen(
      onOpenLocation: () => push((ctx) => LocationScreen(onBack: () => Navigator.pop(ctx), onApplied: () => Navigator.pop(ctx))),
      onOpenSettings: () => push((ctx) => SettingsScreen(onBack: () => Navigator.pop(ctx))),
      onSwitchPlan: () => showPlanSwitcher(context),
    );
  }
}

class _Splash extends StatefulWidget {
  const _Splash({super.key});

  @override
  State<_Splash> createState() => _SplashState();
}

class _SplashState extends State<_Splash> {
  final _started = ambientClock.value;

  @override
  Widget build(BuildContext context) {
    const logo = SizedBox.square(dimension: 72, child: Glyph(size: 72));
    return Material(
      color: Sf.bgDeepest,
      child: Center(
        child: Semantics(
          label: 'Shifter',
          image: true,
          child: ExcludeSemantics(
            child: MediaQuery.disableAnimationsOf(context)
                ? logo
                : AnimatedBuilder(
                    animation: ambientClock,
                    child: logo,
                    builder: (context, child) {
                      // Start at the native logo's exact size and opacity,
                      // then gently breathe on the shared, lifecycle-aware clock.
                      final pulse = breathe(ambientClock.value - _started, 1.1);
                      return Transform.scale(
                        scale: 1 + 0.045 * pulse,
                        child: Opacity(opacity: 1 - 0.14 * pulse, child: child),
                      );
                    },
                  ),
          ),
        ),
      ),
    );
  }
}
