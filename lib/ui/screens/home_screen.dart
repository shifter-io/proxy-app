import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/format.dart';
import '../../data/models.dart';
import '../../state/app_controller.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../links.dart';
import '../widgets/icons.dart';
import '../widgets/layout.dart';
import '../widgets/membership_card.dart';
import '../widgets/power_button.dart';
import '../widgets/primitives.dart';

/// Phone home: plan switcher in the top bar, everything else centred.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onOpenLocation, required this.onOpenSettings, required this.onSwitchPlan});
  final VoidCallback onOpenLocation;
  final VoidCallback onOpenSettings;
  final VoidCallback onSwitchPlan;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final m = app.activeMembership;
    if (m == null) return const SizedBox.shrink();
    final canSwitch = app.usableMemberships.length > 1;
    return PageScaffold(
      atmosphere: true,
      connected: app.isConnected && app.connection.membershipId == m.id,
      header: SfTopBar(
        border: false,
        leading: PlanSwitcherButton(m: m, onTap: canSwitch ? onSwitchPlan : null),
        actions: [SfIconButton(icon: SfIcons.settings, tooltip: 'Settings', onTap: onOpenSettings)],
      ),
      body: LayoutBuilder(builder: (context, c) {
        final pad = context.pagePadding;
        final bottom = MediaQuery.paddingOf(context).bottom;
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: EdgeInsets.fromLTRB(pad, 0, pad, 20 + bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight - 20 - bottom),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Dashboard(onOpenLocation: onOpenLocation, onOpenSession: onOpenSettings, heroSize: _heroSize(c)),
              ),
            ),
          ),
        );
      }),
    );
  }

  /// Power button scales with the screen: 104 on fold covers, 140 on big phones.
  static double _heroSize(BoxConstraints c) {
    final byWidth = (c.maxWidth * 0.34).clamp(96.0, 144.0);
    final byHeight = c.maxHeight < 560 ? 100.0 : 144.0;
    return byWidth < byHeight ? byWidth : byHeight;
  }
}

/// Header button: glyph, "MEMBERSHIP", plan name + pool, chevron.
class PlanSwitcherButton extends StatelessWidget {
  const PlanSwitcherButton({super.key, required this.m, this.onTap});
  final Membership m;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Pressable(
        onTap: onTap,
        scale: 0.97,
        hoverColor: const Color(0x0AFFFFFF),
        borderRadius: BorderRadius.circular(Sf.r),
        semanticLabel: onTap != null ? 'Switch membership' : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Glyph(size: 24),
            const SizedBox(width: 10),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('MEMBERSHIP', style: SfText.label.copyWith(fontSize: 9.5)),
                const SizedBox(height: 3),
                SfSwitcher(
                  axis: Axis.horizontal,
                  child: Row(key: ValueKey(m.id), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Flexible(child: Text(m.planName, maxLines: 1, overflow: TextOverflow.ellipsis, style: SfText.bodyStrong.copyWith(fontSize: 14.5, height: 1.1))),
                    const SizedBox(width: 6),
                    Flexible(child: PoolTag(m, fontSize: 12.5)),
                    if (onTap != null) ...[const SizedBox(width: 4), const SfIcon(SfIcons.chevronDown, size: 15, color: Sf.textTertiary)],
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Hero + location + stats + renewal. Shared by the phone home and the
/// Connect section on tablets/desktop.
class Dashboard extends StatelessWidget {
  const Dashboard({super.key, required this.onOpenLocation, required this.onOpenSession, this.heroSize = 132, this.showLocationCard = true});
  final VoidCallback onOpenLocation;
  final VoidCallback onOpenSession;
  final double heroSize;

  /// Wide layouts show the picker beside the dashboard, so the card is optional.
  final bool showLocationCard;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final m = app.activeMembership!;
    final target = app.currentTarget(m);
    final c = app.connection;
    final here = c.membershipId == m.id || c.status == ConnectionStatus.error;
    final status = here ? c.status : ConnectionStatus.disconnected;
    final locked = m is ResidentialMembership && !poolTargeting(m.pool).country;

    void toggle() {
      if (status == ConnectionStatus.connected || status == ConnectionStatus.connecting) {
        app.disconnect();
      } else if (target == null) {
        onOpenLocation();
      } else {
        app.connect();
      }
    }

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FadeSlideIn(
        child: _Hero(
          status: status,
          exitIp: status == ConnectionStatus.connected ? c.exitIp : null,
          since: status == ConnectionStatus.connected ? c.since : null,
          error: c.status == ConnectionStatus.error ? c.message : null,
          needsTarget: target == null,
          countryCode: (status == ConnectionStatus.connected ? c.exitCountry : null) ?? targetCountryCode(target),
          onToggle: toggle,
          onNewIp: m is ResidentialMembership && status == ConnectionStatus.connected ? app.newIp : null,
          size: heroSize,
        ),
      ),
      if (showLocationCard)
        FadeSlideIn(delay: const Duration(milliseconds: 80), child: LocationCard(m: m, target: target, onOpen: onOpenLocation)),
      if (locked)
        FadeSlideIn(
          delay: const Duration(milliseconds: 120),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Padding(padding: EdgeInsets.only(top: 2), child: SfIcon(SfIcons.lock, size: 14, color: Sf.textMuted)),
              const SizedBox(width: 8),
              Expanded(child: Text(poolLimitNote(ResidentialPool.nonGeo)!, style: SfText.micro.copyWith(fontSize: 12.5, height: 1.5))),
            ]),
          ),
        ),
      const SizedBox(height: 12),
      FadeSlideIn(delay: const Duration(milliseconds: 140), child: StatsCard(m: m, settings: app.settings, onSession: onOpenSession)),
      const SizedBox(height: 18),
      FadeSlideIn(
        delay: const Duration(milliseconds: 200),
        child: RenewalLine(m, onRenew: () => openExternal(context, ShifterUrls.renew(m.id))),
      ),
    ]);
  }
}

