import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/thermostat.dart';
import '../models/thermostat_state.dart';
import '../providers/thermostat_providers.dart';
import '../widgets/thermostat_card.dart';
import '../widgets/thermostat_form_dialog.dart';
import '../../../core/background/thermostat_monitor.dart';
import '../../../core/format/error_messages.dart';
import '../../../core/router/app_router.dart';
import '../../settings/providers/settings_providers.dart';

class ThermostatsPage extends ConsumerWidget {
  const ThermostatsPage({super.key});

  Future<void> _createThermostat(BuildContext context, WidgetRef ref) async {
    final saved = await showDialog<Thermostat>(
      context: context,
      builder: (context) => ThermostatFormDialog(
        onSubmit: (draft) async {
          final service = ref.read(thermostatServiceProvider);
          final alertRepo = ref.read(alertConfigRepositoryProvider);
          final config = await alertRepo.loadConfig();
          return service.createAndTest(
            draft,
            tokenOverride: config.githubToken,
          );
        },
        onSaveWithoutTest: (draft) =>
            ref.read(thermostatRepositoryProvider).create(draft),
      ),
    );

    if (!context.mounted || saved == null) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Thermostat added')));
  }

  Future<void> _editThermostat(
    BuildContext context,
    WidgetRef ref,
    ThermostatSummary summary,
  ) async {
    final thermostat = summary.thermostat;
    final updated = await showDialog<Thermostat>(
      context: context,
      builder: (context) => ThermostatFormDialog(
        initial: thermostat,
        onSubmit: (draft) async {
          final service = ref.read(thermostatServiceProvider);
          final alertRepo = ref.read(alertConfigRepositoryProvider);
          final config = await alertRepo.loadConfig();
          return service.updateAndTest(
            thermostat,
            draft,
            tokenOverride: config.githubToken,
          );
        },
        onSaveWithoutTest: (draft) =>
            ref.read(thermostatRepositoryProvider).update(thermostat, draft),
      ),
    );

    if (!context.mounted || updated == null) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Thermostat updated')));
  }

