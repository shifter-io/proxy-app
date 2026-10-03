import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/format.dart';
import '../../../data/geo_catalog.dart';
import '../../../data/models.dart';
import '../../../state/app_controller.dart';
import '../../../theme/theme.dart';
import '../../../theme/tokens.dart';
import '../../widgets/icons.dart';
import '../../widgets/layout.dart';
import '../../widgets/primitives.dart';
import 'async_list.dart';

enum _Level { countries, country, region }

enum _Tab { regions, cities, isp }

/// Residential targeting. Two ways in, one result:
///  - Search: one box across countries, states, cities and ISPs (tap = use it).
///  - Browse: Country → State → City, with the ISP as an extra filter at
///    every level. The chip bar at the bottom shows exactly what will be
///    sent; "Use" commits it.
class ResidentialPicker extends StatefulWidget {
  const ResidentialPicker({super.key, required this.m, this.onBack, required this.onApplied, this.embedded = false});
  final ResidentialMembership m;
  final VoidCallback? onBack;
  final VoidCallback onApplied;
  final bool embedded;

  @override
  State<ResidentialPicker> createState() => _ResidentialPickerState();
}

class _ResidentialPickerState extends State<ResidentialPicker> {
  late ResidentialTarget draft;
  _Level level = _Level.countries;
  GeoCountry? country;
  GeoRegion? region;
  _Tab countryTab = _Tab.regions;
  _Tab regionTab = _Tab.cities;
  String query = '';
  String debounced = '';
  Timer? _debounce;
  bool _forward = true;

  bool get countryOnly => !poolTargeting(widget.m.pool).subCountry;

