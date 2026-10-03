import 'package:flutter/material.dart';

import 'preview/devices.dart';
import 'preview/device_frame.dart';
import 'shifter_app.dart';
import 'theme/theme.dart';
import 'theme/tokens.dart';
import 'ui/widgets/icons.dart';
import 'ui/widgets/primitives.dart';

/// Device preview studio for macOS: runs the real app inside simulated
/// phones, foldables, tablets and desktop windows.
///
///   flutter run -d macos -t lib/main_preview.dart
void main() => runApp(const PreviewStudioApp());

class PreviewStudioApp extends StatelessWidget {
  const PreviewStudioApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shifter · Device preview',
      debugShowCheckedModeBanner: false,
      theme: buildShifterTheme(),
      home: const PreviewStudio(),
    );
  }
}

enum _Mode { single, gallery }

class PreviewStudio extends StatefulWidget {
  const PreviewStudio({super.key, this.initialDevice = 'iphone-15', this.initialScenario = Scenario.signedOut});
  final String initialDevice;
  final Scenario initialScenario;
  @override
  State<PreviewStudio> createState() => _PreviewStudioState();
}

class _PreviewStudioState extends State<PreviewStudio> {
  _Mode mode = _Mode.single;
  late String deviceId = widget.initialDevice;
  bool landscape = false;
  late Scenario scenario = widget.initialScenario;
  bool connected = false;
  int generation = 0;

  /// Keeps the single-device app alive while switching devices, so you can
  /// change screen size mid-flow exactly like rotating or unfolding.
  GlobalKey _singleKey = GlobalKey();

  PreviewDevice get device => deviceById(deviceId);

  void _restart() => setState(() {
        generation++;
        _singleKey = GlobalKey();
      });

