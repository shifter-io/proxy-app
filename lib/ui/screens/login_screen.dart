import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/mock_api.dart';
import '../../state/app_controller.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../links.dart';
import '../widgets/atmosphere.dart';
import '../widgets/icons.dart';
import '../widgets/layout.dart';
import '../widgets/primitives.dart';

enum _Phase { idle, verifying, verified }

/// Sign in with the panel API key (Profile → API Key). Verified as soon as a
/// whole key is pasted or on Continue. Phones get a full-screen form; wide
/// screens get the shifter.io/login split layout.
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    return Material(
      color: Sf.bgDeepest,
      child: wide ? const _WideLogin() : const _CompactLogin(),
    );
  }
}

class _CompactLogin extends StatelessWidget {
  const _CompactLogin();
  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final side = context.pagePadding + 4;
    return Stack(children: [
      const Positioned.fill(child: Atmosphere()),
      LayoutBuilder(builder: (context, c) {
        return SingleChildScrollView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: EdgeInsets.fromLTRB(side, pad.top + 24, side, pad.bottom + 18),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight - pad.top - pad.bottom - 42),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: const IntrinsicHeight(child: _LoginForm(showWordmark: true)),
              ),
            ),
          ),
        );
      }),
    ]);
  }
}

class _WideLogin extends StatelessWidget {
  const _WideLogin();
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        flex: 11,
        child: Container(
          decoration: const BoxDecoration(
            color: Sf.bgDeep,
            border: Border(right: BorderSide(color: Sf.borderSubtle)),
          ),
          child: Stack(children: [
            const Positioned.fill(child: Atmosphere(intensity: 1.3)),
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 48, 56, 40),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Wordmark(height: 28),
                const Spacer(),
                const FadeSlideIn(child: SfEyebrow('Proxy & VPN')),
                const SizedBox(height: 22),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 60),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Text('Browse from anywhere with your Shifter proxies', style: SfText.display.copyWith(fontSize: 40, height: 1.1, letterSpacing: -1.2)),
                  ),
                ),
                const SizedBox(height: 16),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 120),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Text(
                      'Route this device through your Residential and ISP plans. Pick a country, state, city or carrier and connect in one tap.',
                      style: SfText.bodyMuted.copyWith(fontSize: 15.5),
                    ),
                  ),
                ),
                const SizedBox(height: 34),
                for (final (i, (icon, title, body)) in const [
                  (SfIcons.globe, 'Precise targeting', 'Country, state, city and ISP on Full Geo plans.'),
                  (SfIcons.clock, 'Sticky or rotating IPs', 'Keep one IP for a session or get a new one per request.'),
                  (SfIcons.shieldCheck, 'No leaks', 'DNS resolves at your exit; UDP is blocked so WebRTC can’t expose you.'),
                ].indexed)
                  FadeSlideIn(
                    delay: Duration(milliseconds: 180 + 70 * i),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        IconTile(icon, size: 38),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(title, style: SfText.bodyStrong),
                            const SizedBox(height: 3),
                            Text(body, style: SfText.small.copyWith(fontSize: 13.5, height: 1.45)),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                const Spacer(),
                Text('© Shifter · shifter.io', style: SfText.micro),
              ]),
            ),
          ]),
        ),
      ),
      Expanded(
        flex: 9,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(40),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                padding: const EdgeInsets.fromLTRB(30, 34, 30, 26),
                decoration: BoxDecoration(
                  color: Sf.bgElevated,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Sf.borderSubtle),
                  boxShadow: Sf.overlayShadow,
                ),
                child: const _LoginForm(showWordmark: false),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _LoginForm extends StatefulWidget {
  const _LoginForm({required this.showWordmark});
  final bool showWordmark;
  @override
  State<_LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<_LoginForm> with SingleTickerProviderStateMixin {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  late final _shake = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  bool _reveal = false;
  String? _error;
  _Phase _phase = _Phase.idle;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _fail(String msg) {
    HapticFeedback.heavyImpact();
    setState(() => _error = msg);
    _shake.forward(from: 0);
  }

  Future<void> _verify(String raw) async {
    final value = raw.trim();
    if (value.isEmpty) return _fail('Paste your API key to continue.');
    if (!MockShifterApi.keyPattern.hasMatch(value)) {
      return _fail("That doesn't look like a Shifter API key. Copy it again from your dashboard.");
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _phase = _Phase.verifying;
    });
    final app = AppScope.read(context);
    try {
      final session = await app.api.verifyApiKey(value);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _phase = _Phase.verified);
      await Future.delayed(const Duration(milliseconds: 650));
      await app.signIn(session);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      _fail(e.unauthorized
          ? 'This API key is not valid. It may have been regenerated. Copy the current one from your dashboard.'
          : 'Network hiccup. Try again.');
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _focus.requestFocus();
      return;
    }
    _ctl.text = text;
    _verify(text);
  }

  @override
  Widget build(BuildContext context) {
    final busy = _phase != _Phase.idle;
    final borderColor = _error != null ? const Color(0x8CEF4444) : _focus.hasFocus ? Sf.accent : Sf.borderMedium;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (widget.showWordmark) const Align(alignment: Alignment.centerLeft, child: FadeSlideIn(child: Wordmark(height: 26))),
      if (widget.showWordmark) const SizedBox(height: 40),
      FadeSlideIn(
        delay: const Duration(milliseconds: 60),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SfEyebrow('Proxy & VPN'),
          const SizedBox(height: 18),
          Text('Connect your Shifter account', style: SfText.title.copyWith(fontSize: context.isNarrow ? 21 : 24)),
          const SizedBox(height: 10),
          Text('Paste your API key to load your Residential and ISP plans.', style: SfText.bodyMuted),
        ]),
      ),
      const SizedBox(height: 28),
      FadeSlideIn(
        delay: const Duration(milliseconds: 120),
        child: AnimatedBuilder(
          animation: _shake,
          builder: (_, child) {
            final t = _shake.value;
            final dx = math.sin(t * math.pi * 6) * 9 * (1 - t);
            return Transform.translate(offset: Offset(dx, 0), child: child);
          },
          child: AnimatedContainer(
            duration: Sf.fast,
            height: 52,
            decoration: BoxDecoration(
              color: Sf.bgInput,
              borderRadius: BorderRadius.circular(Sf.r + 2),
              border: Border.all(color: borderColor),
              boxShadow: _focus.hasFocus && _error == null ? [BoxShadow(color: Sf.accent.withValues(alpha: 0.15), spreadRadius: 3)] : null,
            ),
            child: Row(children: [
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _ctl,
                  focusNode: _focus,
                  enabled: !busy,
                  obscureText: !_reveal,
                  obscuringCharacter: '•',
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  autofillHints: const [],
                  onSubmitted: _verify,
                  onChanged: (v) {
                    if (_error != null) setState(() => _error = null);
                    // A whole key arriving at once = pasted: verify instantly.
                    if (v.length >= 32 && MockShifterApi.keyPattern.hasMatch(v.trim()) && v.length - (_lastLen) > 20) _verify(v);
                    _lastLen = v.length;
                  },
                  style: SfText.mono.copyWith(fontSize: 14.5, letterSpacing: _reveal ? 0 : 1.5),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Enter your API key',
                    hintStyle: TextStyle(fontFamily: kSans, fontSize: 15, color: Color(0x59FFFFFF), letterSpacing: 0),
                  ),
                ),
              ),
              SfIconButton(icon: _reveal ? SfIcons.eyeOff : SfIcons.eye, tooltip: _reveal ? 'Hide key' : 'Show key', size: 38, iconSize: 17, onTap: busy ? null : () => setState(() => _reveal = !_reveal)),
              SfIconButton(icon: SfIcons.clipboard, tooltip: 'Paste from clipboard', size: 38, iconSize: 17, onTap: busy ? null : _paste),
              const SizedBox(width: 6),
            ]),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            alignment: Alignment.topLeft,
            child: _error == null
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 4, right: 10),
                    child: Text(_error!, style: SfText.small.copyWith(color: Sf.dangerLight, height: 1.45)),
                  ),
          ),
        ),
        SfLinkButton(text: 'Where do I find it?', onTap: () => openExternal(context, ShifterUrls.apiKey), fontSize: 13),
      ]),
      const SizedBox(height: 14),
      SfButton(
        large: true,
        expand: true,
        variant: _phase == _Phase.verified ? SfButtonVariant.success : SfButtonVariant.primary,
        onPressed: busy ? null : () => _verify(_ctl.text),
        label: SfSwitcher(
          duration: const Duration(milliseconds: 220),
          child: switch (_phase) {
            _Phase.idle => const Row(key: ValueKey('i'), mainAxisSize: MainAxisSize.min, children: [
                Text('Continue'),
                SizedBox(width: 8),
                SfIcon(SfIcons.arrowRight, size: 16, color: Colors.white, strokeWidth: 2.2),
              ]),
            _Phase.verifying => const Row(key: ValueKey('v'), mainAxisSize: MainAxisSize.min, children: [
                Text('Verifying key'),
                SizedBox(width: 10),
                SfSpinner(size: 15, color: Colors.white),
              ]),
            _Phase.verified => const Row(key: ValueKey('ok'), mainAxisSize: MainAxisSize.min, children: [
                PopIn(child: SfIcon(SfIcons.check, size: 17, color: Colors.white, strokeWidth: 3)),
                SizedBox(width: 8),
                Text('Verified'),
              ]),
          },
        ),
      ),
      const SizedBox(height: 36),
      Row(children: [
        const Expanded(child: Divider(color: Sf.borderSubtle, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('NEW TO SHIFTER?', style: SfText.label.copyWith(fontSize: 10, letterSpacing: 2)),
        ),
        const Expanded(child: Divider(color: Sf.borderSubtle, height: 1)),
      ]),
      const SizedBox(height: 22),
      SfButton(
        label: const Text('Create a free account'),
        trailing: const SfIcon(SfIcons.external, size: 15, color: Sf.textTertiary),
        variant: SfButtonVariant.ghost,
        expand: true,
        onPressed: () => openExternal(context, ShifterUrls.register),
      ),
      const SizedBox(height: 12),
      Text('Sign up, then copy your key from Profile → API Key.', textAlign: TextAlign.center, style: SfText.micro.copyWith(fontSize: 12.5)),
      const SizedBox(height: 10),
      Center(
        child: SfLinkButton(
          text: 'Preview with a demo key',
          fontSize: 12.5,
          onTap: busy
              ? () {}
              : () {
                  const demo = 'demo0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUV';
                  _ctl.text = demo;
                  _verify(demo);
                },
        ),
      ),
      if (widget.showWordmark) const Spacer(),
      const SizedBox(height: 24),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        const SfIcon(SfIcons.lock, size: 13, color: Sf.textMuted),
        const SizedBox(width: 6),
        Flexible(child: Text('Your key is stored only on this device.', style: SfText.micro)),
      ]),
    ]);
  }

  int _lastLen = 0;
}