  @override
  void initState() {
    super.initState();
    final current = AppScope.read(context).targetFor(widget.m.id);
    draft = current is ResidentialTarget ? current : ResidentialTarget.worldwide;
    if (!countryOnly && draft.country != null) {
      country = draft.country;
      region = draft.region;
      level = region != null ? _Level.region : _Level.country;
    }
    if (draft.asn != null) {
      countryTab = _Tab.isp;
      regionTab = _Tab.isp;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _go(_Level next, {GeoCountry? c, GeoRegion? r, bool forward = true}) {
    setState(() {
      _forward = forward;
      level = next;
      country = c ?? country;
      region = r;
      query = '';
      debounced = '';
    });
  }

  void _up() {
    switch (level) {
      case _Level.region:
        _go(_Level.country, forward: false);
      case _Level.country:
        _go(_Level.countries, forward: false);
      case _Level.countries:
        widget.onBack?.call();
    }
  }

  Future<void> _apply(ResidentialTarget t) async {
    HapticFeedback.mediumImpact();
    final app = AppScope.read(context);
    await app.setTarget(widget.m.id, t);
    if (!mounted) return;
    setState(() => draft = t);
    widget.onApplied();
  }

  void _setDraft(ResidentialTarget t) {
    HapticFeedback.selectionClick();
    setState(() => draft = t);
  }

  /// Moves the draft to a new place, keeping the picked ISP only when it is
  /// still available there.
  void _setPlace(GeoCountry c, {GeoRegion? r, GeoCity? city}) {
    final asn = draft.asn;
    final available = asn == null
        ? false
        : (GeoCatalog.instance?.isps(c.code, region: r?.slug, city: city?.slug).any((a) => a.asn == asn.asn) ?? false);
    _setDraft(ResidentialTarget(country: c, region: r, city: city, asn: available ? asn : null));
  }

  void _onQuery(String v) {
    setState(() => query = v);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => debounced = v.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final title = switch (level) {
      _Level.countries => 'Choose location',
      _Level.country => country!.name,
      _Level.region => region!.name,
    };
    final hint = switch (level) {
      _Level.countries => countryOnly ? 'Search countries' : 'Search country, state, city or ISP',
      _Level.country => 'Search in ${country!.name}',
      _Level.region => 'Search in ${region!.name}',
    };
    final pad = widget.embedded ? 20.0 : context.pagePadding;
    final current = app.targetFor(widget.m.id);
    final canGoUp = level != _Level.countries || widget.onBack != null;
    final viewKey = ValueKey('$level${country?.code}${region?.slug}');

    return PageScaffold(
      background: widget.embedded ? Colors.transparent : Sf.bgDeepest,
      header: Column(children: [
        SfTopBar(
          title: title,
          onBack: canGoUp ? _up : null,
          border: false,
          actions: [Padding(padding: const EdgeInsets.only(right: 6), child: SfPill(poolLabel(widget.m.pool), tone: SfTone.info))],
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 4, pad, 10),
          child: SfSearchField(key: ValueKey(level), value: query, onChanged: _onQuery, hint: hint),
        ),
      ]),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 380),
        switchInCurve: Sf.easeOutExpo,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, a) {
          final dir = (_forward ? 1 : -1) * (child.key == viewKey ? 1 : -1);
          return FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween(begin: Offset(0.12 * dir, 0), end: Offset.zero).animate(a), child: child),
          );
        },
        child: KeyedSubtree(key: viewKey, child: _body(pad)),
      ),
      footer: countryOnly
          ? null
          : _SelectionBar(
              draft: draft,
              onChange: _setDraft,
              unchanged: current != null && sameTarget(current, draft),
              onApply: () => _apply(draft),
            ),
    );
  }

  Widget _body(double pad) {
    final bottom = countryOnly ? MediaQuery.paddingOf(context).bottom : 0.0;
    final listPad = EdgeInsets.fromLTRB(pad - 8, 4, pad - 8, 20 + bottom);
    return switch (level) {
      _Level.countries => _countries(listPad),
      _Level.country => _countryView(listPad),
      _Level.region => _regionView(listPad),
    };
  }

  /// Lazy list: thousands of cities stay smooth. Only the first rows cascade in.
  Widget _lazy(EdgeInsets padding, List<Widget Function()> items) {
    return ListView.builder(
      padding: padding,
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      itemCount: items.length,
      itemBuilder: (_, i) => i < 18 ? FadeSlideIn(delay: FadeSlideIn.stagger(i, stepMs: 20, maxSteps: 18), offset: 6, child: items[i]()) : items[i](),
    );
  }

  Widget _label(String text, {Widget? trailing}) =>
      Padding(padding: const EdgeInsets.fromLTRB(8, 18, 8, 0), child: SectionLabel(text, trailing: trailing));

  // ── Level 1: countries + global search ────────────────────────────────

  Widget _countries(EdgeInsets padding) {
    final app = AppScope.of(context);
    if (debounced.isNotEmpty) {
      return AsyncValue<List<GeoSearchResult>>(
        cacheKey: debounced,
        load: () => app.api.searchGeo(debounced),
        builder: (context, data, loading) {
          final hits = (data ?? const <GeoSearchResult>[]).where((h) => !countryOnly || h.kind == GeoHitKind.country).toList();
          if (loading && data == null) return ListView(padding: padding, children: const [RowsSkeleton(count: 4)]);
          if (hits.isEmpty) {
            return ListView(padding: padding, children: [
              EmptyState(icon: SfIcons.search, title: 'No matches', body: 'Nothing found for “$debounced”. Try a country, state, city or ISP.'),
            ]);
          }
          return _lazy(padding, [for (final h in hits) () => _SearchHitRow(hit: h, onTap: () => _apply(_hitToTarget(h)))]);
        },
      );
    }

    final recent = app.recentTargets
        .map((t) => clampTarget(t, widget.m.pool))
        .fold<List<ResidentialTarget>>([], (acc, t) => acc.any((o) => sameTarget(o, t)) ? acc : [...acc, t]);

    return AsyncValue<List<GeoCountry>>(
      cacheKey: 'countries',
      load: app.api.countries,
      builder: (context, data, loading) {
        final all = data ?? const <GeoCountry>[];
        final popular = [for (final code in popularCountries) ...all.where((c) => c.code == code)];
        return _lazy(padding, [
          if (poolLimitNote(widget.m.pool) != null) () => _LimitNote(poolLimitNote(widget.m.pool)!),
          () => SfRow(
                leading: const SfFlag(null),
                title: 'Random location',
                subtitle: 'Best available IP, anywhere',
                selected: draft.country == null,
                onTap: () => _apply(ResidentialTarget.worldwide),
              ),
          if (recent.isNotEmpty) ...[
            () => _label('Recent'),
            for (final t in recent.take(3))
              () {
                final d = describeTarget(t);
                return SfRow(leading: SfFlag(t.country?.code), title: d.title, subtitle: d.subtitle, trailingIcon: SfIcons.history, onTap: () => _apply(t));
              },
          ],
          () => _label('Popular'),
          if (loading && data == null) () => const RowsSkeleton(count: 3),
          for (final c in popular) () => _countryRow(c),
          () => _label('All countries', trailing: CountText(data?.length)),
          if (loading && data == null) () => const RowsSkeleton(count: 6),
          for (final c in all) () => _countryRow(c),
        ]);
      },
    );
  }

  Widget _countryRow(GeoCountry c) => SfRow(
        leading: SfFlag(c.code),
        title: c.name,
        selected: draft.country?.code == c.code,
        trailingIcon: countryOnly ? null : SfIcons.chevronRight,
        onTap: () {
          if (countryOnly) {
            _apply(ResidentialTarget(country: c));
            return;
          }
          if (draft.country?.code != c.code) draft = ResidentialTarget(country: c);
          _go(_Level.country, c: c);
        },
      );

  // ── Level 2: inside a country ─────────────────────────────────────────

  Widget _countryView(EdgeInsets padding) {
    final app = AppScope.of(context);
    final c = country!;
    final q = query.trim().toLowerCase();
    bool match(String s) => q.isEmpty || s.toLowerCase().contains(q);

    return AsyncValue<(List<GeoRegion>, List<GeoCity>)>(
      cacheKey: c.code,
      load: () async => (await app.api.regions(c.code), await app.api.cities(c.code)),
      builder: (context, data, loading) {
        final regions = data?.$1 ?? const <GeoRegion>[];
        final cities = data?.$2 ?? const <GeoCity>[];
        final regionBySlug = {for (final r in regions) r.slug: r};
        final inThisCountry = draft.country?.code == c.code;

        final List<Widget Function()> rows;
        switch (countryTab) {
          case _Tab.regions:
            final list = regions.where((r) => match(r.name)).toList();
            rows = list.isEmpty
                ? [() => const _NoneHere('states')]
                : [
                    for (final r in list)
                      () => SfRow(
                            leading: const SfIcon(SfIcons.map, size: 17, color: Sf.textTertiary),
                            title: r.name,
                            selected: inThisCountry && draft.region?.slug == r.slug,
                            subtitle: inThisCountry && draft.region?.slug == r.slug && draft.city != null ? draft.city!.name : null,
                            trailingIcon: SfIcons.chevronRight,
                            onTap: () {
                              if (draft.region?.slug != r.slug) _setPlace(c, r: r);
                              _go(_Level.region, r: r);
                            },
                          ),
                  ];
          case _Tab.cities:
            final list = cities.where((x) => match(x.name)).toList();
            rows = list.isEmpty
                ? [() => const _NoneHere('cities')]
                : [
                    for (final city in list)
                      () => SfRow(
                            leading: const SfIcon(SfIcons.pin, size: 17, color: Sf.textTertiary),
                            title: city.name,
                            subtitle: regionBySlug[city.regionSlug]?.name,
                            selected: inThisCountry && draft.city?.slug == city.slug && draft.region?.slug == city.regionSlug,
                            onTap: () => _setPlace(c, r: regionBySlug[city.regionSlug], city: city),
                          ),
                  ];
          case _Tab.isp:
            rows = _ispRows(c, inThisCountry ? draft.region : null, inThisCountry ? draft.city : null, match);
        }

        return _lazy(padding, [
          () => SfRow(
                leading: SfFlag(c.code),
                title: 'Any location in ${c.name}',
                subtitle: 'Country-level targeting',
                selected: inThisCountry && draft.region == null && draft.city == null,
                onTap: () => _setPlace(c),
              ),
          () => Padding(
                padding: const EdgeInsets.fromLTRB(6, 12, 6, 12),
                child: SfSegmented<_Tab>(
                  value: countryTab,
                  onChanged: (t) => setState(() => countryTab = t),
                  options: [
                    (_Tab.regions, _TabLabel('States', loading ? null : regions.length)),
                    (_Tab.cities, _TabLabel('Cities', loading ? null : cities.length)),
                    (_Tab.isp, const _TabLabel('ISP', null)),
                  ],
                ),
              ),
          if (loading && data == null) () => const RowsSkeleton() else ...rows,
        ]);
      },
    );
  }

  // ── Level 3: inside a state/region ────────────────────────────────────

  Widget _regionView(EdgeInsets padding) {
    final app = AppScope.of(context);
    final c = country!;
    final r = region!;
    final q = query.trim().toLowerCase();
    bool match(String s) => q.isEmpty || s.toLowerCase().contains(q);

    return AsyncValue<List<GeoCity>>(
      cacheKey: '${c.code}/${r.slug}',
      load: () => app.api.cities(c.code, region: r.slug),
      builder: (context, data, loading) {
        final inThisRegion = draft.country?.code == c.code && draft.region?.slug == r.slug;
        final List<Widget Function()> rows;
        if (regionTab == _Tab.isp) {
          rows = _ispRows(c, r, inThisRegion ? draft.city : null, match);
        } else {
          final list = (data ?? const <GeoCity>[]).where((x) => match(x.name)).toList();
          rows = [
            if (!loading && list.isEmpty) () => const _NoneHere('cities'),
            for (final city in list)
              () => SfRow(
                    leading: const SfIcon(SfIcons.pin, size: 17, color: Sf.textTertiary),
                    title: city.name,
                    selected: inThisRegion && draft.city?.slug == city.slug,
                    onTap: () => _setPlace(c, r: r, city: city),
                  ),
          ];
        }

        return _lazy(padding, [
          () => SfRow(
                leading: const SfIcon(SfIcons.map, size: 17, color: Sf.textTertiary),
                title: 'Any city in ${r.name}',
                subtitle: 'State-level · ${c.name}',
                selected: inThisRegion && draft.city == null,
                onTap: () => _setPlace(c, r: r),
              ),
          () => Padding(
                padding: const EdgeInsets.fromLTRB(6, 12, 6, 12),
                child: SfSegmented<_Tab>(
                  value: regionTab,
                  onChanged: (t) => setState(() => regionTab = t),
                  options: [
                    (_Tab.cities, _TabLabel('Cities', loading ? null : data?.length)),
                    (_Tab.isp, const _TabLabel('ISP', null)),
                  ],
                ),
              ),
          if (loading && data == null) () => const RowsSkeleton(count: 4) else ...rows,
        ]);
      },
    );
  }

  /// ISPs for the most specific place picked (city > state > country).
  List<Widget Function()> _ispRows(GeoCountry c, GeoRegion? r, GeoCity? city, bool Function(String) match) {
    final catalog = GeoCatalog.instance;
    final scopeName = city?.name ?? r?.name ?? c.name;
    final q = query.trim().toLowerCase().replaceFirst(RegExp(r'^as(?=\d)'), '');
    final list = (catalog?.isps(c.code, region: r?.slug, city: city?.slug) ?? const <GeoAsn>[])
        .where((a) => match(a.name) || (q.isNotEmpty && '${a.asn}'.startsWith(q)))
        .toList();
    return [
      () => Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text(
              'ISPs available in $scopeName. Pick one to only get IPs from that provider.',
              style: SfText.micro.copyWith(fontSize: 12.5, height: 1.5),
            ),
          ),
      if (list.isEmpty) () => const _NoneHere('ISPs'),
      for (final a in list)
        () => SfRow(
              leading: const SfIcon(SfIcons.network, size: 17, color: Sf.textTertiary),
              title: a.name,
              subtitle: 'AS${a.asn}',
              selected: draft.country?.code == c.code && draft.asn?.asn == a.asn,
              onTap: () => _setDraft(ResidentialTarget(
                country: c,
                region: r,
                city: city,
                asn: draft.asn?.asn == a.asn ? null : a,
              )),
            ),
    ];
  }
}

