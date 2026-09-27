import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format/relative_time.dart';
import '../../settings/providers/settings_providers.dart';
import '../data/device_diagnostics_client.dart';
import '../data/thermostat_reading_utils.dart';
import '../models/device_diagnostics.dart';
import '../models/thermostat_state.dart';
import '../providers/thermostat_providers.dart';

const Duration _defaultDiagnosticsPollInterval = Duration(minutes: 5);

/// The device's own report is deliberately kept separate from the last valid
/// temperature: a failing sensor must not make a previously valid value vanish.
class DeviceDiagnosticsPanel extends ConsumerStatefulWidget {
  const DeviceDiagnosticsPanel({required this.summary, super.key});

  final ThermostatSummary summary;

  @override
  ConsumerState<DeviceDiagnosticsPanel> createState() =>
      _DeviceDiagnosticsPanelState();
}

class _DeviceDiagnosticsPanelState
    extends ConsumerState<DeviceDiagnosticsPanel> {
  Timer? _ageTicker;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = ref.read(nowProvider)();
    _ageTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = ref.read(nowProvider)());
    });
  }

  @override
  void dispose() {
    _ageTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final thermostat = widget.summary.thermostat;
    final gistId = thermostat.diagnosticsGistId;
    final deviceRef = thermostat.deviceRef;
    final configured =
        gistId != null &&
        gistId.isNotEmpty &&
        deviceRef != null &&
        deviceRef.isNotEmpty;
    final diagnostics = configured
        ? ref.watch(deviceDiagnosticsProvider(thermostat.id))
        : const AsyncValue<DeviceDiagnosticsSnapshot?>.data(null);
    final pollInterval =
        ref.watch(alertConfigProvider).asData?.value.pollInterval ??
        _defaultDiagnosticsPollInterval;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.secondaryContainer.withValues(alpha: .72),
            colors.surfaceContainerLow,
          ],
        ),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colors.secondary,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.memory, color: colors.onSecondary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Device diagnostics',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        configured
                            ? 'A separate report from the connected device'
                            : 'An optional device-side health report',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (configured)
                  IconButton(
                    onPressed: diagnostics.isLoading
                        ? null
                        : () => ref.invalidate(
                            deviceDiagnosticsProvider(thermostat.id),
                          ),
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh device diagnostics',
                  ),
              ],
            ),
            const SizedBox(height: 18),
            if (!configured)
              _LegacyState(
                onConfigure: () => _editAssociation(
                  context,
                  ref,
                  thermostat.id,
                  gistId: gistId,
                  deviceRef: deviceRef,
                ),
              )
            else
              diagnostics.when(
                loading: () => const _StatusLine(
                  icon: Icons.sync,
                  title: 'Checking device report',
                  detail: 'Fetching the latest published diagnostics…',
                ),
                error: (error, stack) => _DiagnosticsError(error: error),
                data: (snapshot) => snapshot == null
                    ? const _StatusLine(
                        icon: Icons.cloud_off,
                        title: 'Report unavailable',
                        detail:
                            'No diagnostics report is available for this device.',
                        warning: true,
                      )
                    : _SnapshotView(
                        snapshot: snapshot,
                        expectedRef: deviceRef,
                        now: _now,
                        pollInterval: pollInterval,
                      ),
              ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => _editAssociation(
                  context,
                  ref,
                  thermostat.id,
                  gistId: gistId,
                  deviceRef: deviceRef,
                ),
                icon: Icon(configured ? Icons.tune : Icons.link),
                label: Text(
                  configured ? 'Edit device link' : 'Link device report',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosticsError extends StatelessWidget {
  const _DiagnosticsError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final diagnosticError = error;
    final kind = diagnosticError is DeviceDiagnosticsException
        ? diagnosticError.kind
        : DeviceDiagnosticsErrorKind.unavailable;
    if (kind == DeviceDiagnosticsErrorKind.deviceReferenceMismatch) {
      return const _StatusLine(
        icon: Icons.link_off,
        title: 'Device reference mismatch',
        detail:
            'The report belongs to a different device. Edit the link to match before relying on these details.',
        warning: true,
      );
    }
    if (kind == DeviceDiagnosticsErrorKind.unsupportedSchema ||
        kind == DeviceDiagnosticsErrorKind.invalidFields) {
      return const _StatusLine(
        icon: Icons.warning_amber,
        title: 'Report format not supported',
        detail:
            'The report was published, but its contents could not be read. Check that the device is using a supported report format.',
        warning: true,
      );
    }
    return const _StatusLine(
      icon: Icons.cloud_off,
      title: 'Report unavailable',
      detail:
          'The device report could not be read. Check the link and try again.',
      warning: true,
    );
  }
}

class _LegacyState extends StatelessWidget {
  const _LegacyState({required this.onConfigure});
  final VoidCallback onConfigure;
  @override
  Widget build(BuildContext context) => _StatusLine(
    icon: Icons.info_outline,
    title: 'Diagnostics not configured',
    detail:
        'This thermostat uses the legacy setup. Add a diagnostics Gist ID and device reference to see device-reported health.',
    trailing: TextButton(onPressed: onConfigure, child: const Text('Set up')),
  );
}

class _SnapshotView extends StatelessWidget {
  const _SnapshotView({
    required this.snapshot,
    required this.expectedRef,
    required this.now,
    required this.pollInterval,
  });
  final DeviceDiagnosticsSnapshot snapshot;
  final String expectedRef;
  final DateTime now;
  final Duration pollInterval;
  @override
  Widget build(BuildContext context) {
    final publishedAt = snapshot.gistUpdatedAt;
    final stale =
        publishedAt != null &&
        now.difference(publishedAt) > staleDataThreshold(pollInterval);
    final mismatch = snapshot.deviceRef != expectedRef;
    final status = snapshot.sensorState.toString().split('.').last;
    final ok =
        status.toLowerCase() == 'ok' || status.toLowerCase() == 'healthy';
    if (mismatch) {
      return const _StatusLine(
        icon: Icons.link_off,
        title: 'Device reference mismatch',
        detail:
            'The report belongs to a different device. Edit the link to match before relying on these details.',
        warning: true,
      );
    }
    final age = now.difference(publishedAt ?? now);
    final publishStatus = publishedAt == null
        ? 'Publish freshness is unknown.'
        : stale
        ? 'Last published ${formatRelativeDuration(age)}. No recent device report has arrived.'
        : 'Last published ${formatRelativeDuration(age)}.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusLine(
          icon: publishedAt == null
              ? Icons.help_outline
              : stale
              ? Icons.schedule
              : ok
              ? Icons.check_circle_outline
              : Icons.warning_amber,
          title: publishedAt == null
              ? 'Publish freshness unknown'
              : stale
              ? 'Report is out of date'
              : ok
              ? 'Sensor reports healthy'
              : 'Sensor reports $status',
          detail:
              'Sensor report: $status. $publishStatus This is separate from the last valid temperature above.',
          warning: stale || publishedAt == null || !ok,
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _Metric(
              label: 'Firmware',
              value: _safeFirmwareVersion(snapshot.firmwareRunning),
            ),
            _Metric(
              label: 'Consecutive failures',
              value: '${snapshot.consecutiveFailures}',
            ),
            _Metric(label: 'Heartbeat', value: '${snapshot.heartbeatSeq}'),
          ],
        ),
      ],
    );
  }
}

