import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../data/models.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'icons.dart';

// ── Interaction ─────────────────────────────────────────────────────────

/// Touch + pointer feedback used by every tappable surface: a soft press
/// scale (mobile feel), a hover tint (desktop) and an optional haptic.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.97,
    this.haptic = true,
    this.hoverColor,
    this.borderRadius,
    this.semanticLabel,
  });
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final bool haptic;
  final Color? hoverColor;
  final BorderRadius? borderRadius;
  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    Widget child = widget.child;
    if (widget.hoverColor != null) {
      child = AnimatedContainer(
        duration: Sf.fast,
        decoration: BoxDecoration(
          color: _hover && enabled ? widget.hoverColor : widget.hoverColor!.withValues(alpha: 0),
          borderRadius: widget.borderRadius,
        ),
        child: child,
      );
    }
    return Semantics(
      button: enabled,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTap: enabled
              ? () {
                  if (widget.haptic) HapticFeedback.selectionClick();
                  widget.onTap!();
                }
              : null,
          child: AnimatedScale(
            scale: _down ? widget.scale : 1,
            duration: Duration(milliseconds: _down ? 90 : 220),
            curve: _down ? Curves.easeOut : Curves.easeOutBack,
            child: child,
          ),
        ),
      ),
    );
  }
}

// ── Buttons ─────────────────────────────────────────────────────────────

enum SfButtonVariant { primary, secondary, ghost, danger, success }

class SfButton extends StatelessWidget {
  const SfButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = SfButtonVariant.primary,
    this.leading,
    this.trailing,
    this.large = false,
    this.small = false,
    this.expand = false,
  });
  final Widget label;
  final VoidCallback? onPressed;
  final SfButtonVariant variant;
  final Widget? leading;
  final Widget? trailing;
  final bool large;
  final bool small;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (variant) {
      SfButtonVariant.primary => (Sf.accent, Colors.white, Colors.transparent),
      SfButtonVariant.secondary => (Sf.accentSoft, Sf.accentLight, const Color(0x2E2B7FFF)),
      SfButtonVariant.ghost => (const Color(0x0AFFFFFF), Sf.textSecondary, Sf.borderSubtle),
      SfButtonVariant.danger => (const Color(0x2EEF4444), const Color(0xFFFECACA), const Color(0x73EF4444)),
      SfButtonVariant.success => (Sf.verified, Colors.white, Colors.transparent),
    };
    final h = large ? 52.0 : small ? 40.0 : 46.0;
    return Opacity(
      opacity: onPressed == null && variant != SfButtonVariant.success ? 0.5 : 1,
      child: Pressable(
        onTap: onPressed,
        child: AnimatedContainer(
          duration: Sf.medium,
          curve: Curves.easeOut,
          height: h,
          padding: EdgeInsets.symmetric(horizontal: small ? 16 : 22),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(Sf.r + 2),
            border: Border.all(color: border),
            boxShadow: variant == SfButtonVariant.primary
                ? [BoxShadow(color: Sf.accent.withValues(alpha: 0.35), blurRadius: 24, spreadRadius: -10, offset: const Offset(0, 10))]
                : null,
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              fontFamily: kSans,
              color: fg,
              fontSize: small ? 13.5 : 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.25,
            ),
            child: IconTheme.merge(
              data: IconThemeData(color: fg),
              child: Row(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 8)],
                  Flexible(child: label),
                  if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SfIconButton extends StatelessWidget {
  const SfIconButton({super.key, required this.icon, required this.onTap, this.tooltip, this.size = 40, this.iconSize = 18, this.color});
  final SfIcons icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    Widget w = Pressable(
      onTap: onTap,
      scale: 0.9,
      hoverColor: const Color(0x0DFFFFFF),
      borderRadius: BorderRadius.circular(Sf.r),
      semanticLabel: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Center(child: SfIcon(icon, size: iconSize, color: color ?? Sf.textTertiary)),
      ),
    );
    if (tooltip != null) w = Tooltip(message: tooltip!, child: w);
    return w;
  }
}

