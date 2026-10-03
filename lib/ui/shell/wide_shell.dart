import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../data/format.dart';
import '../../data/models.dart';
import '../../state/app_controller.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../screens/home_screen.dart';
import '../screens/location/location_screen.dart';
import '../screens/plans_screen.dart';
import '../screens/settings_screen.dart';
import '../widgets/atmosphere.dart';
import '../widgets/icons.dart';
import '../widgets/layout.dart';
import '../widgets/membership_card.dart';
import '../widgets/primitives.dart';

enum Section { connect, plans, settings }

/// Tablets, unfolded foldables and desktop: navigation on the side, the
/// location picker docked next to the dashboard when there is room.
class WideShell extends StatefulWidget {
  const WideShell({super.key});
  @override
  State<WideShell> createState() => _WideShellState();
}

class _WideShellState extends State<WideShell> {
  Section section = Section.connect;

  void _go(Section s) => setState(() => section = s);

  @override
  Widget build(BuildContext context) {
    final expanded = context.sizeClass == SizeClass.expanded;
    final content = AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      switchInCurve: Sf.easeOutExpo,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(position: Tween(begin: const Offset(0, 0.02), end: Offset.zero).animate(a), child: c),
      ),
      child: KeyedSubtree(
        key: ValueKey(section),
        child: switch (section) {
          Section.connect => _ConnectSection(onOpenSettings: () => _go(Section.settings)),
          Section.plans => PlansScreen(embedded: true, onChosen: () => _go(Section.connect)),
          Section.settings => const SettingsScreen(embedded: true),
        },
      ),
    );

    return Material(
      color: Sf.bgDeepest,
      child: Row(children: [
        expanded ? _Sidebar(section: section, onSelect: _go) : _Rail(section: section, onSelect: _go),
        Expanded(child: content),
      ]),
    );
  }
}

// ── Connect ─────────────────────────────────────────────────────────────

class _ConnectSection extends StatelessWidget {
  const _ConnectSection({required this.onOpenSettings});
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final m = app.activeMembership!;
    final connected = app.isConnected && app.connection.membershipId == m.id;

    return LayoutBuilder(builder: (context, c) {
      final docked = c.maxWidth >= 700;
      final panelWidth = (c.maxWidth * 0.42).clamp(320.0, 460.0);
      final heroSize = (c.maxHeight < 640 ? 112.0 : 150.0);

      final dashboard = Stack(children: [
        Positioned.fill(child: Atmosphere(connected: connected)),
        Column(children: [
          SfTopBar(
            title: 'Connect',
            large: true,
            actions: [SfPill(m.type == ProductType.isp ? 'ISP' : 'Residential', tone: m.type == ProductType.isp ? SfTone.neutral : SfTone.info, xs: false)],
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, inner) {
              return SingleChildScrollView(
                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: inner.maxHeight - 28),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Dashboard(
                        heroSize: heroSize,
                        onOpenSession: onOpenSettings,
                        onOpenLocation: docked
                            ? () {}
                            : () => Navigator.of(context).push(CupertinoPageRoute(
                                  builder: (ctx) => LocationScreen(onBack: () => Navigator.pop(ctx), onApplied: () => Navigator.pop(ctx)),
                                )),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ]),
      ]);

      if (!docked) return dashboard;
      return Row(children: [
        Expanded(child: dashboard),
        Container(
          width: panelWidth,
          decoration: const BoxDecoration(
            color: Sf.bgDeep,
            border: Border(left: BorderSide(color: Sf.borderSubtle)),
          ),
          child: LocationScreen(
            embedded: true,
            onApplied: () {
              ScaffoldMessenger.maybeOf(context)
                ?..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(
                  width: 320,
                  duration: const Duration(milliseconds: 1600),
                  content: Row(children: [
                    const SfIcon(SfIcons.check, size: 16, color: Sf.successLight, strokeWidth: 2.4),
                    const SizedBox(width: 10),
                    Expanded(child: Text(describeTarget(AppScope.read(context).currentTarget(m)).title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                ));
            },
          ),
        ),
      ]);
    });
  }
}

// ── Navigation ──────────────────────────────────────────────────────────

const _nav = [
  (Section.connect, SfIcons.power, 'Connect'),
  (Section.plans, SfIcons.layers, 'Plans'),
  (Section.settings, SfIcons.settings, 'Settings'),
];

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.section, required this.onSelect});
  final Section section;
  final ValueChanged<Section> onSelect;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final m = app.activeMembership!;
    final pad = MediaQuery.paddingOf(context);
    return Container(
      width: 268,
      padding: EdgeInsets.fromLTRB(16, pad.top + 22, 16, pad.bottom + 16),
      decoration: const BoxDecoration(
        color: Sf.bgDeep,
        border: Border(right: BorderSide(color: Sf.borderSubtle)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(padding: EdgeInsets.only(left: 8), child: Align(alignment: Alignment.centerLeft, child: Wordmark(height: 24))),
        const SizedBox(height: 28),
        _PlanMiniCard(m: m, onTap: app.usableMemberships.length > 1 ? () => onSelect(Section.plans) : null),
        const SizedBox(height: 22),
        for (final (s, icon, label) in _nav)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _NavItem(icon: icon, label: label, selected: s == section, onTap: () => onSelect(s)),
          ),
        const Spacer(),
        const _StatusChip(),
        const SizedBox(height: 14),
        Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: Sf.accentSoft, borderRadius: BorderRadius.circular(Sf.r), border: Border.all(color: const Color(0x332B7FFF))),
            child: Center(
              child: Text(
                (app.session?.user.name ?? 'S').substring(0, 1),
                style: SfText.bodyStrong.copyWith(color: Sf.accentLight, fontSize: 14),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(app.session?.user.name ?? '', style: SfText.body.copyWith(fontSize: 13.5), maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(app.session?.user.email ?? '', style: SfText.micro, maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      ]),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, required this.selected, required this.onTap});
  final SfIcons icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      scale: 0.98,
      hoverColor: selected ? null : const Color(0x08FFFFFF),
      borderRadius: BorderRadius.circular(Sf.r),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? Sf.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(Sf.r),
          border: Border.all(color: selected ? const Color(0x382B7FFF) : Colors.transparent),
        ),
        child: Row(children: [
          SfIcon(icon, size: 18, color: selected ? Sf.accentLight : Sf.textTertiary),
          const SizedBox(width: 12),
          Text(label, style: SfText.body.copyWith(fontSize: 14, color: selected ? Sf.textPrimary : Sf.textSecondary)),
        ]),
      ),
    );
  }
}

