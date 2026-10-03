import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/format.dart';
import '../../data/models.dart';
import '../../proxy/bypass.dart';
import '../../state/app_controller.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../links.dart';
import '../widgets/icons.dart';
import '../widgets/layout.dart';
import '../widgets/primitives.dart';

const _ttlPresets = [60, 300, 600, 1800, 3600];
const _ttlMin = 30;
const _ttlMax = 24 * 3600;

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.onBack, this.embedded = false});
  final VoidCallback? onBack;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.settings;
    final pad = context.pagePadding;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final sticky = s.sessionMode == SessionMode.sticky;
    var i = 0;
    Widget section(Widget w) => FadeSlideIn(delay: FadeSlideIn.stagger(i++, stepMs: 60), child: Padding(padding: const EdgeInsets.only(bottom: 26), child: w));

    return PageScaffold(
      header: embedded ? const SfTopBar(title: 'Settings', large: true) : SfTopBar(title: 'Settings', onBack: onBack),
      body: ListView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: EdgeInsets.fromLTRB(pad, embedded ? 4 : 20, pad, 28 + bottom),
        children: [
          MaxWidth(
            maxWidth: 640,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // ── Session ───────────────────────────────────────────────
              section(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('IP session'),
                SfCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SfSegmented<SessionMode>(
                      value: s.sessionMode,
                      onChanged: (v) => app.updateSettings(s.copyWith(sessionMode: v)),
                      options: const [
                        (SessionMode.sticky, Row(mainAxisSize: MainAxisSize.min, children: [SfIcon(SfIcons.clock, size: 15), SizedBox(width: 6), Text('Sticky')])),
                        (SessionMode.rotating, Row(mainAxisSize: MainAxisSize.min, children: [SfIcon(SfIcons.shuffle, size: 15), SizedBox(width: 6), Text('Rotating')])),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SfSwitcher(
                      child: Text(
                        sticky
                            ? 'Keep the same exit IP for a while. Best for logins, carts and anything with a session.'
                            : 'A fresh exit IP on every request. Best for scraping and price checks.',
                        key: ValueKey(sticky),
                        style: SfText.bodyMuted.copyWith(fontSize: 13),
                      ),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 380),
                      curve: Sf.easeOutExpo,
                      alignment: Alignment.topCenter,
                      child: sticky ? _TtlEditor(value: s.ttlSeconds, onChanged: (v) => app.updateSettings(s.copyWith(ttlSeconds: v))) : const SizedBox(width: double.infinity),
                    ),
                  ]),
                ),
              ])),

              // ── Connection ────────────────────────────────────────────
              section(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Connection'),
                SfCard(
                  padding: EdgeInsets.zero,
                  child: Column(children: [
                    _SwitchRow(
                      title: 'Strict location',
                      body: 'Fail instead of falling back to a wider area when the exact city or ISP has no free IP.',
                      value: s.strict,
                      onChanged: (v) => app.updateSettings(s.copyWith(strict: v)),
                    ),
                    const _Divider(),
                    _SwitchRow(
                      title: 'Connect on launch',
                      body: 'Reconnect to your last location when Shifter starts.',
                      value: s.autoConnect,
                      onChanged: (v) => app.updateSettings(s.copyWith(autoConnect: v)),
                    ),
                  ]),
                ),
              ])),

              // ── How traffic is routed (system proxy, not a tunnel) ────
              section(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('How traffic is routed'),
                SfCard(
                  padding: EdgeInsets.zero,
                  child: Column(children: const [
                    _InfoRow(
                      icon: SfIcons.dns,
                      title: 'DNS through Shifter',
                      body: 'Apps that follow the system proxy (browsers and most apps) look sites up at your exit location, not on your local network.',
                    ),
                    _Divider(),
                    _InfoRow(
                      icon: SfIcons.shieldCheck,
                      title: 'What connects directly',
                      body: 'UDP traffic (WebRTC calls, games) and apps that ignore the system proxy don’t go through Shifter. Turn off WebRTC in your browser if it must never show your real IP.',
                    ),
                  ]),
                ),
              ])),

              section(_BypassList(list: s.bypassList, onChanged: (l) => app.updateSettings(s.copyWith(bypassList: l)))),

              // ── Account ───────────────────────────────────────────────
              section(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const SectionLabel('Account'),
                SfCard(
                  padding: EdgeInsets.zero,
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        const IconTile(SfIcons.key, size: 38),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(app.session?.user.email ?? 'API key', style: SfText.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 2),
                            Text(_maskKey(app.session?.apiKey), style: SfText.mono.copyWith(fontSize: 12, color: Sf.textMuted)),
                          ]),
                        ),
                      ]),
                    ),
                    const _Divider(),
                    _LinkRow(text: 'Open Shifter dashboard', onTap: () => openExternal(context, ShifterUrls.panel)),
                    const _Divider(),
                    _LinkRow(text: 'Help & support', onTap: () => openExternal(context, ShifterUrls.support)),
                  ]),
                ),
                const SizedBox(height: 14),
                SfButton(
                  label: const Text('Sign out'),
                  leading: const SfIcon(SfIcons.logout, size: 16, color: Color(0xFFFECACA)),
                  variant: SfButtonVariant.danger,
                  small: true,
                  expand: true,
                  onPressed: () => _confirmSignOut(context, app),
                ),
              ])),
              Text('Shifter app v0.1.0', textAlign: TextAlign.center, style: SfText.micro.copyWith(color: Sf.textFaint)),
            ]),
          ),
        ],
      ),
    );
  }

  static String _maskKey(String? key) => key == null || key.length < 8 ? '' : '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';

  Future<void> _confirmSignOut(BuildContext context, AppController app) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (ctx) => Dialog(
        backgroundColor: Sf.bgElevated,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: Sf.borderMedium)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Align(alignment: Alignment.centerLeft, child: IconTile(SfIcons.logout, tone: SfTone.danger, size: 42)),
              const SizedBox(height: 16),
              Text('Sign out of Shifter?', style: SfText.heading),
              const SizedBox(height: 6),
              Text('This disconnects the proxy and removes your API key from this device.', style: SfText.bodyMuted),
              const SizedBox(height: 22),
              Row(children: [
                Expanded(child: SfButton(label: const Text('Cancel'), variant: SfButtonVariant.ghost, small: true, expand: true, onPressed: () => Navigator.pop(ctx, false))),
                const SizedBox(width: 10),
                Expanded(child: SfButton(label: const Text('Sign out'), variant: SfButtonVariant.danger, small: true, expand: true, onPressed: () => Navigator.pop(ctx, true))),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (ok == true) await app.signOut();
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Container(height: 1, color: Sf.borderSubtle);
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.title, required this.body, required this.value, required this.onChanged});
  final String title;
  final String body;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: () => onChanged(!value),
      scale: 1,
      hoverColor: const Color(0x05FFFFFF),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: SfText.body),
              const SizedBox(height: 3),
              Text(body, style: SfText.small.copyWith(height: 1.45)),
            ]),
          ),
          const SizedBox(width: 12),
          SfToggle(value: value, onChanged: onChanged),
        ]),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.title, required this.body});
  final SfIcons icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconTile(icon, tone: SfTone.success, size: 34),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(title, style: SfText.body)),
              const SizedBox(width: 8),
              const SfPill('Always on', tone: SfTone.success),
            ]),
            const SizedBox(height: 4),
            Text(body, style: SfText.small.copyWith(height: 1.45)),
          ]),
        ),
      ]),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      scale: 1,
      hoverColor: const Color(0x08FFFFFF),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(children: [
          Expanded(child: Text(text, style: SfText.body.copyWith(color: Sf.textSecondary, fontWeight: FontWeight.w400))),
          const SfIcon(SfIcons.external, size: 15, color: Sf.textMuted),
        ]),
      ),
    );
  }
}

