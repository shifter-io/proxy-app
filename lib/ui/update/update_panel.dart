import 'package:flutter/material.dart';

import '../../state/app_controller.dart';
import '../../theme/theme.dart';
import '../../update/update_models.dart';
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
        Text('App updates', style: SfText.heading),
        const SizedBox(height: 8),
        if (updates != null)
          Text(
            'Version ${updates.identity.version} (${updates.identity.build})',
            style: SfText.small,
          ),
        TextButton(
          onPressed: scope?.open,
          child: const Text('Check for updates'),
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
            Expanded(child: Text('App updates', style: SfText.heading)),
            Semantics(
              label: 'Close app updates',
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
            'Installed: ${u.identity.version} (${u.identity.build})',
            style: SfText.small,
          ),
        const SizedBox(height: 14),
        Semantics(
          liveRegion: true,
          child: Text(
            u?.status ?? scope.problem ?? 'Update information is loading…',
            style: SfText.body,
          ),
        ),
        if (u?.lastCheck != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Last checked: ${u!.lastCheck!.toLocal().toString().split('.').first}',
              style: SfText.micro,
            ),
          ),
        if (r != null) ...[
          const SizedBox(height: 16),
          Text('Version ${r.version}', style: SfText.body),
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
            semanticsLabel: 'Update progress',
          ),
        ],
        const SizedBox(height: 18),
        if (u != null) ...[
          if (connected && (u.canInstall || u.capabilities.store))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Shifter will disconnect before opening the installer. It will stay disconnected afterward.',
                style: SfText.small,
              ),
            ),
          if (u.canDownload)
            FilledButton(
              onPressed: u.download,
              child: const Text('Download update'),
            ),
          if (u.canInstall)
            FilledButton(
              onPressed: u.install,
              child: Text(
                u.identity.distribution == Distribution.direct
                    ? (connected ? 'Disconnect and install' : 'Install update')
                    : (connected
                          ? 'Disconnect and restart'
                          : 'Restart and install'),
              ),
            ),
          if (u.identity.distribution == Distribution.play &&
              r != null &&
              u.phase == UpdatePhase.available &&
              !u.busy)
            FilledButton(
              onPressed: u.startPlayDownload,
              child: const Text('Update with Google Play'),
            ),
          if (u.phase == UpdatePhase.downloading && u.capabilities.cancel)
            TextButton(
              onPressed: u.cancelDownload,
              child: const Text('Cancel download'),
            ),
          if (u.capabilities.store)
            OutlinedButton(
              onPressed: u.busy ? null : u.openStore,
              child: Text(
                u.identity.distribution == Distribution.appStore
                    ? 'Open App Store'
                    : 'Open Google Play',
              ),
            ),
          if (!u.ready &&
              u.phase != UpdatePhase.awaitingSystemConsent &&
              u.phase != UpdatePhase.handingOff)
            OutlinedButton(
              onPressed: u.busy ? null : () => u.check(),
              child: const Text('Check for updates'),
            ),
        ],
        TextButton(
          onPressed: installing ? null : onClose,
          child: Text(r == null ? 'Close' : 'Later'),
        ),
      ],
    );
  }
}
