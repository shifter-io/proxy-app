import 'package:flutter/material.dart';

import '../../data/format.dart';
import '../../data/models.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'icons.dart';
import 'primitives.dart';

/// Residential pool ("· Full Geo") shown beside the plan title.
class PoolTag extends StatelessWidget {
  const PoolTag(this.m, {super.key, this.fontSize = 13});
  final Membership m;
  final double fontSize;
  @override
  Widget build(BuildContext context) {
    final mm = m;
    if (mm is! ResidentialMembership) return const SizedBox.shrink();
    return Text.rich(
      TextSpan(children: [
        const TextSpan(text: '·  ', style: TextStyle(color: Sf.textMuted)),
        TextSpan(text: poolLabel(mm.pool)),
      ]),
      maxLines: 1,
      style: TextStyle(fontFamily: kSans, fontSize: fontSize, fontWeight: FontWeight.w400, color: Sf.textTertiary),
    );
  }
}

/// "Renews in 23 days · Oct 23, 2026"; expired plans get a Renew link.
class RenewalLine extends StatelessWidget {
  const RenewalLine(this.m, {super.key, required this.onRenew, this.center = true});
  final Membership m;
  final VoidCallback onRenew;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final Widget line;
    if (m.status == MembershipStatus.expired) {
      line = Text('Expired ${formatDate(m.expiresAt)}', style: SfText.small.copyWith(color: Sf.dangerLight));
    } else {
      final tone = m.status == MembershipStatus.expiring ? Sf.warningLight : Sf.textTertiary;
      line = Text.rich(
        TextSpan(children: [
          TextSpan(text: '${m.renewsAt != null ? 'Renews' : 'Expires'} ${relativeDays(m.renewsAt ?? m.expiresAt)}', style: TextStyle(color: tone)),
          TextSpan(text: ' · ${formatDate(m.renewsAt ?? m.expiresAt)}', style: const TextStyle(color: Sf.textMuted)),
        ]),
        style: SfText.small,
        textAlign: center ? TextAlign.center : TextAlign.start,
      );
    }
    return Wrap(
      alignment: center ? WrapAlignment.center : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      children: [
        line,
        if (!m.usable) SfLinkButton(text: 'Renew', icon: SfIcons.external, onTap: onRenew, fontSize: 12.5),
      ],
    );
  }
}

class UsageLine extends StatelessWidget {
  const UsageLine(this.m, {super.key});
  final Membership m;
  @override
  Widget build(BuildContext context) {
    final mm = m;
    if (mm is! ResidentialMembership) {
      return Row(children: [
        Text('Bandwidth', style: SfText.small),
        const Spacer(),
        Text('Unlimited', style: SfText.mono.copyWith(fontSize: 12.5, color: Sf.textSecondary)),
      ]);
    }
    final t = trafficLeft(mm);
    if (t == null) {
      return Row(children: [
        Text('Traffic left', style: SfText.small),
        const Spacer(),
        Text('—', style: SfText.mono.copyWith(fontSize: 12.5, color: Sf.textSecondary)),
      ]);
    }
    return Column(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        Text('Traffic left', style: SfText.small),
        const Spacer(),
        Text.rich(TextSpan(children: [
          TextSpan(text: formatBytes(t.left), style: const TextStyle(color: Sf.textPrimary, fontWeight: FontWeight.w500)),
          TextSpan(text: ' / ${formatBytes(t.total, digits: 0)}', style: const TextStyle(color: Sf.textMuted)),
        ]), style: SfText.mono.copyWith(fontSize: 12.5)),
      ]),
      const SizedBox(height: 8),
      SfProgressBar(ratio: t.ratio),
    ]);
  }
}

class MembershipCard extends StatelessWidget {
  const MembershipCard(this.m, {super.key, required this.onSelect, required this.onRenew, this.selected = false});
  final Membership m;
  final VoidCallback onSelect;
  final VoidCallback onRenew;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final usable = m.usable;
    final narrow = MediaQuery.sizeOf(context).width < 360;
    final badges = Wrap(spacing: 6, runSpacing: 6, children: [
      if (m.status != MembershipStatus.active) statusPill(m.status),
      SfPill(productLabel(m.type), tone: m.type == ProductType.residential ? SfTone.info : SfTone.neutral),
    ]);
    return Opacity(
      opacity: usable ? 1 : 0.6,
      child: AnimatedContainer(
        duration: Sf.medium,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Sf.rCard),
          boxShadow: selected ? [BoxShadow(color: Sf.accent.withValues(alpha: 0.5), spreadRadius: 1.2)] : null,
        ),
        child: SfCard(
          onTap: usable ? onSelect : null,
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              IconTile(m.type == ProductType.residential ? SfIcons.globe : SfIcons.server,
                  tone: m.type == ProductType.residential ? SfTone.info : SfTone.purple),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                    Flexible(child: Text(m.planName, maxLines: 1, overflow: TextOverflow.ellipsis, style: SfText.bodyStrong)),
                    const SizedBox(width: 6),
                    Flexible(child: PoolTag(m)),
                  ]),
                  if (narrow) ...[const SizedBox(height: 6), badges],
                ]),
              ),
              if (!narrow) ...[const SizedBox(width: 8), badges],
              if (selected) ...[const SizedBox(width: 8), const PopIn(child: SfIcon(SfIcons.check, size: 18, color: Sf.accentLight, strokeWidth: 2.4))],
            ]),
            const SizedBox(height: 14),
            UsageLine(m),
            const SizedBox(height: 12),
            Container(height: 1, color: Sf.borderSubtle),
            const SizedBox(height: 10),
            RenewalLine(m, onRenew: onRenew),
          ]),
        ),
      ),
    );
  }
}