String _safeFirmwareVersion(String version) {
  final trimmed = version.trim();
  return RegExp(r'^v?\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$').hasMatch(trimmed)
      ? trimmed
      : 'Unrecognized';
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 132),
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: .76),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.title,
    required this.detail,
    this.warning = false,
    this.trailing,
  });
  final IconData icon;
  final String title;
  final String detail;
  final bool warning;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = warning ? colors.error : colors.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: warning ? colors.error : null,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                detail,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              if (trailing != null)
                Align(alignment: Alignment.centerLeft, child: trailing!),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _editAssociation(
  BuildContext context,
  WidgetRef ref,
  String thermostatId, {
  required String? gistId,
  required String? deviceRef,
}) async {
  final result = await showDialog<({String? gistId, String? deviceRef})>(
    context: context,
    builder: (_) => _AssociationDialog(gistId: gistId, deviceRef: deviceRef),
  );
  if (result == null || !context.mounted) return;
  await ref
      .read(thermostatRepositoryProvider)
      .saveDiagnosticsAssociation(
        thermostatId,
        gistId: result.gistId,
        deviceRef: result.deviceRef,
      );
  ref.invalidate(deviceDiagnosticsProvider(thermostatId));
}

class _AssociationDialog extends StatefulWidget {
  const _AssociationDialog({required this.gistId, required this.deviceRef});

  final String? gistId;
  final String? deviceRef;

  @override
  State<_AssociationDialog> createState() => _AssociationDialogState();
}

class _AssociationDialogState extends State<_AssociationDialog> {
  late final TextEditingController _gistController;
  late final TextEditingController _refController;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _gistController = TextEditingController(text: widget.gistId ?? '');
    _refController = TextEditingController(text: widget.deviceRef ?? '');
  }

  @override
  void dispose() {
    _gistController.dispose();
    _refController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Device diagnostics link'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Link a diagnostics Gist and device reference. Never enter a password or access token.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _gistController,
                maxLength: 40,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Diagnostics Gist ID',
                  hintText: 'GitHub Gist ID',
                ),
                validator: (value) =>
                    RegExp(
                      r'^[0-9a-fA-F]{32,40}$',
                    ).hasMatch((value ?? '').trim())
                    ? null
                    : 'Enter a valid GitHub Gist ID.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _refController,
                maxLength: 256,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Device reference',
                  hintText: 'Device reference',
                ),
                validator: (value) {
                  final input = (value ?? '').trim();
                  return input.isNotEmpty && input.length <= 256
                      ? null
                      : 'Enter a device reference (up to 256 characters).';
                },
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      if (widget.gistId != null || widget.deviceRef != null)
        TextButton(
          onPressed: () =>
              Navigator.pop(context, (gistId: null, deviceRef: null)),
          child: const Text('Remove link'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_formKey.currentState!.validate()) {
            Navigator.pop(context, (
              gistId: _gistController.text.trim(),
              deviceRef: _refController.text.trim(),
            ));
          }
        },
        child: const Text('Save'),
      ),
    ],
  );
}
