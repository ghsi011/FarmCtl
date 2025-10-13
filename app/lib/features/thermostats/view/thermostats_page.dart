import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/thermostat.dart';
import '../models/thermostat_state.dart';
import '../providers/thermostat_providers.dart';
import '../widgets/thermostat_card.dart';
import '../widgets/thermostat_form_dialog.dart';

class ThermostatsPage extends ConsumerWidget {
  const ThermostatsPage({super.key});

  Future<void> _createThermostat(BuildContext context, WidgetRef ref) async {
    final saved = await showDialog<Thermostat>(
      context: context,
      builder: (context) => ThermostatFormDialog(
        onSubmit: (draft) {
          final service = ref.read(thermostatServiceProvider);
          return service.createAndTest(draft);
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
        onSubmit: (draft) {
          final service = ref.read(thermostatServiceProvider);
          return service.updateAndTest(thermostat, draft);
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

    return Scaffold(
      appBar: AppBar(title: const Text('Thermostats')),
      body: asyncThermostats.when(
        data: (thermostats) {
          if (thermostats.isEmpty) {
            return const _EmptyState();
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemBuilder: (context, index) {
              final summary = thermostats[index];
              return ThermostatCard(
                summary: summary,
                onEdit: () => _editThermostat(context, ref, summary),
                onDelete: () => _deleteThermostat(context, ref, summary),
                onRefresh: () => _refreshThermostat(context, ref, summary),
              );
            },
            separatorBuilder: (context, index) => const SizedBox(height: 12),
            itemCount: thermostats.length,
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => _ErrorState(error: error),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createThermostat(context, ref),
        child: const Icon(Icons.add),
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