  Future<void> _refreshThermostat(
    BuildContext context,
    WidgetRef ref,
    ThermostatSummary summary,
  ) async {
    final service = ref.read(thermostatServiceProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await service.refresh(summary.thermostat);
      if (!context.mounted) {
        return;
      }
      final thermostatName = summary.thermostat.name;
      final message = '$thermostatName: ${result.message}';
      final isError = switch (result.status) {
        ThermostatReadingStatus.ok => false,
        _ => true,
      };
      final scheme = Theme.of(context).colorScheme;
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? scheme.error : null,
        ),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      final scheme = Theme.of(context).colorScheme;
      messenger.showSnackBar(
        SnackBar(
          content: Text('${summary.thermostat.name}: ${humanizeError(error)}'),
          backgroundColor: scheme.error,
        ),
      );
    }
  }

  Future<void> _deleteThermostat(
    BuildContext context,
    WidgetRef ref,
    ThermostatSummary summary,
  ) async {
    final thermostat = summary.thermostat;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return AlertDialog(
          title: const Text('Delete thermostat'),
          content: Text('Delete "${thermostat.name}"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (!context.mounted) {
      return;
    }

    if (confirm != true) {
      return;
    }

    final repository = ref.read(thermostatRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repository.delete(thermostat.id);
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Thermostat deleted'),
          // Longer window than the 4s default: deletion drops reading history,
          // so give the user time to notice and undo.
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              // Restores the configuration (reading history is not recovered).
              try {
                await repository.restore(thermostat);
              } catch (_) {
                // If the restore fails the row simply stays deleted.
              }
            },
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text(humanizeError(error))));
    }
  }

  Future<void> _resumeMonitoring(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(alertConfigRepositoryProvider).clearPause();
      await initializeBackgroundMonitoring();
      messenger.showSnackBar(
        const SnackBar(content: Text('Monitoring resumed')),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(humanizeError(error))));
    }
  }

  Future<void> _refreshAll(WidgetRef ref, List<ThermostatSummary> items) async {
    final service = ref.read(thermostatServiceProvider);
    await refreshAllThermostats(
      items,
      (thermostat) => service.refresh(thermostat),
    );
  }

  Widget _buildGrid(
    BuildContext context,
    WidgetRef ref,
    List<ThermostatSummary> thermostats,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = switch (width) {
          >= 1200 => 3,
          >= 760 => 2,
          _ => 1,
        };
        final bottomPadding = MediaQuery.of(context).padding.bottom;
        final padding = EdgeInsets.fromLTRB(16, 16, 16, 24 + bottomPadding);

        ThermostatCard buildCard(ThermostatSummary summary) => ThermostatCard(
          summary: summary,
          onEdit: () => _editThermostat(context, ref, summary),
          onDelete: () => _deleteThermostat(context, ref, summary),
          onRefresh: () => _refreshThermostat(context, ref, summary),
          onTap: () => context.pushNamed(
            ThermostatDetailRoute.name,
            pathParameters: {'id': summary.thermostat.id},
          ),
        );

        if (crossAxisCount == 1) {
          return ListView.separated(
            padding: padding,
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: thermostats.length,
            separatorBuilder: (context, _) => const SizedBox(height: 18),
            itemBuilder: (context, index) => buildCard(thermostats[index]),
          );
        }

        const spacing = 18.0;
        // Height is driven by content (not a fixed aspect ratio) so cards don't
        // overflow at large text scales.
        return GridView.builder(
          padding: padding,
          primary: false,
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: width / crossAxisCount,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            mainAxisExtent: 280,
          ),
          itemCount: thermostats.length,
          itemBuilder: (context, index) => buildCard(thermostats[index]),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncThermostats = ref.watch(thermostatsProvider);
    final offlineStatus = ref.watch(offlineStatusProvider);
    final config = ref.watch(alertConfigProvider).asData?.value;
    final now = DateTime.now().toUtc();
    final pausedUntil = (config != null && config.isPaused(now))
        ? config.pauseAllUntil
        : null;

    final content = asyncThermostats.when(
      data: (thermostats) {
        if (thermostats.isEmpty) {
          return _EmptyState(onAdd: () => _createThermostat(context, ref));
        }
        return RefreshIndicator(
          onRefresh: () => _refreshAll(ref, thermostats),
          child: _buildGrid(context, ref, thermostats),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => _ErrorState(
        error: error,
        onRetry: () => ref.invalidate(thermostatsProvider),
      ),
    );

    final showOfflineBanner =
        offlineStatus == OfflineStatus.offline ||
        offlineStatus == OfflineStatus.degraded;

    return Scaffold(
      appBar: AppBar(title: const Text('Thermostats')),
      body: SafeArea(
        child: Column(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: pausedUntil != null
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: _PauseBanner(
                        resumesAt: pausedUntil,
                        onResume: () => _resumeMonitoring(context, ref),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: showOfflineBanner
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: _OfflineBanner(status: offlineStatus),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(child: content),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createThermostat(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add thermostat'),
      ),
    );
  }
}

class _PauseBanner extends StatelessWidget {
  const _PauseBanner({required this.resumesAt, required this.onResume});

  final DateTime resumesAt;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final resumeTime = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(resumesAt.toLocal()));
    final message = 'Alarms are paused until $resumeTime.';

    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Monitoring paused',
      value: message,
      child: Card(
        margin: EdgeInsets.zero,
        color: colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
          child: Row(
            children: [
              Icon(
                Icons.pause_circle_outline,
                color: colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Monitoring paused',
                      style: textTheme.titleSmall?.copyWith(
                        color: colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      message,
                      style: textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onResume,
                style: TextButton.styleFrom(
                  foregroundColor: colorScheme.onErrorContainer,
                ),
                child: const Text('Resume'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.status});

  final OfflineStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final (title, message, icon, avatarColor, onAvatarColor) = switch (status) {
      OfflineStatus.offline => (
        'Offline mode',
        'FarmCtl is showing the last known readings until the connection returns.',
        Icons.cloud_off,
        colorScheme.errorContainer,
        colorScheme.onErrorContainer,
      ),
      OfflineStatus.degraded => (
        'Connectivity issues',
        'Some thermostats are unreachable and recent values may be stale.',
        Icons.cloud_queue,
        colorScheme.tertiaryContainer,
        colorScheme.onTertiaryContainer,
      ),
      _ => (
        'Connectivity notice',
        'Network status is unavailable.',
        Icons.cloud_queue,
        colorScheme.tertiaryContainer,
        colorScheme.onTertiaryContainer,
      ),
    };

    return Semantics(
      container: true,
      liveRegion: true,
      label: title,
      value: message,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: avatarColor,
                foregroundColor: onAvatarColor,
                child: Icon(icon),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      message,
                      style: textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.device_thermostat,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('No thermostats yet', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add your first thermostat to start monitoring temperatures.',
              textAlign: TextAlign.center,
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add thermostat'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              'Failed to load thermostats',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              humanizeError(error),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