class _Hero extends StatelessWidget {
  const _Hero({
    required this.status,
    required this.exitIp,
    required this.since,
    required this.error,
    required this.needsTarget,
    required this.countryCode,
    required this.onToggle,
    required this.onNewIp,
    required this.size,
  });
  final ConnectionStatus status;
  final String? exitIp;
  final DateTime? since;
  final String? error;
  final bool needsTarget;
  final String? countryCode;
  final VoidCallback onToggle;
  final VoidCallback? onNewIp;
  final double size;

  @override
  Widget build(BuildContext context) {
    final connected = status == ConnectionStatus.connected;
    final connecting = status == ConnectionStatus.connecting;
    final title = switch (status) {
      ConnectionStatus.connected => 'Connected',
      ConnectionStatus.connecting => 'Connecting…',
      ConnectionStatus.error => 'Connection failed',
      ConnectionStatus.disconnected => 'Not connected',
    };

    Widget sub;
    if (connected && exitIp != null) {
      sub = Wrap(
        key: ValueKey('ip$exitIp'),
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 7,
        runSpacing: 4,
        children: [
          SfFlag(countryCode, width: 18),
          Text(exitIp!, style: SfText.mono.copyWith(fontSize: 13.5, color: Sf.textSecondary)),
          if (since != null) _Uptime(since: since!),
          if (onNewIp != null)
            SfIconButton(icon: SfIcons.refresh, tooltip: 'New IP', size: 30, iconSize: 14, color: Sf.textMuted, onTap: onNewIp),
        ],
      );
    } else if (connecting) {
      sub = Text('Securing your route through Shifter', key: const ValueKey('c'), style: SfText.small, textAlign: TextAlign.center);
    } else if (status == ConnectionStatus.error) {
      sub = Text(error ?? '', key: const ValueKey('e'), style: SfText.small.copyWith(color: Sf.dangerLight), textAlign: TextAlign.center);
    } else {
      sub = Text(
        needsTarget ? 'Pick an IP to get started' : 'Tap to route this device through Shifter',
        key: ValueKey('d$needsTarget'),
        style: SfText.small,
        textAlign: TextAlign.center,
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: size * 0.05, bottom: size * 0.12),
      child: Column(children: [
        PowerButton(status: status, onTap: onToggle, size: size),
        SizedBox(height: size * 0.02),
        SfSwitcher(
          child: Text(
            title,
            key: ValueKey(title),
            style: SfText.heading.copyWith(fontSize: 19, color: connected ? Sf.successLight : Sf.textPrimary),
          ),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(constraints: const BoxConstraints(minHeight: 30), child: Center(child: SfSwitcher(child: sub))),
        AnimatedSize(
          duration: const Duration(milliseconds: 350),
          curve: Sf.easeOutExpo,
          child: connected
              ? Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: FadeSlideIn(
                    offset: 8,
                    child: Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 6, children: const [
                      SfPill('DNS via Shifter', tone: SfTone.success, icon: SfIcons.shieldCheck),
                      SfPill('System proxy', tone: SfTone.neutral, icon: SfIcons.lock),
                    ]),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}

class _Uptime extends StatefulWidget {
  const _Uptime({required this.since});
  final DateTime since;
  @override
  State<_Uptime> createState() => _UptimeState();
}

class _UptimeState extends State<_Uptime> {
  late final Timer _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.now().difference(widget.since);
    return Text('· ${formatUptime(d.isNegative ? Duration.zero : d)}', style: SfText.mono.copyWith(fontSize: 13, color: Sf.textMuted));
  }
}

class LocationCard extends StatelessWidget {
  const LocationCard({super.key, required this.m, required this.target, required this.onOpen});
  final Membership m;
  final Target? target;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final mm = m;
    final locked = mm is ResidentialMembership && !poolTargeting(mm.pool).country;
    final t = target;
    final ({String title, String subtitle}) d;
    if (locked) {
      d = (title: 'Random location', subtitle: 'Worldwide · Non-Geo plan');
    } else if (mm is IspMembership && t == null) {
      d = (title: 'Choose an IP', subtitle: '${mm.ipCount} static ISP IPs on this plan');
    } else if (mm is ResidentialMembership && !poolTargeting(mm.pool).subCountry && t is ResidentialTarget && t.country != null) {
      d = (title: t.country!.name, subtitle: 'Country-level · Country Geo plan');
    } else {
      d = describeTarget(t);
    }
    final code = targetCountryCode(t);

    return SfCard(
      accentEdge: true,
      onTap: locked ? null : onOpen,
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: const Color(0x08FFFFFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Sf.borderSubtle),
          ),
          child: Center(
            child: SfSwitcher(
              child: mm is IspMembership && t == null
                  ? const SfIcon(SfIcons.server, key: ValueKey('srv'), size: 20, color: Sf.textTertiary)
                  : code == null
                      ? const SfIcon(SfIcons.globe, key: ValueKey('globe'), size: 21, color: Sf.accentLight)
                      : SfFlag(code, key: ValueKey(code), width: 26),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mm is IspMembership ? 'STATIC IP' : 'LOCATION', style: SfText.label.copyWith(fontSize: 9.5)),
            const SizedBox(height: 4),
            SfSwitcher(
              axis: Axis.horizontal,
              child: Column(
                key: ValueKey(d.title + d.subtitle),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: SfText.bodyStrong),
                  const SizedBox(height: 2),
                  Text(d.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: SfText.small),
                ],
              ),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        if (locked)
          const SfIcon(SfIcons.lock, size: 16, color: Sf.textMuted)
        else if (MediaQuery.sizeOf(context).width < 340)
          const SfIcon(SfIcons.chevronRight, size: 18, color: Sf.accentLight)
        else
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Change', style: SfText.small.copyWith(color: Sf.accentLight, fontWeight: FontWeight.w500)),
            const SizedBox(width: 2),
            const SfIcon(SfIcons.chevronRight, size: 16, color: Sf.accentLight),
          ]),
      ]),
    );
  }
}