ResidentialTarget _hitToTarget(GeoSearchResult h) =>
    ResidentialTarget(country: h.country, region: h.region, city: h.city, asn: h.asn);

class _SearchHitRow extends StatelessWidget {
  const _SearchHitRow({required this.hit, required this.onTap});
  final GeoSearchResult hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = hit;
    final title = switch (h.kind) {
      GeoHitKind.asn => h.asn!.name,
      GeoHitKind.city => h.city!.name,
      GeoHitKind.region => h.region!.name,
      GeoHitKind.country => h.country.name,
    };
    final subtitle = switch (h.kind) {
      GeoHitKind.asn => 'AS${h.asn!.asn} · ${h.country.name}',
      GeoHitKind.city => [h.region?.name, h.country.name].whereType<String>().join(', '),
      GeoHitKind.region => h.country.name,
      GeoHitKind.country => 'Any city',
    };
    final (label, icon) = switch (h.kind) {
      GeoHitKind.country => ('Country', SfIcons.globe),
      GeoHitKind.region => ('State', SfIcons.map),
      GeoHitKind.city => ('City', SfIcons.pin),
      GeoHitKind.asn => ('ISP', SfIcons.network),
    };
    return SfRow(
      leading: SfFlag(h.country.code),
      title: title,
      subtitle: subtitle,
      onTap: onTap,
      trailing: SfPill(label, icon: icon),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel(this.text, this.count);
  final String text;
  final int? count;
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(text),
      if (count != null) ...[const SizedBox(width: 6), Text('$count', style: SfText.mono.copyWith(fontSize: 11.5, color: Sf.textMuted))],
    ]);
  }
}