class SfLinkButton extends StatelessWidget {
  const SfLinkButton({super.key, required this.text, required this.onTap, this.icon, this.fontSize = 13});
  final String text;
  final VoidCallback onTap;
  final SfIcons? icon;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      scale: 0.96,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(text, style: TextStyle(fontFamily: kSans, fontSize: fontSize, color: Sf.accentLight, fontWeight: FontWeight.w500)),
          if (icon != null) ...[const SizedBox(width: 4), SfIcon(icon!, size: fontSize, color: Sf.accentLight)],
        ]),
      ),
    );
  }
}

// ── Surfaces ────────────────────────────────────────────────────────────

class SfCard extends StatelessWidget {
  const SfCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.accentEdge = false, this.color});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// Brand accent hairline across the top (`.sf-accent-edge`).
  final bool accentEdge;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    Widget card = Container(
      decoration: BoxDecoration(
        color: color ?? Sf.bgCard,
        borderRadius: BorderRadius.circular(Sf.rCard),
        border: Border.all(color: Sf.borderSubtle),
        boxShadow: Sf.cardShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Sf.rCard),
        child: Stack(children: [
          Padding(padding: padding, child: child),
          if (accentEdge)
            Positioned(
              top: 0,
              left: 18,
              right: 18,
              child: Container(
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [Sf.accent.withValues(alpha: 0), Sf.accent.withValues(alpha: 0.6), Sf.accent.withValues(alpha: 0)]),
                ),
              ),
            ),
        ]),
      ),
    );
    if (onTap != null) {
      card = Pressable(onTap: onTap, scale: 0.985, hoverColor: const Color(0x08FFFFFF), borderRadius: BorderRadius.circular(Sf.rCard), child: card);
    }
    return card;
  }
}

class SfPill extends StatelessWidget {
  const SfPill(this.text, {super.key, this.tone = SfTone.neutral, this.icon, this.xs = true, this.leading});
  final String text;
  final SfTone tone;
  final SfIcons? icon;
  final Widget? leading;
  final bool xs;

  @override
  Widget build(BuildContext context) {
    final c = SfToneColors.of(tone);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: xs ? 8 : 10, vertical: xs ? 2.5 : 4),
      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(999), border: Border.all(color: c.border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (leading != null) ...[leading!, const SizedBox(width: 5)],
        if (icon != null) ...[SfIcon(icon!, size: 11, color: c.fg), const SizedBox(width: 4)],
        Text(text, style: TextStyle(fontFamily: kSans, fontSize: xs ? 11 : 12, fontWeight: FontWeight.w600, color: c.fg, height: 1.2)),
      ]),
    );
  }
}

/// `.sf-eyebrow`: glassy uppercase badge with a blue dot.
class SfEyebrow extends StatelessWidget {
  const SfEyebrow(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0x08FFFFFF),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: const BoxDecoration(color: Sf.accent, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(text.toUpperCase(),
            style: const TextStyle(fontFamily: kSans, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 2, color: Color(0xEB5BA3FF))),
      ]),
    );
  }
}

class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.tone = SfTone.info, this.size = 40});
  final SfIcons icon;
  final SfTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = tone == SfTone.neutral
        ? const SfToneColors(Color(0x0AFFFFFF), Sf.textTertiary, Color(0x14FFFFFF))
        : SfToneColors.of(tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(Sf.r + 1), border: Border.all(color: c.border)),
      child: Center(child: SfIcon(icon, size: (size * 0.46).roundToDouble(), color: c.fg)),
    );
  }
}

// ── Brand ───────────────────────────────────────────────────────────────

class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.height = 26});
  final double height;
  @override
  Widget build(BuildContext context) => SvgPicture.asset('assets/brand/shifter-wordmark.svg', height: height);
}

class Glyph extends StatelessWidget {
  const Glyph({super.key, this.size = 24});
  final double size;
  @override
  Widget build(BuildContext context) => SvgPicture.asset('assets/brand/shifter-glyph.svg', height: size);
}

/// Flag PNGs are the panel's set; no code = worldwide globe chip.
class SfFlag extends StatelessWidget {
  const SfFlag(this.code, {super.key, this.width = 22});
  final String? code;
  final double width;

