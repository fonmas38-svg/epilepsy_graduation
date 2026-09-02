import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/config.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/ui/common.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/app_state.dart';
import '../../services/monitoring_service.dart';

class DeviceLinkScreen extends StatelessWidget {
  const DeviceLinkScreen({super.key});

  String _sourceTitle(AppLocalizations l, SignalSource s) => switch (s) {
        SignalSource.headDevice => l.sourceDevice,
        SignalSource.dataset => l.sourceDataset,
        SignalSource.simulator => l.sourceSimulator,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = context.watch<AppState>();
    final m = state.monitoring;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.sourceSection),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Gap.md),
        children: [
          Text(l.sourceSection, style: theme.textTheme.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(
            l.deviceIntro,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Gap.md),
          Card(
            child: ListTile(
              leading: const Icon(Icons.sensors),
              title: Text('${l.currentSource}: ${_sourceTitle(l, m.source)}'),
              subtitle: Text(
                m.source == SignalSource.headDevice
                    ? (m.deviceConnected
                        ? '${l.deviceConnected} · ${m.deviceId ?? "-"} · ${m.deviceBuffered} ${l.bufferedSamples}'
                        : l.sourceDeviceDesc)
                    : m.source == SignalSource.dataset
                        ? l.sourceDatasetDesc
                        : l.sourceSimulatorDesc,
              ),
            ),
          ),
          const SizedBox(height: Gap.sm),
          FilledButton.icon(
            onPressed: state.useDataset,
            icon: const Icon(Icons.storage),
            label: Text('${l.sourceDataset} (${l.recommendedNow})'),
          ),
          const SizedBox(height: Gap.xs),
          OutlinedButton.icon(
            onPressed: state.useSimulator,
            icon: const Icon(Icons.auto_graph),
            label: Text(l.sourceSimulator),
          ),
          const SizedBox(height: Gap.xs),
          OutlinedButton.icon(
            onPressed: state.useHeadDevice,
            icon: const Icon(Icons.headset_mic),
            label: Text(l.sourceDevice),
          ),
          const SizedBox(height: Gap.lg),
          Text(l.serverSettings, style: theme.textTheme.titleMedium),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('API'),
            subtitle: Text(AppConfig.apiBaseUrl),
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: AppConfig.apiBaseUrl));
                if (context.mounted) {
                  AppSnack.success(context, l.copied);
                }
              },
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.patientLabel),
            subtitle: Text(state.auth.currentUser?.uid ?? '-'),
          ),
          const SizedBox(height: Gap.sm),
          Container(
            padding: const EdgeInsets.all(Gap.md),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.demoPathTitle,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: Gap.xs),
                Text(
                  l.demoPathSteps,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