class _TtlEditor extends StatelessWidget {
  const _TtlEditor({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  int _clamp(int v) => v.clamp(_ttlMin, _ttlMax);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text('Session length (TTL)', style: SfText.body.copyWith(color: Sf.textSecondary, fontSize: 13.5))),
          Text('${value}s', style: SfText.mono.copyWith(fontSize: 12.5, color: Sf.textTertiary)),
        ]),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth < 280 ? 3 : 5;
          final w = (c.maxWidth - 6 * (cols - 1)) / cols;
          return Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in _ttlPresets)
              SizedBox(
                width: w,
                child: Pressable(
                  onTap: () => onChanged(p),
                  scale: 0.94,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: value == p ? Sf.accentSoft : const Color(0x08FFFFFF),
                      borderRadius: BorderRadius.circular(Sf.rMd),
                      border: Border.all(color: value == p ? const Color(0x592B7FFF) : Sf.borderSubtle),
                    ),
                    child: Text(
                      formatDuration(p),
                      style: TextStyle(
                        fontFamily: kSans,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: value == p ? Sf.accentLight : Sf.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
          ]);
        }),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Text('Custom (seconds)', style: SfText.small.copyWith(color: Sf.textMuted))),
          Container(
            height: 38,
            decoration: BoxDecoration(
              color: Sf.bgInput,
              borderRadius: BorderRadius.circular(Sf.rMd),
              border: Border.all(color: Sf.borderInput),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _StepButton(text: '−', onTap: () => onChanged(_clamp(value - 30))),
              SizedBox(
                width: 64,
                child: Text('$value', textAlign: TextAlign.center, style: SfText.mono.copyWith(fontSize: 13.5)),
              ),
              _StepButton(text: '+', onTap: () => onChanged(_clamp(value + 30))),
            ]),
          ),
        ]),
      ]),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      scale: 0.88,
      hoverColor: const Color(0x0DFFFFFF),
      child: SizedBox(
        width: 38,
        height: 38,
        child: Center(child: Text(text, style: const TextStyle(fontFamily: kSans, fontSize: 17, color: Sf.textTertiary))),
      ),
    );
  }
}