  Widget _app(Key key) => ShifterApp(key: key, demoKey: scenario.key, demoConnected: connected && scenario.key != null);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Sf.bgDeep,
      child: Column(children: [
        _toolbar(),
        Expanded(
          child: Row(children: [
            if (mode == _Mode.single) _deviceList(),
            Expanded(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: RadialGradient(center: Alignment(0, -0.6), radius: 1.2, colors: [Color(0xFF111726), Sf.bgDeep]),
                ),
                child: mode == _Mode.single ? _single() : _gallery(),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  // ── Toolbar ───────────────────────────────────────────────────────────

  Widget _toolbar() {
    final d = device;
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(color: Sf.bgDeepest, border: Border(bottom: BorderSide(color: Sf.borderSubtle))),
      child: Row(children: [
        const Glyph(size: 24),
        const SizedBox(width: 10),
        Text('Device preview', style: SfText.bodyStrong),
        const SizedBox(width: 20),
        SizedBox(
          width: 220,
          child: SfSegmented<_Mode>(
            value: mode,
            onChanged: (m) => setState(() => mode = m),
            options: const [(_Mode.single, Text('Single device')), (_Mode.gallery, Text('All sizes'))],
          ),
        ),
        const SizedBox(width: 14),
        _ScenarioMenu(value: scenario, onChanged: (s) => setState(() {
              scenario = s;
              _restart();
            })),
        const SizedBox(width: 14),
        Opacity(
          opacity: scenario.key == null ? 0.4 : 1,
          child: Row(children: [
            SfToggle(
              value: connected,
              onChanged: (v) {
                if (scenario.key == null) return;
                setState(() {
                  connected = v;
                  _restart();
                });
              },
            ),
            const SizedBox(width: 8),
            Text('Start connected', style: SfText.small.copyWith(color: Sf.textSecondary)),
          ]),
        ),
        const Spacer(),
        if (mode == _Mode.single && d.foldPartner != null) ...[
          SfButton(
            label: Text(d.id.endsWith('inner') ? 'Fold' : 'Unfold'),
            leading: const SfIcon(SfIcons.layers, size: 15, color: Sf.accentLight),
            variant: SfButtonVariant.secondary,
            small: true,
            onPressed: () => setState(() => deviceId = d.foldPartner!),
          ),
          const SizedBox(width: 8),
        ],
        if (mode == _Mode.single && !d.isDesktop) ...[
          SfButton(
            label: Text(landscape ? 'Portrait' : 'Landscape'),
            leading: const SfIcon(SfIcons.refresh, size: 15, color: Sf.textSecondary),
            variant: SfButtonVariant.ghost,
            small: true,
            onPressed: () => setState(() => landscape = !landscape),
          ),
          const SizedBox(width: 8),
        ],
        SfButton(
          label: const Text('Restart app'),
          leading: const SfIcon(SfIcons.power, size: 15, color: Sf.textSecondary),
          variant: SfButtonVariant.ghost,
          small: true,
          onPressed: _restart,
        ),
      ]),
    );
  }

  // ── Single device ─────────────────────────────────────────────────────

  Widget _deviceList() {
    String sizeClass(Size s) => s.width < 600 ? 'Compact' : s.width < 1024 ? 'Medium' : 'Expanded';
    final groups = {
      DeviceGroup.phone: 'Phones',
      DeviceGroup.foldable: 'Foldables',
      DeviceGroup.tablet: 'Tablets',
      DeviceGroup.desktop: 'Desktop',
    };
    return Container(
      width: 272,
      decoration: const BoxDecoration(color: Sf.bgDeepest, border: Border(right: BorderSide(color: Sf.borderSubtle))),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
        children: [
          for (final g in groups.entries) ...[
            Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 0), child: SectionLabel(g.value)),
            for (final d in previewDevices.where((d) => d.group == g.key))
              Builder(builder: (context) {
                final s = d.sizeFor(landscape);
                final selected = d.id == deviceId;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Pressable(
                    onTap: () => setState(() => deviceId = d.id),
                    scale: 0.98,
                    hoverColor: selected ? null : const Color(0x08FFFFFF),
                    borderRadius: BorderRadius.circular(Sf.r),
                    child: AnimatedContainer(
                      duration: Sf.fast,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      decoration: BoxDecoration(
                        color: selected ? Sf.accentSoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(Sf.r),
                        border: Border.all(color: selected ? const Color(0x402B7FFF) : Colors.transparent),
                      ),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(d.name, style: SfText.body.copyWith(fontSize: 13.5, color: selected ? Sf.textPrimary : Sf.textSecondary)),
                            const SizedBox(height: 2),
                            Text('${s.width.round()} × ${s.height.round()}', style: SfText.mono.copyWith(fontSize: 11.5, color: Sf.textMuted)),
                          ]),
                        ),
                        SfPill(sizeClass(s), tone: s.width < 600 ? SfTone.neutral : s.width < 1024 ? SfTone.purple : SfTone.info),
                      ]),
                    ),
                  ),
                );
              }),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0x08FFFFFF), borderRadius: BorderRadius.circular(Sf.r), border: Border.all(color: Sf.borderSubtle)),
            child: Text(
              'The app keeps its state when you switch devices, rotate or fold, so you can watch a screen reflow live.',
              style: SfText.micro.copyWith(fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _single() {
    final d = device;
    final s = d.sizeFor(landscape);
    return Column(children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 12),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: DeviceFrame(device: d, landscape: landscape, child: _app(_singleKey)),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(d.name, style: SfText.body.copyWith(fontSize: 13.5)),
          const SizedBox(width: 10),
          Text('${s.width.round()} × ${s.height.round()} pt', style: SfText.mono.copyWith(fontSize: 12, color: Sf.textMuted)),
          if (d.note != null) ...[const SizedBox(width: 10), Text('· ${d.note}', style: SfText.micro)],
        ]),
      ),
    ]);
  }

  // ── Gallery ───────────────────────────────────────────────────────────

  Widget _gallery() {
    final devices = galleryDeviceIds.map(deviceById).toList();
    return LayoutBuilder(builder: (context, c) {
      final outers = devices.map((d) => DeviceFrame.outerSize(d, false)).toList();
      const gap = 28.0;
      final sumAspect = outers.fold<double>(0, (a, s) => a + s.width / s.height);
      final h = ((c.maxWidth - 64 - gap * (devices.length - 1)) / sumAspect).clamp(380.0, c.maxHeight - 90);
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(32),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final (i, d) in devices.indexed) ...[
            if (i > 0) const SizedBox(width: gap),
            Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: h,
                width: h * outers[i].width / outers[i].height,
                child: FittedBox(
                  child: DeviceFrame(
                    device: d,
                    landscape: false,
                    child: _app(ValueKey('g-${d.id}-${scenario.name}-$connected-$generation')),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(d.name, style: SfText.body.copyWith(fontSize: 13)),
              const SizedBox(height: 2),
              Text('${d.size.width.round()} × ${d.size.height.round()}', style: SfText.mono.copyWith(fontSize: 11.5, color: Sf.textMuted)),
            ]),
          ],
        ]),
      );
    });
  }
}

class _ScenarioMenu extends StatelessWidget {
  const _ScenarioMenu({required this.value, required this.onChanged});
  final Scenario value;
  final ValueChanged<Scenario> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Scenario>(
      tooltip: 'Mock account scenario',
      color: Sf.bgElevated,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Sf.r + 2), side: const BorderSide(color: Sf.borderMedium)),
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final s in Scenario.values)
          PopupMenuItem(
            value: s,
            child: Row(children: [
              SizedBox(width: 22, child: s == value ? const SfIcon(SfIcons.check, size: 15, color: Sf.accentLight, strokeWidth: 2.4) : null),
              Text(s.label, style: SfText.body.copyWith(fontSize: 13.5)),
            ]),
          ),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0x0AFFFFFF),
          borderRadius: BorderRadius.circular(Sf.r + 1),
          border: Border.all(color: Sf.borderSubtle),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const SfIcon(SfIcons.user, size: 15, color: Sf.textTertiary),
          const SizedBox(width: 8),
          Text(value.label, style: SfText.body.copyWith(fontSize: 13.5)),
          const SizedBox(width: 6),
          const SfIcon(SfIcons.chevronDown, size: 15, color: Sf.textTertiary),
        ]),
      ),
    );
  }
}
