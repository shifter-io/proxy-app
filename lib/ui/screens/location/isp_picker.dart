import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/models.dart';
import '../../../state/app_controller.dart';
import '../../../theme/tokens.dart';
import '../../widgets/icons.dart';
import '../../widgets/layout.dart';
import '../../widgets/primitives.dart';
import 'async_list.dart';

/// ISP plans are a fixed set of static IPs: pick one, optionally filter by country.
class IspPicker extends StatefulWidget {
  const IspPicker({super.key, required this.m, this.onBack, required this.onApplied, this.embedded = false});
  final IspMembership m;
  final VoidCallback? onBack;
  final VoidCallback onApplied;
  final bool embedded;

  @override
  State<IspPicker> createState() => _IspPickerState();
}

class _IspPickerState extends State<IspPicker> {
  String country = 'all';
  String query = '';

  Future<void> _pick(IspIp ip) async {
    HapticFeedback.mediumImpact();
    await AppScope.read(context).setTarget(widget.m.id, IspTarget(ip));
    if (mounted) widget.onApplied();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final current = app.targetFor(widget.m.id);
    final selectedId = current is IspTarget ? current.ip.id : null;
    final pad = widget.embedded ? 20.0 : context.pagePadding;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return PageScaffold(
      background: widget.embedded ? Colors.transparent : Sf.bgDeepest,
      header: Column(children: [
        SfTopBar(
          title: 'Choose an IP',
          onBack: widget.onBack,
          border: false,
          actions: [Padding(padding: const EdgeInsets.only(right: 6), child: SfPill('${widget.m.ipCount} IPs'))],
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 4, pad, 10),
          child: Column(children: [
            SfSearchField(value: query, onChanged: (v) => setState(() => query = v), hint: 'Search IP, city or carrier'),
            if (widget.m.countries.length > 1) ...[
              const SizedBox(height: 10),
              SfSegmented<String>(
                value: country,
                onChanged: (c) => setState(() => country = c),
                options: [
                  ('all', const Text('All')),
                  for (final c in widget.m.countries)
                    (c, Row(mainAxisSize: MainAxisSize.min, children: [SfFlag(c, width: 16), const SizedBox(width: 6), Text(c.toUpperCase())])),
                ],
              ),
            ],
          ]),
        ),
      ]),
      body: AsyncValue<List<IspIp>>(
        cacheKey: widget.m.id,
        load: () => app.api.ispIps(widget.m.id),
        builder: (context, data, loading) {
          if (loading && data == null) return ListView(padding: EdgeInsets.symmetric(horizontal: pad - 8), children: const [RowsSkeleton(count: 6)]);
          final q = query.trim().toLowerCase();
          final list = (data ?? const <IspIp>[]).where((ip) =>
              (country == 'all' || ip.country == country) &&
              (q.isEmpty || ip.ip.contains(q) || (ip.city?.toLowerCase().contains(q) ?? false) || ip.isp.toLowerCase().contains(q)));
          final groups = <String, List<IspIp>>{};
          for (final ip in list) {
            groups.putIfAbsent('${ip.country}|${ip.city ?? ''}', () => []).add(ip);
          }
          if (groups.isEmpty) {
            return ListView(children: const [EmptyState(icon: SfIcons.search, title: 'No IPs match', body: 'Try a different IP, city or carrier.')]);
          }
          var i = 0;
          return ListView(
            padding: EdgeInsets.fromLTRB(pad - 8, 4, pad - 8, 24 + bottom),
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            children: [
              for (final MapEntry(:key, :value) in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                  child: SectionLabel(
                    value.first.city ?? key.split('|').first.toUpperCase(),
                    leading: SfFlag(key.split('|').first, width: 16),
                    trailing: Text('${value.length}', style: const TextStyle(fontFamily: 'GeistMono', fontSize: 11.5, color: Sf.textMuted)),
                  ),
                ),
                for (final ip in value)
                  FadeSlideIn(
                    delay: FadeSlideIn.stagger(i++, stepMs: 18, maxSteps: 16),
                    offset: 6,
                    child: SfRow(
                      leading: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Sf.success,
                          shape: BoxShape.circle,
                          boxShadow: [BoxShadow(color: Color(0x263DBA78), spreadRadius: 3)],
                        ),
                      ),
                      title: ip.ip,
                      mono: true,
                      subtitle: ip.isp,
                      selected: ip.id == selectedId,
                      onTap: () => _pick(ip),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ],
          );
        },
      ),
    );
  }
}