/// Two-up stats: traffic left + IP session (opens Settings). Stacks on
/// very narrow screens (fold cover displays).
class StatsCard extends StatelessWidget {
  const StatsCard({super.key, required this.m, required this.settings, required this.onSession});
  final Membership m;
  final ProxySettings settings;
  final VoidCallback onSession;

  @override
  Widget build(BuildContext context) {
    final mm = m;
    final traffic = mm is ResidentialMembership ? trafficLeft(mm) : null;
    final usage = mm is ResidentialMembership && traffic != null
        ? _Stat(
            label: 'Traffic left',
            value: Text.rich(TextSpan(children: [
              TextSpan(text: formatBytes(traffic.left)),
              TextSpan(
                text: ' / ${formatBytes(traffic.total, digits: 0)}',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400, color: Sf.textMuted),
              ),
            ])),
            sub: Padding(padding: const EdgeInsets.only(top: 4), child: SfProgressBar(ratio: traffic.ratio, height: 4)),
          )
        : mm is ResidentialMembership && !mm.unmetered
            ? const _Stat(label: 'Traffic left', value: Text('—'), sub: Text('Usage not available yet'))
            : const _Stat(label: 'Bandwidth', value: Text('Unlimited'), sub: Text('No traffic cap'));
    final session = mm is IspMembership
        ? const _Stat(label: 'IP', value: Text('Static'), sub: Text('Same IP every time'))
        : _Stat(
            label: 'Session',
            value: Text(settings.sessionMode == SessionMode.sticky ? formatDuration(settings.ttlSeconds) : 'Rotating'),
            sub: Text(settings.sessionMode == SessionMode.sticky ? 'Sticky IP' : 'New IP per request'),
            action: true,
          );
    final sessionCell = mm is IspMembership
        ? session
        : Pressable(onTap: onSession, scale: 0.98, hoverColor: const Color(0x08FFFFFF), child: session);

    return SfCard(
      padding: EdgeInsets.zero,
      child: LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < 300) {
          return Column(children: [usage, Container(height: 1, color: Sf.borderSubtle), sessionCell]);
        }
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: usage),
            Container(width: 1, color: Sf.borderSubtle),
            Expanded(child: sessionCell),
          ]),
        );
      }),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.sub, this.action = false});
  final String label;
  final Widget value;
  final Widget sub;
  final bool action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Text(label.toUpperCase(), style: SfText.label.copyWith(fontSize: 9.5))),
          if (action) const SfIcon(SfIcons.chevronRight, size: 14, color: Sf.textMuted),
        ]),
        const SizedBox(height: 8),
        DefaultTextStyle(
          style: SfText.mono.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          child: value,
        ),
        const SizedBox(height: 6),
        DefaultTextStyle(style: SfText.micro.copyWith(color: Sf.textTertiary, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis, child: sub),
      ]),
    );
  }
}
