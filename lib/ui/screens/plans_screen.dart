import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../state/app_controller.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../links.dart';
import '../widgets/icons.dart';
import '../widgets/layout.dart';
import '../widgets/membership_card.dart';
import '../widgets/primitives.dart';

/// Membership list: shown after sign-in when there is more than one usable
/// plan, from the plan switcher, and as the "Plans" section on wide screens.
class PlansScreen extends StatelessWidget {
  const PlansScreen({super.key, this.onBack, this.onOpenSettings, this.onChosen, this.embedded = false});
  final VoidCallback? onBack;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onChosen;

  /// Wide layouts: large title, no wordmark bar.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final header = embedded
        ? const SfTopBar(title: 'Plans', large: true)
        : SfTopBar(
            onBack: onBack,
            leading: Padding(
              padding: EdgeInsets.only(left: onBack == null ? 8 : 4),
              child: const Align(alignment: Alignment.centerLeft, child: Wordmark(height: 22)),
            ),
            actions: [if (onOpenSettings != null) SfIconButton(icon: SfIcons.settings, tooltip: 'Settings', onTap: onOpenSettings)],
          );
    return PageScaffold(
      atmosphere: !embedded,
      header: header,
      body: RefreshIndicator(
        color: Sf.accentLight,
        backgroundColor: Sf.bgElevated,
        onRefresh: app.reloadMemberships,
        child: PlansList(onChosen: onChosen, embedded: embedded),
      ),
    );
  }
}

class PlansList extends StatelessWidget {
  const PlansList({super.key, this.onChosen, this.embedded = false, this.shrinkWrap = false});
  final VoidCallback? onChosen;
  final bool embedded;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final list = app.memberships;
    final pad = context.pagePadding;
    final bottom = MediaQuery.paddingOf(context).bottom;

    Widget content;
    if (app.membershipsError != null) {
      content = EmptyState(
        icon: SfIcons.refresh,
        title: 'Something went wrong',
        body: app.membershipsError!,
        action: SfButton(label: const Text('Try again'), variant: SfButtonVariant.ghost, small: true, onPressed: app.reloadMemberships),
      );
    } else if (list == null) {
      content = Column(children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SfCard(
              child: Column(children: const [
                Row(children: [
                  Skeleton(width: 40, height: 40, radius: 11),
                  SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Skeleton(width: 140, height: 14),
                    SizedBox(height: 8),
                    Skeleton(width: 80, height: 11),
                  ])),
                ]),
                SizedBox(height: 16),
                Skeleton(height: 6),
              ]),
            ),
          ),
      ]);
    } else {
      final usable = list.where((m) => m.usable).toList();
      final inactive = list.where((m) => !m.usable).toList();
      var i = 0;
      Widget card(Membership m) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FadeSlideIn(
              delay: FadeSlideIn.stagger(i++, stepMs: 60),
              child: MembershipCard(
                m,
                selected: embedded && m.id == app.activeId,
                onSelect: () async {
                  await app.selectMembership(m.id);
                  onChosen?.call();
                },
                onRenew: () => openExternal(context, ShifterUrls.renew(m.id)),
              ),
            ),
          );
      content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (usable.isEmpty)
          EmptyState(
            icon: SfIcons.layers,
            title: 'No active memberships',
            body: 'Get a Residential or ISP plan on Shifter and it will show up here instantly.',
            action: SfButton(
              label: const Text('View plans'),
              trailing: const SfIcon(SfIcons.external, size: 14, color: Colors.white),
              small: true,
              onPressed: () => openExternal(context, ShifterUrls.order),
            ),
          ),
        if (usable.isNotEmpty) ...[
          if (!embedded) ...[
            FadeSlideIn(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Choose a plan', style: SfText.title),
                  const SizedBox(height: 6),
                  Text('Pick the membership this device should connect with. You can switch any time.', style: SfText.bodyMuted),
                ]),
              ),
            ),
          ],
          SectionLabel('Active', trailing: CountText(usable.length)),
          for (final m in usable) card(m),
        ],
        if (inactive.isNotEmpty) ...[
          const SizedBox(height: 14),
          const SectionLabel('Inactive'),
          for (final m in inactive) card(m),
        ],
        const SizedBox(height: 10),
        SfButton(
          label: const Text('Add a plan'),
          leading: const SfIcon(SfIcons.plus, size: 16, color: Sf.textSecondary),
          variant: SfButtonVariant.ghost,
          small: true,
          expand: true,
          onPressed: () => openExternal(context, ShifterUrls.order),
        ),
      ]);
    }

    return ListView(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: EdgeInsets.fromLTRB(pad, embedded ? 4 : 18, pad, 24 + bottom),
      children: [MaxWidth(maxWidth: embedded ? 760 : 560, child: content)],
    );
  }
}

/// Phone plan switcher: a bottom sheet instead of a full screen.
Future<void> showPlanSwitcher(BuildContext context) {
  final app = AppScope.read(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (sheetContext) => AppScope(
      controller: app,
      child: _PlanSheet(),
    ),
  );
}

class _PlanSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final usable = app.usableMemberships;
    final maxH = MediaQuery.sizeOf(context).height * 0.85;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: const BoxDecoration(
        color: Sf.bgElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        border: Border(top: BorderSide(color: Sf.borderMedium)),
        boxShadow: Sf.overlayShadow,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 10),
        Container(width: 38, height: 5, decoration: BoxDecoration(color: Sf.borderStrong, borderRadius: BorderRadius.circular(9))),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 12, 8),
          child: Row(children: [
            Expanded(child: Text('Switch plan', style: SfText.heading)),
            SfIconButton(icon: SfIcons.x, tooltip: 'Close', onTap: () => Navigator.pop(context)),
          ]),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(16, 4, 16, 20 + bottom),
            children: [
              for (final (i, m) in usable.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: FadeSlideIn(
                    delay: FadeSlideIn.stagger(i, stepMs: 50),
                    child: MembershipCard(
                      m,
                      selected: m.id == app.activeId,
                      onSelect: () async {
                        await app.selectMembership(m.id);
                        if (context.mounted) Navigator.pop(context);
                      },
                      onRenew: () => openExternal(context, ShifterUrls.renew(m.id)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}
