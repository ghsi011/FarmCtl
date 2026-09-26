import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/fleet_connection_store.dart';
import '../models/fleet_configuration.dart';
import '../providers/fleet_providers.dart';

/// Phone-side connection and read-only view of repository desired state.
class FleetConfigurationPage extends ConsumerStatefulWidget {
  const FleetConfigurationPage({super.key});

  @override
  ConsumerState<FleetConfigurationPage> createState() =>
      _FleetConfigurationPageState();
}

class _FleetConfigurationPageState extends ConsumerState<FleetConfigurationPage>
    with WidgetsBindingObserver {
  late final FleetConnectionStore _store;
  late final ProviderSubscription<FleetConnectionStore> _storeSubscription;
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _owner = TextEditingController();
  late final TextEditingController _repo = TextEditingController();
  late final TextEditingController _branch = TextEditingController(
    text: 'main',
  );
  late final TextEditingController _path = TextEditingController(
    text: 'fleet.json',
  );
  late final TextEditingController _token = TextEditingController();
  FleetConfiguration? _configuration;
  DateTime? _fetchedAt;
  Timer? _expiryTicker;
  bool _busy = true;
  bool _obscureToken = true;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _storeSubscription = ref.listenManual(
      fleetConnectionStoreProvider,
      (previous, next) {},
    );
    _store = ref.read(fleetConnectionStoreProvider);
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      final connection = await _store.loadConnection();
      if (!mounted) return;
      if (connection != null) {
        _owner.text = connection.owner;
        _repo.text = connection.repo;
        _branch.text = connection.branch;
        _path.text = connection.path;
      }
      setState(() {
        _busy = false;
        _notice = connection == null
            ? null
            : 'Connection saved securely on this phone.';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _notice =
              'Saved connection is unavailable. Review the details or clear it.';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _closeSession('Session closed when FarmCtl went to the background.');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiryTicker?.cancel();
    _store.closeSession();
    _storeSubscription.close();
    for (final controller in [_owner, _repo, _branch, _path, _token]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  void _closeSession([String? notice]) {
    _expiryTicker?.cancel();
    _expiryTicker = null;
    _store.closeSession();
    if (mounted) {
      setState(() {
        _configuration = null;
        _fetchedAt = null;
        if (notice != null) _notice = notice;
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await _store.saveConnection(
        _owner.text.trim(),
        _repo.text.trim(),
        _branch.text.trim(),
        _path.text.trim(),
        _token.text,
      );
      if (!mounted) return;
      _token.clear();
      setState(() {
        _busy = false;
        _notice = 'Connection saved securely on this phone.';
      });
      FocusScope.of(context).unfocus();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _notice =
              'Could not save this connection. Check the fields and try again.';
        });
      }
    }
  }

  Future<void> _openSession() async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final session = await _store.openEditSession();
      final config = session.configuration;
      if (!mounted) {
        session.close();
        return;
      }
      setState(() {
        _configuration = config;
        _fetchedAt = DateTime.now();
        _busy = false;
        _notice = null;
      });
      _expiryTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!session.isActive) {
          _closeSession(
            'This five-minute review session has expired. Open it again to fetch the latest version.',
          );
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _configuration = null;
          _notice =
              'The saved file could not be opened. Check your connection and try again.';
        });
      }
    }
  }

  Future<void> _clear() async {
    setState(() {
      _busy = true;
    });
    try {
      await _store.clearConnection();
      _owner.clear();
      _repo.clear();
      _branch.text = 'main';
      _path.text = 'fleet.json';
      _token.clear();
      if (mounted) {
        setState(() {
          _configuration = null;
          _fetchedAt = null;
          _busy = false;
          _notice = 'Saved connection cleared.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _notice = 'Could not clear the saved connection. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final config = _configuration;
    return Scaffold(
      appBar: AppBar(title: const Text('Device configuration')),
      body: SafeArea(
        child: _busy && config == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.cloud_sync_outlined,
                          color: colors.onPrimaryContainer,
                          size: 30,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Repository desired state',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'This is what the private fleet file asks devices to use. It is not a report of what any device has applied.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Card(
                    color: colors.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: colors.onErrorContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Device-applied status is not available yet. Changes cannot be submitted from FarmCtl.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onErrorContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_notice != null) ...[
                    const SizedBox(height: 12),
                    _StatusBanner(message: _notice!),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    'Private repository connection',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Credentials are stored in secure storage on this phone. The fleet file itself is never saved here.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        _field(_owner, 'Repository owner'),
                        _field(_repo, 'Repository name'),
                        _field(_branch, 'Branch'),
                        _field(_path, 'Fleet file path'),
                        TextFormField(
                          controller: _token,
                          obscureText: _obscureToken,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'Writer token',
                            helperText:
                                'Used only to access this private file.',
                            suffixIcon: IconButton(
                              tooltip: _obscureToken
                                  ? 'Show token'
                                  : 'Hide token',
                              onPressed: () => setState(
                                () => _obscureToken = !_obscureToken,
                              ),
                              icon: Icon(
                                _obscureToken
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                            ),
                          ),
                          validator: (value) => value == null || value.isEmpty
                              ? 'Enter a writer token.'
                              : null,
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              onPressed: _busy ? null : _save,
                              icon: const Icon(Icons.lock_outline),
                              label: const Text('Save connection'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _openSession,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Fetch desired state'),
                            ),
                            TextButton.icon(
                              onPressed: _busy ? null : _clear,
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Clear connection'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (config != null)
                    _ConfigurationOverview(
                      configuration: config,
                      fetchedAt: _fetchedAt!,
                    ),
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      leading: Icon(
                        Icons.lock_clock_outlined,
                        color: colors.primary,
                      ),
                      title: const Text(
                        'Editing unlocks after compatibility check',
                      ),
                      subtitle: const Text(
                        'Review only for now. FarmCtl will enable changes when device compatibility and acknowledgement are supported.',
                      ),
                      trailing: const Icon(Icons.lock_outline),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _field(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextFormField(
      controller: controller,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: label),
      validator: (value) =>
          value == null || value.trim().isEmpty ? 'Enter $label.' : null,
    ),
  );
}

class _ConfigurationOverview extends StatelessWidget {
  const _ConfigurationOverview({
    required this.configuration,
    required this.fetchedAt,
  });
  final FleetConfiguration configuration;
  final DateTime fetchedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current desired settings', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Revision ${configuration.revision}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            Text(
              'Fetched just now · ${TimeOfDay.fromDateTime(fetchedAt).format(context)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const Divider(height: 24),
            for (final entry in configuration.devices.entries.take(16))
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.key.length > 52
                          ? '${entry.key.substring(0, 52)}…'
                          : entry.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Logical ID · ${entry.value.logicalId}',
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      'Sample every ${entry.value.sampleIntervalSeconds}s · Publish every ${entry.value.publicationIntervalSeconds}s',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              'Desired configuration only — device acknowledgement is not available.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(message),
  );
}