class _NoneHere extends StatelessWidget {
  const _NoneHere(this.what);
  final String what;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
        child: Text('No $what match your search.', textAlign: TextAlign.center, style: SfText.small.copyWith(color: Sf.textMuted)),
      );
}

class _LimitNote extends StatelessWidget {
  const _LimitNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(6, 0, 6, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x08FFFFFF),
        borderRadius: BorderRadius.circular(Sf.r + 1),
        border: Border.all(color: Sf.borderSubtle),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 2), child: SfIcon(SfIcons.lock, size: 14, color: Sf.textTertiary)),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: SfText.small.copyWith(height: 1.5))),
      ]),
    );
  }
}

/// Bottom bar: breadcrumb chips of exactly what will be targeted + Use.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.draft, required this.onChange, required this.onApply, required this.unchanged});
  final ResidentialTarget draft;
  final ValueChanged<ResidentialTarget> onChange;
  final VoidCallback onApply;
  final bool unchanged;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final pad = context.pagePadding;
    final chips = <(String, Widget, VoidCallback)>[];
    if (draft.country != null) {
      chips.add((
        'country',
        Row(mainAxisSize: MainAxisSize.min, children: [SfFlag(draft.country!.code, width: 16), const SizedBox(width: 6), Text(draft.country!.name)]),
        () => onChange(ResidentialTarget.worldwide),
      ));
    }
    if (draft.region != null) {
      chips.add(('region', Text(draft.region!.name), () => onChange(draft.copyWith(region: () => null, city: () => null))));
    }
    if (draft.city != null) chips.add(('city', Text(draft.city!.name), () => onChange(draft.copyWith(city: () => null))));
    if (draft.asn != null) chips.add(('asn', ConstrainedBox(constraints: const BoxConstraints(maxWidth: 170), child: Text(draft.asn!.name, maxLines: 1, overflow: TextOverflow.ellipsis)), () => onChange(draft.copyWith(asn: () => null))));

    return Container(
      padding: EdgeInsets.fromLTRB(pad, 12, pad, 14 + bottom),
      decoration: const BoxDecoration(
        color: Color(0xF2131927),
        border: Border(top: BorderSide(color: Sf.borderSubtle)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Sf.easeOutExpo,
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 30),
            child: Align(
              alignment: Alignment.centerLeft,
              child: chips.isEmpty
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      const SfFlag(null, width: 18),
                      const SizedBox(width: 8),
                      Text('Random location worldwide', style: SfText.small),
                    ])
                  : Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      for (final (i, (key, label, clear)) in chips.indexed) ...[
                        if (i > 0)
                          key == 'asn'
                              ? Text('+', style: SfText.small.copyWith(color: Sf.textFaint))
                              : const SfIcon(SfIcons.chevronRight, size: 13, color: Sf.textFaint),
                        PopIn(key: ValueKey('$key-${label.hashCode}'), child: _Chip(label: label, onClear: clear)),
                      ],
                    ]),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SfButton(
          label: Text(unchanged ? 'Keep this location' : 'Use this location'),
          trailing: const SfIcon(SfIcons.arrowRight, size: 16, color: Colors.white, strokeWidth: 2.2),
          expand: true,
          onPressed: onApply,
        ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onClear});
  final Widget label;
  final VoidCallback onClear;
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: 10, right: 2),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(Sf.rMd),
        border: Border.all(color: Sf.borderSubtle),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        DefaultTextStyle(style: SfText.small.copyWith(color: Sf.textPrimary, fontWeight: FontWeight.w500), child: label),
        SfIconButton(icon: SfIcons.x, size: 26, iconSize: 12, tooltip: 'Remove', onTap: onClear),
      ]),
    );
  }
}
