import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/thermostat.dart';
import '../models/thermostat_state.dart';
import '../providers/thermostat_providers.dart';
import '../widgets/thermostat_card.dart';
import '../widgets/thermostat_form_dialog.dart';
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
      ),
    );

    if (!context.mounted || saved == null) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Thermostat added.')));
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
      ),
    );

    if (!context.mounted || updated == null) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Thermostat updated.')));
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        ),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to refresh ${summary.thermostat.name}: $error'),
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
        return AlertDialog(
          title: const Text('Delete thermostat'),
          content: Text('Delete "${thermostat.name}"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
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
    try {
      await repository.delete(thermostat.id);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Thermostat deleted.')));
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete thermostat: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncThermostats = ref.watch(thermostatsProvider);
    final offlineStatus = ref.watch(offlineStatusProvider);

    final content = asyncThermostats.when(
      data: (thermostats) {
        if (thermostats.isEmpty) {
          return const _EmptyState();
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final crossAxisCount = switch (width) {
              >= 1200 => 3,
              >= 760 => 2,
              _ => 1,
            };
            final spacing = 18.0;
            return GridView.builder(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                24 + MediaQuery.of(context).padding.bottom,
              ),
              primary: false,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: spacing,
                crossAxisSpacing: spacing,
                childAspectRatio: crossAxisCount == 1 ? 1.02 : 0.94,
              ),
              itemCount: thermostats.length,
              itemBuilder: (context, index) {
                final summary = thermostats[index];
                return ThermostatCard(
                  summary: summary,
                  onEdit: () => _editThermostat(context, ref, summary),
                  onDelete: () => _deleteThermostat(context, ref, summary),
                  onRefresh: () => _refreshThermostat(context, ref, summary),
                  onTap: () => context.pushNamed(
                    ThermostatDetailRoute.name,
                    pathParameters: {'id': summary.thermostat.id},
                  ),
                );
              },
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => _ErrorState(error: error),
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

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.status});

  final OfflineStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final (title, message, icon) = switch (status) {
      OfflineStatus.offline => (
        'Offline mode',
        'FarmCtl is showing the last known readings until the connection returns.',
        Icons.cloud_off,
      ),
      OfflineStatus.degraded => (
        'Connectivity issues',
        'Some thermostats are unreachable and recent values may be stale.',
        Icons.cloud_queue,
      ),
      _ => (
        'Connectivity notice',
        'Network status is unavailable.',
        Icons.cloud_queue,
      ),
    };

    return Semantics(
      container: true,
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
                backgroundColor: colorScheme.primaryContainer,
                foregroundColor: colorScheme.onPrimaryContainer,
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
  const _EmptyState();

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
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error});

  final Object error;

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
              'Failed to load thermostats.',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
