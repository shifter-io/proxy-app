import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../../i18n/i18n.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../update/update_models.dart';
import '../../update/update_coordinator.dart';
import '../widgets/primitives.dart';
import 'update_host.dart';

class AppUpdatesEntry extends StatelessWidget {
  const AppUpdatesEntry({super.key});
  @override
  Widget build(BuildContext context) {
    final scope = UpdateScope.of(context);
    final updates = scope?.coordinator;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr('App updates'), style: SfText.heading),
        const SizedBox(height: 8),
        if (updates != null)
          Text(
            trf('Version {version} ({build})', {'version': updates.identity.version, 'build': updates.identity.build}),
            style: SfText.small,
          ),
        if (updates?.supportsAutomaticInstall == true)
          ListenableBuilder(
            listenable: updates!,
            builder: (context, _) => SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Install eligible updates automatically')),
              subtitle: Text(tr('Applies at startup while disconnected.')),
              value: updates.automaticInstallEnabled,
              onChanged: updates.setAutomaticInstall,
            ),
          ),
        TextButton(
          onPressed: scope?.open,
          child: Text(tr('Check for updates')),
        ),
      ],
    );
  }
}

class UpdatePanel extends StatelessWidget {
  const UpdatePanel({super.key, required this.onClose});
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final scope = UpdateScope.of(context)!;
    final u = scope.coordinator;
    final connected =
        AppScope.of(context).isConnected || AppScope.of(context).isConnecting;
    final r = u?.release;
    final installing = u?.phase == UpdatePhase.preparingInstall;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(tr('App updates'), style: SfText.heading)),
            Semantics(
              label: tr('Close app updates'),
              button: true,
              child: IconButton(
                onPressed: installing ? null : onClose,
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
        if (u != null)
          Text(
            trf('Installed: {version} ({build})', {'version': u.identity.version, 'build': u.identity.build}),
            style: SfText.small,
          ),
        const SizedBox(height: 14),
        Semantics(
          liveRegion: true,
          child: Text(
            u?.status ?? tr(scope.problem ?? 'Update information is loading…'),
            style: SfText.body,
          ),
        ),
        if (u?.lastCheck != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              trf('Last checked: {time}', {'time': u!.lastCheck!.toLocal().toString().split('.').first}),
              style: SfText.micro,
            ),
          ),
        if (r != null) ...[
          const SizedBox(height: 16),
          Text(trf('Version {version}', {'version': r.version}), style: SfText.body),
          if (r.artifact != null)
            Text(
              '${(r.byteLength / 1048576).toStringAsFixed(1)} MB',
              style: SfText.small,
            ),
          if (r.notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(r.notes, style: SfText.bodyMuted),
            ),
        ],
        if (u?.phase == UpdatePhase.downloading ||
            u?.phase == UpdatePhase.verifying ||
            installing) ...[
          const SizedBox(height: 18),
          LinearProgressIndicator(
            value: u?.phase == UpdatePhase.downloading ? u?.progress : null,
            semanticsLabel: tr('Update progress'),
          ),
        ],
        const SizedBox(height: 18),
        if (u != null) ...[
          if (connected && u.canInstall)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                tr('Shifter will disconnect before opening the installer. It will stay disconnected afterward.'),
                style: SfText.small,
              ),
            ),
          if (u.manualDownload != null)
            OutlinedButton(
              onPressed: u.busy ? null : u.openManualDownload,
              child: Text(tr('Download AppImage')),
            ),
          if (u.canDownload)
            FilledButton(
              onPressed: u.download,
              child: Text(tr('Download update')),
            ),
          if (u.canInstall)
            FilledButton(
              onPressed: u.install,
              child: Text(
                connected ? tr('Disconnect and restart') : tr('Restart and install'),
              ),
            ),
          if (u.phase == UpdatePhase.downloading && u.capabilities.cancel)
            TextButton(
              onPressed: u.cancelDownload,
              child: Text(tr('Cancel download')),
            ),
          if (!u.ready && u.phase != UpdatePhase.handingOff)
            OutlinedButton(
              onPressed: u.busy ? null : () => u.check(),
              child: Text(tr('Check for updates')),
            ),
        ],
        TextButton(
          onPressed: installing ? null : onClose,
          child: Text(r == null ? tr('Close') : tr('Later')),
        ),
      ],
    );
  }
}

class RequiredUpdatePanel extends StatelessWidget {
  const RequiredUpdatePanel({super.key, required this.updates});

  final UpdateCoordinator updates;

  @override
  Widget build(BuildContext context) {
    final working =
        updates.phase == UpdatePhase.downloading ||
        updates.phase == UpdatePhase.verifying ||
        updates.phase == UpdatePhase.preparingInstall;
    final manual =
        !updates.capabilities.install && updates.manualDownload != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(label: 'Shifter', child: const Wordmark(height: 24)),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Sf.accentSoft,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Sf.accent.withValues(alpha: .25)),
            ),
            child: const Icon(
              Icons.system_update_alt,
              color: Sf.accentLight,
              size: 32,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            tr('Update required'),
            textAlign: TextAlign.center,
            style: SfText.display,
          ),
          const SizedBox(height: 10),
          Text(
            tr('A new version of Shifter is required. Update to keep using the app.'),
            textAlign: TextAlign.center,
            style: SfText.bodyMuted,
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [
              _VersionBadge(updates.identity.version, SfTone.neutral),
              const Icon(Icons.arrow_forward, size: 16, color: Sf.textTertiary),
              _VersionBadge(updates.requiredVersion!, SfTone.info),
            ],
          ),
          if (updates.busy ||
              updates.phase == UpdatePhase.error ||
              updates.phase == UpdatePhase.unavailable) ...[
            const SizedBox(height: 16),
            if (working)
              LinearProgressIndicator(
                value: updates.phase == UpdatePhase.downloading
                    ? updates.progress
                    : null,
                semanticsLabel: tr('Update progress'),
              ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                updates.status,
                textAlign: TextAlign.center,
                style: SfText.small,
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: updates.busy || updates.phase == UpdatePhase.handingOff
                ? null
                : updates.updateNow,
            icon: const Icon(Icons.download, size: 18),
            label: Text(manual ? tr('Download AppImage') : tr('Update now')),
          ),
          if (!manual &&
              updates.phase == UpdatePhase.error &&
              updates.manualDownload != null)
            TextButton(
              onPressed: updates.busy ? null : updates.openManualDownload,
              child: Text(tr('Download AppImage')),
            ),
        ],
      ),
    );
  }
}

class _VersionBadge extends StatelessWidget {
  const _VersionBadge(this.version, this.tone);

  final String version;
  final SfTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = SfToneColors.of(tone);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.bg,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(version, style: SfText.mono.copyWith(color: colors.fg)),
      ),
    );
  }
}