  @override
  Widget build(BuildContext context) {
    final h = width * 0.7;
    final radius = BorderRadius.circular(width > 24 ? 4 : 2.5);
    if (code == null) {
      return Container(
        width: width,
        height: h,
        decoration: BoxDecoration(color: Sf.accentSoft, borderRadius: radius, border: Border.all(color: const Color(0x332B7FFF), width: 0.5)),
        child: Center(child: SfIcon(SfIcons.globe, size: h * 0.78, color: Sf.accentLight, strokeWidth: 2)),
      );
    }
    return Container(
      width: width,
      height: h,
      decoration: BoxDecoration(borderRadius: radius, boxShadow: const [BoxShadow(color: Color(0x14FFFFFF), spreadRadius: 1)]),
      child: ClipRRect(
        borderRadius: radius,
        child: Image.asset('assets/flags/$code.png', fit: BoxFit.cover, errorBuilder: (_, _, _) => Container(color: Sf.bgElevated)),
      ),
    );
  }
}

// ── Feedback ────────────────────────────────────────────────────────────

class SfSpinner extends StatefulWidget {
  const SfSpinner({super.key, this.size = 18, this.color = Sf.accentLight, this.stroke = 2});
  final double size;
  final Color color;
  final double stroke;
  @override
  State<SfSpinner> createState() => _SfSpinnerState();
}

class _SfSpinnerState extends State<SfSpinner> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 850))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _c,
      child: CustomPaint(size: Size.square(widget.size), painter: _ArcPainter(widget.color, widget.stroke)),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.color, this.stroke);
  final Color color;
  final double stroke;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final track = Paint()
      ..color = color.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(rect.center, size.width / 2 - stroke / 2, track);
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawArc(rect.deflate(stroke / 2), -math.pi / 2, math.pi / 2, false, arc);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}

class SfProgressBar extends StatelessWidget {
  const SfProgressBar({super.key, required this.ratio, this.height = 6});
  final double ratio;
  final double height;

  @override
  Widget build(BuildContext context) {
    final r = ratio.clamp(0.0, 1.0);
    final colors = r <= 0.1
        ? const [Sf.danger, Color(0xFFF97A7A)]
        : r <= 0.25
            ? const [Sf.warning, Color(0xFFF5B977)]
            : const [Sf.accent, Sf.accentLight];
    return Container(
      height: height,
      decoration: BoxDecoration(color: Sf.barTrack, borderRadius: BorderRadius.circular(999)),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: r),
        duration: const Duration(milliseconds: 900),
        curve: Sf.easeOutExpo,
        builder: (_, v, _) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: v,
          child: Container(
            decoration: BoxDecoration(gradient: LinearGradient(colors: colors), borderRadius: BorderRadius.circular(999)),
          ),
        ),
      ),
    );
  }
}

