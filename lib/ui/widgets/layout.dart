import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'atmosphere.dart';
import 'icons.dart';
import 'primitives.dart';

/// Width classes, Material 3 window size classes.
///  compact   < 600   phones, foldable cover screens (down to 280 wide)
///  medium    < 1024  small tablets, unfolded foldables, tablet portrait
///  expanded  ≥ 1024  tablet landscape, desktop
enum SizeClass { compact, medium, expanded }

extension LayoutX on BuildContext {
  Size get screenSize => MediaQuery.sizeOf(this);
  SizeClass get sizeClass {
    final w = screenSize.width;
    if (w < 600) return SizeClass.compact;
    if (w < 1024) return SizeClass.medium;
    return SizeClass.expanded;
  }

  /// Foldable cover screens and the smallest phones (Galaxy Fold cover is 280dp).
  bool get isNarrow => screenSize.width < 340;

  /// Horizontal page padding that breathes with the screen width.
  double get pagePadding {
    final w = screenSize.width;
    if (w < 340) return 14;
    if (w < 400) return 18;
    if (w < 600) return 22;
    return 28;
  }
}

/// Screen chrome: optional top bar, scrollable body, optional pinned footer
/// and the brand atmosphere behind everything.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    this.header,
    required this.body,
    this.footer,
    this.atmosphere = false,
    this.connected = false,
    this.background = Sf.bgDeepest,
  });
  final Widget? header;
  final Widget body;
  final Widget? footer;
  final bool atmosphere;
  final bool connected;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      child: Stack(children: [
        if (atmosphere) Positioned.fill(child: Atmosphere(connected: connected)),
        Column(children: [
          ?header,
          Expanded(child: body),
          ?footer,
        ]),
      ]),
    );
  }
}

/// 56px top bar with safe-area padding (`TopBar` in the extension).
class SfTopBar extends StatelessWidget {
  const SfTopBar({super.key, this.title, this.onBack, this.leading, this.actions = const [], this.border = true, this.large = false});
  final String? title;
  final VoidCallback? onBack;
  final Widget? leading;
  final List<Widget> actions;
  final bool border;

  /// Wide layouts: bigger title, no back button, more padding.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final pad = large ? 28.0 : (context.isNarrow ? 6.0 : 10.0);
    return Container(
      padding: EdgeInsets.only(top: top, left: pad, right: pad),
      decoration: BoxDecoration(
        color: Sf.bgDeepest.withValues(alpha: large ? 0 : 0.72),
        border: border && !large ? const Border(bottom: BorderSide(color: Sf.borderSubtle)) : null,
      ),
      child: SizedBox(
        height: large ? 76 : 58,
        child: Row(children: [
          if (onBack != null) SfIconButton(icon: SfIcons.arrowLeft, tooltip: 'Back', onTap: onBack),
          if (onBack != null && title != null) const SizedBox(width: 4),
          if (leading != null) Expanded(child: leading!),
          if (title != null)
            Expanded(
              child: SfSwitcher(
                axis: Axis.horizontal,
                child: Align(
                  key: ValueKey(title),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: large ? SfText.title : SfText.heading.copyWith(fontSize: 16.5),
                  ),
                ),
              ),
            ),
          if (title == null && leading == null) const Spacer(),
          ...actions,
        ]),
      ),
    );
  }
}

/// Centers content and caps its width on big screens.
class MaxWidth extends StatelessWidget {
  const MaxWidth({super.key, required this.child, this.maxWidth = 640});
  final Widget child;
  final double maxWidth;
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
    );
  }
}

/// Page route used on phones: iOS-style slide with a parallax on the page
/// underneath, plus a fade so dark-on-dark edges don't look harsh.
class SfPageRoute<T> extends PageRouteBuilder<T> {
  SfPageRoute({required WidgetBuilder builder})
      : super(
          transitionDuration: const Duration(milliseconds: 420),
          reverseTransitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (context, _, _) => builder(context),
          transitionsBuilder: (context, animation, secondary, child) {
            final a = CurvedAnimation(parent: animation, curve: Sf.easeOutExpo, reverseCurve: Curves.easeInCubic);
            final s = CurvedAnimation(parent: secondary, curve: Sf.easeOutExpo, reverseCurve: Curves.easeInCubic);
            return SlideTransition(
              position: Tween(begin: Offset.zero, end: const Offset(-0.25, 0)).animate(s),
              child: FadeTransition(
                opacity: Tween(begin: 1.0, end: 0.6).animate(s),
                child: SlideTransition(
                  position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(a),
                  child: FadeTransition(
                    opacity: Tween(begin: 0.4, end: 1.0).animate(a),
                    child: DecoratedBox(
                      decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Color(0x80000000), blurRadius: 30)]),
                      child: child,
                    ),
                  ),
                ),
              ),
            );
          },
        );
}
