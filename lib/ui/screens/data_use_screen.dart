import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../links.dart';
import '../widgets/icons.dart';
import '../widgets/primitives.dart';
import '../../i18n/i18n.dart';

/// Shown once on a phone, the first time the user taps Connect, before the
/// system asks to add the VPN configuration. App Store guideline 5.4 and
/// Google Play's VpnService policy both require the app to say what it does
/// and what data it uses, link the privacy policy, and get an explicit tap
/// first. "Allow and connect" is that consent; the caller saves it and
/// connects.
class DataUseScreen extends StatelessWidget {
  const DataUseScreen({super.key, required this.onAccept, this.ios});

  final VoidCallback onAccept;

  /// iOS wording; defaults to the running platform (tests set it).
  final bool? ios;

  @override
  Widget build(BuildContext context) {
    final ios = this.ios ?? Platform.isIOS;
    final points = <(SfIcons, String, String)>[
      (
        SfIcons.lock,
        tr('Encrypted by default'),
        tr('All traffic between this device and Shifter is encrypted, on Wi-Fi and mobile data.'),
      ),
      (
        SfIcons.key,
        tr('Only your API key'),
        ios
            ? tr('Kept in the Keychain on this device and sent only to Shifter, to load your plans.')
            : tr('Kept encrypted on this device and sent only to Shifter, to load your plans.'),
      ),
      (
        SfIcons.shieldCheck,
        tr('Never sold or shared'),
        tr('Shifter does not sell or share your traffic, or use it for anything else.'),
      ),
    ];
    return Scaffold(
      backgroundColor: Sf.bgDeep,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: LayoutBuilder(
              // Button at the bottom on tall screens, everything scrolls on short ones.
              builder: (context, box) => SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight - 52),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Layout B: the content is centred in the space above
                        // the button, so tall phones have no gap in the middle.
                        const Spacer(),
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Glyph(size: 44),
                        ),
                        const SizedBox(height: 22),
                        Text(
                          tr('Before you connect'),
                          style: SfText.display.copyWith(
                            fontSize: 32,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          ios
                              ? tr('Shifter adds a VPN configuration to this device so your apps reach the internet through your Shifter plan.')
                              : tr("Shifter uses Android's VPN service so your apps reach the internet through your Shifter plan."),
                          style: SfText.bodyMuted.copyWith(
                            fontSize: 17,
                            color: Sf.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 30),
                        for (final (icon, title, body) in points)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: SfCard(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  IconTile(icon, size: 44),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          title,
                                          style: SfText.bodyStrong.copyWith(
                                            fontSize: 16,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          body,
                                          style: SfText.small.copyWith(
                                            fontSize: 14.5,
                                            height: 1.45,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        const Spacer(),
                        const SizedBox(height: 16),
                        SfButton(
                          label: Text(tr('Allow and connect')),
                          expand: true,
                          large: true,
                          onPressed: onAccept,
                        ),
                        const SizedBox(height: 16),
                        Center(
                          child: SfLinkButton(
                            text: tr('Privacy policy'),
                            fontSize: 15,
                            onTap: () =>
                                openExternal(context, ShifterUrls.privacy),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          ios
                              ? tr('Next, iOS asks to add the VPN configuration. Tap Allow.')
                              : tr('Next, Android asks to allow the connection request. Tap OK.'),
                          textAlign: TextAlign.center,
                          style: SfText.micro.copyWith(fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
