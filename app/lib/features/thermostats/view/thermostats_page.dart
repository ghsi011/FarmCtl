import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/thermostat.dart';
import '../providers/thermostat_providers.dart';
import '../widgets/thermostat_card.dart';
import '../widgets/thermostat_form_dialog.dart';

class ThermostatsPage extends ConsumerWidget {
  const ThermostatsPage({super.key});

  Future<void> _createThermostat(BuildContext context, WidgetRef ref) async {
    final draft = await showDialog<ThermostatDraft>(
      context: context,
      builder: (context) => const ThermostatFormDialog(),
    );

    if (draft == null) {
      return;
    }

    final repository = ref.read(thermostatRepositoryProvider);
    try {
      await repository.create(draft);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Thermostat added.')));
    } on ThermostatValidationException catch (error) {
      final first = error.result.errors.first;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(first.message)));
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save thermostat: $error')),
      );
    }
  }

  Future<void> _editThermostat(
    BuildContext context,
    WidgetRef ref,
    Thermostat thermostat,
  ) async {
    final draft = await showDialog<ThermostatDraft>(
      context: context,
      builder: (context) => ThermostatFormDialog(initial: thermostat),
    );

    if (draft == null) {
      return;
    }

    final repository = ref.read(thermostatRepositoryProvider);
    try {
      await repository.update(thermostat, draft);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Thermostat updated.')));
    } on ThermostatValidationException catch (error) {
      final first = error.result.errors.first;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(first.message)));
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update thermostat: $error')),
      );
    }
  }

  Future<void> _deleteThermostat(
    BuildContext context,
    WidgetRef ref,
    Thermostat thermostat,
  ) async {
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

    if (confirm != true) {
      return;
    }

    final repository = ref.read(thermostatRepositoryProvider);
    try {
      await repository.delete(thermostat.id);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Thermostat deleted.')));
    } catch (error) {
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
              final thermostat = thermostats[index];
              return ThermostatCard(
                thermostat: thermostat,
                onEdit: () => _editThermostat(context, ref, thermostat),
                onDelete: () => _deleteThermostat(context, ref, thermostat),
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