class _PlanMiniCard extends StatelessWidget {
  const _PlanMiniCard({required this.m, this.onTap});
  final Membership m;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mm = m;
    return SfCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('MEMBERSHIP', style: SfText.label.copyWith(fontSize: 9.5)),
          const Spacer(),
          if (onTap != null) Text('Switch', style: SfText.micro.copyWith(color: Sf.accentLight, fontWeight: FontWeight.w500)),
        ]),
        const SizedBox(height: 8),
        SfSwitcher(
          axis: Axis.horizontal,
          child: Row(key: ValueKey(m.id), children: [
            Flexible(child: Text(m.planName, maxLines: 1, overflow: TextOverflow.ellipsis, style: SfText.bodyStrong)),
            const SizedBox(width: 6),
            Flexible(child: PoolTag(m, fontSize: 12.5)),
          ]),
        ),
        const SizedBox(height: 10),
        if (mm is ResidentialMembership)
          if (trafficLeft(mm) case final t?) ...[
            SfProgressBar(key: ValueKey('bar${m.id}'), ratio: t.ratio, height: 4),
            const SizedBox(height: 7),
            Text('${formatBytes(t.left)} left of ${formatBytes(t.total, digits: 0)}', style: SfText.micro.copyWith(fontSize: 12)),
          ] else
            Text(mm.unmetered ? 'Unlimited traffic' : 'Traffic usage not available yet', style: SfText.micro.copyWith(fontSize: 12))
        else
          Text('${(mm as IspMembership).ipCount} static IPs · unlimited', style: SfText.micro.copyWith(fontSize: 12)),
      ]),
    );
  }
}

/// Live connection status for the sidebar / rail.
class _StatusChip extends StatelessWidget {
  const _StatusChip({this.dotOnly = false});
  final bool dotOnly;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = app.connection;
    final (color, label) = switch (c.status) {
      ConnectionStatus.connected => (Sf.success, 'Connected'),
      ConnectionStatus.connecting => (Sf.accentLight, 'Connecting…'),
      ConnectionStatus.error => (Sf.danger, 'Failed'),
      ConnectionStatus.disconnected => (Sf.textMuted, 'Not connected'),
    };
    final dot = AnimatedContainer(
      duration: Sf.medium,
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), spreadRadius: 3)],
      ),
    );
    if (dotOnly) return Tooltip(message: label, child: dot);
    return AnimatedContainer(
      duration: Sf.medium,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.status == ConnectionStatus.connected ? const Color(0x143DBA78) : const Color(0x08FFFFFF),
        borderRadius: BorderRadius.circular(Sf.r),
        border: Border.all(color: c.status == ConnectionStatus.connected ? const Color(0x383DBA78) : Sf.borderSubtle),
      ),
      child: Row(children: [
        dot,
        const SizedBox(width: 10),
        Expanded(
          child: SfSwitcher(
            axis: Axis.horizontal,
            child: Align(
              key: ValueKey('$label${c.exitIp}'),
              alignment: Alignment.centerLeft,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: SfText.body.copyWith(fontSize: 13)),
                if (c.status == ConnectionStatus.connected && c.exitIp != null)
                  Text(c.exitIp!, style: SfText.mono.copyWith(fontSize: 11.5, color: Sf.textTertiary)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.section, required this.onSelect});
  final Section section;
  final ValueChanged<Section> onSelect;

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Container(
      width: 88,
      padding: EdgeInsets.fromLTRB(10, pad.top + 20, 10, pad.bottom + 18),
      decoration: const BoxDecoration(
        color: Sf.bgDeep,
        border: Border(right: BorderSide(color: Sf.borderSubtle)),
      ),
      child: Column(children: [
        const Glyph(size: 30),
        const SizedBox(height: 30),
        for (final (s, icon, label) in _nav)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Pressable(
              onTap: () => onSelect(s),
              scale: 0.94,
              child: Column(children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  curve: Sf.easeOutExpo,
                  width: s == section ? 56 : 44,
                  height: 34,
                  decoration: BoxDecoration(
                    color: s == section ? Sf.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: s == section ? const Color(0x402B7FFF) : Colors.transparent),
                  ),
                  child: Center(child: SfIcon(icon, size: 19, color: s == section ? Sf.accentLight : Sf.textTertiary)),
                ),
                const SizedBox(height: 5),
                Text(label, style: SfText.micro.copyWith(fontSize: 11.5, color: s == section ? Sf.textPrimary : Sf.textTertiary, fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
        const Spacer(),
        const _StatusChip(dotOnly: true),
      ]),
    );
  }
}