class _BypassList extends StatefulWidget {
  const _BypassList({required this.list, required this.onChanged});
  final List<String> list;
  final ValueChanged<List<String>> onChanged;
  @override
  State<_BypassList> createState() => _BypassListState();
}

class _BypassListState extends State<_BypassList> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add() {
    final host = normalizeBypassRule(_ctl.text);
    if (host == null) {
      HapticFeedback.heavyImpact();
      setState(() => _error = true);
      return;
    }
    if (!widget.list.contains(host)) widget.onChanged([...widget.list, host]);
    _ctl.clear();
    setState(() => _error = false);
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = _error ? const Color(0x99EF4444) : _focus.hasFocus ? Sf.accent : Sf.borderInput;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionLabel('Bypass proxy for'),
      SfCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('These sites and hosts always connect directly, without Shifter.', style: SfText.small.copyWith(height: 1.45)),
          const SizedBox(height: 12),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Sf.easeOutExpo,
            alignment: Alignment.topLeft,
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final h in widget.list)
                PopIn(
                  key: ValueKey(h),
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.only(left: 10, right: 2),
                    decoration: BoxDecoration(
                      color: const Color(0x0DFFFFFF),
                      borderRadius: BorderRadius.circular(Sf.rMd),
                      border: Border.all(color: Sf.borderSubtle),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(h, style: SfText.mono.copyWith(fontSize: 12)),
                      SfIconButton(
                        icon: SfIcons.x,
                        size: 26,
                        iconSize: 12,
                        tooltip: 'Remove $h',
                        onTap: () => widget.onChanged(widget.list.where((x) => x != h).toList()),
                      ),
                    ]),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: AnimatedContainer(
                duration: Sf.fast,
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Sf.bgInput,
                  borderRadius: BorderRadius.circular(Sf.r),
                  border: Border.all(color: borderColor),
                ),
                child: Center(
                  child: TextField(
                    controller: _ctl,
                    focusNode: _focus,
                    onSubmitted: (_) => _add(),
                    onChanged: (_) => _error ? setState(() => _error = false) : null,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    style: const TextStyle(fontFamily: kSans, fontSize: 14, color: Sf.textPrimary),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'example.com or *.example.com',
                      hintStyle: TextStyle(fontFamily: kSans, fontSize: 14, color: Sf.textMuted),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Pressable(
              onTap: _add,
              scale: 0.9,
              semanticLabel: 'Add',
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0x0AFFFFFF),
                  borderRadius: BorderRadius.circular(Sf.r),
                  border: Border.all(color: Sf.borderSubtle),
                ),
                child: const Center(child: SfIcon(SfIcons.plus, size: 17, color: Sf.textSecondary)),
              ),
            ),
          ]),
        ]),
      ),
    ]);
  }
}