class SfToggle extends StatelessWidget {
  const SfToggle({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => onChanged(!value),
      scale: 0.92,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        width: 46,
        height: 28,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: value ? Sf.accent : const Color(0x1AFFFFFF),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: value ? Colors.transparent : Sf.borderSubtle),
          boxShadow: value ? [BoxShadow(color: Sf.accent.withValues(alpha: 0.35), blurRadius: 12, spreadRadius: -4)] : null,
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutBack,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: value ? Colors.white : Sf.textSecondary,
              shape: BoxShape.circle,
              boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 3, offset: Offset(0, 1))],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.sf-segmented` with a thumb that slides between options.
class SfSegmented<T> extends StatelessWidget {
  const SfSegmented({super.key, required this.options, required this.value, required this.onChanged, this.height = 40});
  final List<(T, Widget)> options;
  final T value;
  final ValueChanged<T> onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final index = options.indexWhere((o) => o.$1 == value).clamp(0, options.length - 1);
    return Container(
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0x0AFFFFFF),
        borderRadius: BorderRadius.circular(Sf.r + 1),
        border: Border.all(color: Sf.borderSubtle),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth / options.length;
        return Stack(children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 320),
            curve: Sf.easeOutExpo,
            left: w * index,
            top: 0,
            bottom: 0,
            width: w,
            child: Container(
              decoration: BoxDecoration(
                color: Sf.bgElevated,
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(color: Sf.borderMedium, spreadRadius: 1),
                  BoxShadow(color: Color(0x40000000), blurRadius: 2, offset: Offset(0, 1)),
                ],
              ),
            ),
          ),
          Row(children: [
            for (final (i, o) in options.indexed)
              Expanded(
                child: Pressable(
                  onTap: () => onChanged(o.$1),
                  scale: 0.95,
                  child: Center(
                    child: AnimatedDefaultTextStyle(
                      duration: Sf.fast,
                      style: TextStyle(
                        fontFamily: kSans,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: i == index ? Sf.textPrimary : Sf.textTertiary,
                      ),
                      child: IconTheme.merge(
                        data: IconThemeData(color: i == index ? Sf.textPrimary : Sf.textTertiary),
                        child: FittedBox(fit: BoxFit.scaleDown, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: o.$2)),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ]);
      }),
    );
  }
}

class SfSearchField extends StatefulWidget {
  const SfSearchField({super.key, required this.value, required this.onChanged, required this.hint, this.autofocus = false});
  final String value;
  final ValueChanged<String> onChanged;
  final String hint;
  final bool autofocus;

  @override
  State<SfSearchField> createState() => _SfSearchFieldState();
}

class _SfSearchFieldState extends State<SfSearchField> {
  late final _ctl = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(covariant SfSearchField old) {
    super.didUpdateWidget(old);
    if (widget.value != _ctl.text) _ctl.text = widget.value;
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return AnimatedContainer(
      duration: Sf.fast,
      height: 46,
      decoration: BoxDecoration(
        color: Sf.bgInput,
        borderRadius: BorderRadius.circular(Sf.r + 1),
        border: Border.all(color: focused ? Sf.accent : Sf.borderInput),
        boxShadow: focused ? [BoxShadow(color: Sf.accent.withValues(alpha: 0.18), spreadRadius: 3)] : null,
      ),
      child: Row(children: [
        const SizedBox(width: 14),
        SfIcon(SfIcons.search, size: 17, color: focused ? Sf.textTertiary : Sf.textMuted),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _ctl,
            focusNode: _focus,
            autofocus: widget.autofocus,
            onChanged: (v) {
              widget.onChanged(v);
              setState(() {});
            },
            style: const TextStyle(fontFamily: kSans, fontSize: 14.5, color: Sf.textPrimary),
            cursorColor: Sf.accentLight,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: widget.hint,
              hintStyle: const TextStyle(fontFamily: kSans, fontSize: 14.5, color: Sf.textMuted),
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: Sf.fast,
          transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
          child: _ctl.text.isEmpty
              ? const SizedBox(width: 10)
              : SfIconButton(
                  key: const ValueKey('clear'),
                  icon: SfIcons.x,
                  size: 36,
                  iconSize: 15,
                  tooltip: 'Clear',
                  onTap: () {
                    _ctl.clear();
                    widget.onChanged('');
                    setState(() {});
                  },
                ),
        ),
      ]),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing, this.leading});
  final String text;
  final Widget? trailing;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: 7)],
        Expanded(child: Text(text.toUpperCase(), style: SfText.label, overflow: TextOverflow.ellipsis)),
        ?trailing,
      ]),
    );
  }
}

class CountText extends StatelessWidget {
  const CountText(this.n, {super.key});
  final int? n;
  @override
  Widget build(BuildContext context) =>
      n == null ? const SizedBox.shrink() : Text('$n', style: SfText.mono.copyWith(fontSize: 11.5, color: Sf.textMuted));
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final SfIcons icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return FadeSlideIn(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          IconTile(icon, tone: SfTone.neutral, size: 48),
          const SizedBox(height: 16),
          Text(title, style: SfText.bodyStrong, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(body, style: SfText.bodyMuted, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      ),
    );
  }
}

// ── Lists ───────────────────────────────────────────────────────────────

/// Selectable list row used by the location and IP pickers (`.sf-row`).
class SfRow extends StatelessWidget {
  const SfRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.selected = false,
    this.trailing,
    this.trailingIcon,
    required this.onTap,
    this.mono = false,
  });
  final Widget leading;
  final String title;
  final String? subtitle;
  final bool selected;
  final Widget? trailing;
  final SfIcons? trailingIcon;
  final VoidCallback onTap;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      scale: 0.985,
      hoverColor: selected ? null : const Color(0x0AFFFFFF),
      borderRadius: BorderRadius.circular(Sf.r + 2),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Sf.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(Sf.r + 2),
          border: Border.all(color: selected ? const Color(0x402B7FFF) : Colors.transparent),
        ),
        child: Row(children: [
          SizedBox(width: 26, child: Center(child: leading)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono ? SfText.mono.copyWith(fontSize: 14.5, fontWeight: FontWeight.w500) : SfText.body),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: SfText.small),
              ],
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          if (selected && trailingIcon == null) ...[
            const SizedBox(width: 8),
            const PopIn(child: SfIcon(SfIcons.check, size: 17, strokeWidth: 2.4, color: Sf.accentLight)),
          ],
          if (trailingIcon != null) ...[
            const SizedBox(width: 8),
            SfIcon(trailingIcon!, size: 16, color: selected ? Sf.accentLight : Sf.textMuted),
          ],
        ]),
      ),
    );
  }
}

class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height = 12, this.radius = 6});
  final double? width;
  final double height;
  final double radius;
  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = _c.value * 2 - 0.5;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(-1 + t * 2 - 1, 0),
              end: Alignment(1 + t * 2 - 1, 0),
              colors: const [Color(0x08FFFFFF), Color(0x14FFFFFF), Color(0x08FFFFFF)],
            ),
          ),
        );
      },
    );
  }
}

class RowsSkeleton extends StatelessWidget {
  const RowsSkeleton({super.key, this.count = 5});
  final int count;
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      for (var i = 0; i < count; i++)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          child: Row(children: [
            const Skeleton(width: 24, height: 16, radius: 3),
            const SizedBox(width: 16),
            Expanded(child: FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: 0.45 + (i % 3) * 0.15, child: const Skeleton(height: 13))),
          ]),
        ),
    ]);
  }
}

// ── Motion ──────────────────────────────────────────────────────────────

/// Fade + 16px rise on first build (`sf-slide-up`), optionally delayed so
/// lists and dashboards cascade in.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero, this.offset = 16, this.duration = Sf.slow});
  final Widget child;
  final Duration delay;
  final double offset;
  final Duration duration;

  /// Convenience for staggered lists.
  static Duration stagger(int index, {int stepMs = 45, int maxSteps = 10}) =>
      Duration(milliseconds: stepMs * math.min(index, maxSteps));

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: widget.duration);
  late final _a = CurvedAnimation(parent: _c, curve: Sf.easeOutExpo);

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      builder: (_, child) => Opacity(
        opacity: _a.value.clamp(0, 1),
        child: Transform.translate(offset: Offset(0, (1 - _a.value) * widget.offset), child: child),
      ),
      child: widget.child,
    );
  }
}

/// `sf-pop`: scale from 0.4 with an overshoot.
class PopIn extends StatelessWidget {
  const PopIn({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.4, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutBack,
      builder: (_, v, c) => Opacity(opacity: ((v - 0.4) / 0.6).clamp(0, 1), child: Transform.scale(scale: v, child: c)),
      child: child,
    );
  }
}

/// Smooth cross-fade + slight slide for swapping content in place.
class SfSwitcher extends StatelessWidget {
  const SfSwitcher({super.key, required this.child, this.duration = Sf.medium, this.axis = Axis.vertical});
  final Widget child;
  final Duration duration;
  final Axis axis;
  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Sf.easeOutExpo,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.center, children: [...previous, ?current]),
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: axis == Axis.vertical ? const Offset(0, 0.15) : const Offset(0.08, 0), end: Offset.zero).animate(a),
          child: c,
        ),
      ),
      child: child,
    );
  }
}

/// Status pill for a membership.
SfPill statusPill(MembershipStatus s) => switch (s) {
      MembershipStatus.active => const SfPill('Active', tone: SfTone.success),
      MembershipStatus.expiring => const SfPill('Expiring soon', tone: SfTone.warning),
      MembershipStatus.expired => const SfPill('Expired', tone: SfTone.danger),
      MembershipStatus.suspended => const SfPill('Suspended', tone: SfTone.danger),
    };
