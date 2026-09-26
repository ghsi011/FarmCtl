import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/settings/providers/settings_providers.dart';
import '../../thermostats/data/thermostat_reading_utils.dart';
import '../../thermostats/models/device_diagnostics.dart';
import '../../thermostats/models/thermostat_state.dart';
import '../../thermostats/providers/thermostat_providers.dart';
import '../data/fleet_connection_store.dart';
import '../data/fleet_configuration_service.dart';
import '../models/fleet_configuration.dart';
import '../providers/fleet_providers.dart';

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
  final _connectionForm = GlobalKey<FormState>();
  final _owner = TextEditingController();
  final _repo = TextEditingController();
  final _branch = TextEditingController(text: 'main');
  final _path = TextEditingController(text: 'fleet.json');
  final _writerToken = TextEditingController();
  FleetEditSession? _session;
  FleetConfiguration? _configuration;
  DateTime? _sessionOpenedAt;
  DateTime? _sessionExpiresAt;
  DateTime? _diagnosticsRequestedAt;
  DeviceDiagnosticsSnapshot? _diagnostics;
  ThermostatSummary? _thermostat;
  String? _selectedDeviceRef;
  bool _busy = true;
  bool _writerTokenRevealed = false;
  Timer? _writerTokenMaskTimer;
  bool _checkingCompatibility = false;
  bool _editing = false;
  bool _revealed = false;
  bool _submitting = false;
  bool _submissionInFlight = false;
  bool _submissionOutcomeUnresolved = false;
  String? _notice;
  String? _gateOverride;
  Timer? _sessionTicker;
  Timer? _maskTimer;
  Timer? _retainedDraftTimer;
  DateTime? _revealUntil;
  DateTime? _retainedDraftExpiresAt;
  bool _retainedDraftAvailable = false;
  bool _latestFetchedForReapply = false;
  bool _reapplyDraftReviewing = false;
  FleetDeviceConfiguration? _draftBaseDevice;
  String? _unknownOutcomeChangeId;
  String? _pendingChangeId;
  String? _pendingThermostatId;
  String? _pendingDeviceRef;
  String? _pendingDiagnosticsGistId;
  DateTime? _pendingSince;
  bool _pendingApplied = false;
  bool _checkingPending = false;
  int _pendingGeneration = 0;
  int _editorGeneration = 0;
  int _draftGeneration = 0;
  int _submissionAttemptGeneration = 0;
  int _fetchGeneration = 0;
  int _writerTokenConsentGeneration = 0;

  @override
  void initState() {
    super.initState();
    _storeSubscription = ref.listenManual(
      fleetConnectionStoreProvider,
      (previous, next) {},
    );
    _store = ref.read(fleetConnectionStoreProvider);
    _writerToken.addListener(() => _writerTokenConsentGeneration++);
    WidgetsBinding.instance.addObserver(this);
    _loadConnection();
  }

  Future<void> _loadConnection() async {
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
            : 'Connection is saved securely on this phone.';
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
      _endSession('Session closed when FarmCtl went to the background.');
      _maskSecrets(clear: true);
      _maskWriterToken(clear: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sessionTicker?.cancel();
    _maskTimer?.cancel();
    _discardDraft();
    _writerTokenConsentGeneration++;
    _writerTokenMaskTimer?.cancel();
    _store.closeSession();
    _storeSubscription.close();
    for (final controller in [_owner, _repo, _branch, _path, _writerToken]) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  void _endSession(
    String message, {
    bool preserveDraft = false,
    FleetConfiguration? keepConfiguration,
  }) {
    _editorGeneration++;
    if (!_submissionInFlight) {
      _submissionAttemptGeneration++;
      _submitting = false;
    }
    _sessionTicker?.cancel();
    _sessionTicker = null;
    _session?.close();
    _session = null;
    _store.closeSession();
    if (preserveDraft) {
      _maskSecrets();
      _reapplyDraftReviewing = false;
    } else {
      _discardDraft();
    }
    _maskWriterToken(clear: true);
    if (mounted) {
      setState(() {
        _configuration = keepConfiguration;
        _sessionOpenedAt = null;
        _sessionExpiresAt = null;
        _diagnostics = null;
        _diagnosticsRequestedAt = null;
        _thermostat = null;
        _editing = false;
        _gateOverride = null;
        _notice = message;
      });
    }
  }

  void _discardDraft() {
    _draftGeneration++;
    _retainedDraftTimer?.cancel();
    _retainedDraftTimer = null;
    _retainedDraftExpiresAt = null;
    _retainedDraftAvailable = false;
    _latestFetchedForReapply = false;
    _reapplyDraftReviewing = false;
    _draftBaseDevice = null;
    _clearDraft();
  }

  void _expireRetainedDraft() {
    if (!_retainedDraftAvailable) return;
    _discardDraft();
    if (mounted) {
      setState(() {
        _editing = false;
        _notice =
            'The saved draft expired with its original edit session and was cleared.';
      });
    }
  }

  Future<void> _saveConnection() async {
    if (_busy || _submitting || _submissionInFlight) return;
    if (!_connectionForm.currentState!.validate()) return;
    final writerToken = _writerToken.text;
    _endSession('Saving connection. Previous edit state cleared.');
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
        writerToken,
      );
      if (!mounted) return;
      _writerToken.clear();
      final discardedConflictDraft = _retainedDraftAvailable;
      if (discardedConflictDraft) _discardDraft();
      setState(() {
        _busy = false;
        _notice = discardedConflictDraft
            ? 'Connection saved securely. The prior conflict draft was discarded.'
            : 'Connection is saved securely on this phone.';
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
    if (_busy || _submitting || _submissionInFlight) return;
    final fetchGeneration = ++_fetchGeneration;
    final keepDraft =
        _retainedDraftAvailable &&
        _retainedDraftExpiresAt != null &&
        _now().isBefore(_retainedDraftExpiresAt!);
    _endSession(
      'Fetching desired state. Previous compatibility evidence was cleared.',
      preserveDraft: keepDraft,
    );
    if (keepDraft) {
      _latestFetchedForReapply = false;
      _reapplyDraftReviewing = false;
    }
    final sessionDeadline = _now().add(_store.sessionLifetime);
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final session = await _store.openEditSession();
      final configuration = session.configuration;
      if (!mounted || fetchGeneration != _fetchGeneration) {
        session.close();
        return;
      }
      var notice = 'Latest desired state fetched in a new edit session.';
      if (_retainedDraftAvailable &&
          _retainedDraftExpiresAt != null &&
          !_now().isBefore(_retainedDraftExpiresAt!)) {
        _discardDraft();
        notice =
            'The saved draft expired with its original edit session and was cleared.';
      } else if (_retainedDraftAvailable &&
          _selectedDeviceRef != null &&
          !configuration.devices.containsKey(_selectedDeviceRef)) {
        _discardDraft();
        _selectedDeviceRef = configuration.devices.keys.first;
        notice =
            'The selected device was removed from the latest file. The saved draft was discarded and cannot be reapplied.';
      } else if (_unknownOutcomeChangeId != null) {
        notice =
            'The previous submission outcome is still unknown. Do not submit a replacement; review the repository and device status outside this editor.';
      } else if (_retainedDraftAvailable) {
        _latestFetchedForReapply = true;
        notice =
            'Latest file fetched in a new five-minute session. Review its current values above before loading the saved draft.';
      }
      if (_selectedDeviceRef == null ||
          !configuration.devices.containsKey(_selectedDeviceRef)) {
        _selectedDeviceRef = configuration.devices.keys.first;
      }
      setState(() {
        _session = session;
        _configuration = configuration;
        _sessionOpenedAt = _now();
        _sessionExpiresAt = sessionDeadline;
        _diagnostics = null;
        _diagnosticsRequestedAt = null;
        _thermostat = null;
        _gateOverride = null;
        _busy = false;
        _notice = notice;
      });
      _sessionTicker?.cancel();
      _sessionTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        if (!session.isActive) {
          _endSession(
            'This five-minute session expired. Fetch the latest configuration to continue.',
          );
        } else if (_revealed &&
            _revealUntil != null &&
            !_now().isBefore(_revealUntil!)) {
          _maskSecrets();
        }
      });
    } catch (_) {
      if (mounted && fetchGeneration == _fetchGeneration) {
        setState(() {
          _busy = false;
          _configuration = null;
          _notice =
              'The saved fleet file could not be opened. Check the connection and try again.';
        });
      }
    }
  }

  DateTime _now() => ref.read(nowProvider)().toUtc();

  void _clearDraft() {
    _draft?.dispose();
    _draft = null;
  }

  _FleetDeviceDraft? _draft;

  Future<void> _refreshCompatibility() async {
    if (_busy || _submitting || _submissionInFlight) return;
    final deviceRef = _selectedDeviceRef;
    final summaries = ref.read(thermostatsProvider).asData?.value;
    if (deviceRef == null || summaries == null) {
      setState(
        () => _gateOverride =
            'Thermostat list is unavailable. Retry after it loads.',
      );
      return;
    }
    final matches = summaries
        .where((item) => item.thermostat.deviceRef == deviceRef)
        .toList();
    if (matches.length != 1) {
      setState(() {
        _diagnostics = null;
        _thermostat = null;
        _gateOverride = matches.isEmpty
            ? 'No thermostat is linked to this immutable device reference.'
            : 'More than one thermostat uses this device reference. Resolve the duplicate link first.';
      });
      return;
    }
    final thermostat = matches.single;
    final gistId = thermostat.thermostat.diagnosticsGistId;
    if (gistId == null || gistId.isEmpty) {
      setState(() {
        _diagnostics = null;
        _thermostat = thermostat;
        _gateOverride = 'This thermostat has no diagnostics Gist configured.';
      });
      return;
    }
    setState(() {
      _checkingCompatibility = true;
      _gateOverride = null;
      _diagnostics = null;
      _thermostat = thermostat;
    });
    final requestedAt = _now();
    final editorGeneration = _editorGeneration;
    try {
      final provider = deviceDiagnosticsProvider(thermostat.thermostat.id);
      ref.invalidate(provider);
      final snapshot = await ref.read(provider.future);
      if (!mounted ||
          editorGeneration != _editorGeneration ||
          deviceRef != _selectedDeviceRef) {
        return;
      }
      setState(() {
        _diagnostics = snapshot;
        _diagnosticsRequestedAt = requestedAt;
        _checkingCompatibility = false;
      });
    } catch (_) {
      if (mounted &&
          editorGeneration == _editorGeneration &&
          deviceRef == _selectedDeviceRef) {
        setState(() {
          _checkingCompatibility = false;
          _diagnostics = null;
          _diagnosticsRequestedAt = requestedAt;
          _gateOverride =
              'Fresh device diagnostics could not be read. Retry before editing.';
        });
      }
    }
  }

  _GateResult _checkGate({required bool requireFreshFetch}) {
    if (_unknownOutcomeChangeId != null || _submissionOutcomeUnresolved) {
      return const _GateResult.denied(
        'A previous submission outcome is unresolved. Replacement submissions are disabled; review the private repository and device status before editing again.',
      );
    }
    final configuration = _configuration;
    final deviceRef = _selectedDeviceRef;
    final thermostat = _thermostat;
    final snapshot = _diagnostics;
    final requestedAt = _diagnosticsRequestedAt;
    if (configuration == null ||
        deviceRef == null ||
        _session?.isActive != true) {
      return const _GateResult.denied('Fetch a configuration before editing.');
    }
    if (!configuration.devices.containsKey(deviceRef)) {
      return const _GateResult.denied(
        'The selected device is no longer in this fleet file.',
      );
    }
    if (_gateOverride != null) return _GateResult.denied(_gateOverride!);
    if (thermostat == null || thermostat.thermostat.deviceRef != deviceRef) {
      return const _GateResult.denied(
        'Thermostat association does not match the immutable device reference.',
      );
    }
    final gistId = thermostat.thermostat.diagnosticsGistId;
    if (gistId == null || gistId.isEmpty) {
      return const _GateResult.denied(
        'A diagnostics Gist is required for compatibility checks.',
      );
    }
    if (gistId != configuration.devices[deviceRef]!.diagnosticsGistId) {
      return const _GateResult.denied(
        'The diagnostics Gist does not match the selected device configuration.',
      );
    }
    if (snapshot == null || snapshot.deviceRef != deviceRef) {
      return const _GateResult.denied(
        'Fresh diagnostics for this device are not available.',
      );
    }
    if (snapshot.configurationStatus == null) {
      return const _GateResult.denied(
        'This device does not report configuration acknowledgements.',
      );
    }
    if (!snapshot.supportsFleetSchema1) {
      return const _GateResult.denied(
        'Running or retained firmware cannot confirm fleet schema 1.',
      );
    }
    final updatedAt = snapshot.gistUpdatedAt;
    if (updatedAt == null) {
      return const _GateResult.denied(
        'Diagnostics do not include a Gist update time.',
      );
    }
    final now = _now();
    final age = now.difference(updatedAt);
    final pollInterval = ref
        .read(alertConfigProvider)
        .asData
        ?.value
        .pollInterval;
    if (snapshot.fetchedAt.isAfter(now) ||
        age.isNegative ||
        pollInterval == null ||
        age > staleDataThreshold(pollInterval)) {
      return const _GateResult.denied(
        'Device diagnostics are stale or have an invalid timestamp. Refresh and retry.',
      );
    }
    if (requestedAt == null || snapshot.fetchedAt.isBefore(requestedAt)) {
      return const _GateResult.denied(
        'Diagnostics must be refreshed explicitly before editing.',
      );
    }
    if (requireFreshFetch &&
        snapshot.fetchedAt.isBefore(
          _now().subtract(const Duration(seconds: 20)),
        )) {
      return const _GateResult.denied(
        'The compatibility check is no longer fresh. Refresh and retry.',
      );
    }
    return const _GateResult.allowed();
  }

  Future<void> _beginEditing() async {
    final gate = _checkGate(requireFreshFetch: true);
    if (!gate.allowed) {
      setState(() => _gateOverride = gate.reason);
      return;
    }
    if (_retainedDraftAvailable &&
        (!_latestFetchedForReapply ||
            _retainedDraftExpiresAt == null ||
            !_now().isBefore(_retainedDraftExpiresAt!))) {
      _expireRetainedDraft();
      return;
    }
    final config = _configuration!.devices[_selectedDeviceRef]!;
    if (_retainedDraftAvailable) {
      _reapplyDraftReviewing = true;
    } else {
      _discardDraft();
      _draft = _FleetDeviceDraft(config);
      _draftBaseDevice = config;
    }
    setState(() {
      _editing = true;
      _notice = _reapplyDraftReviewing
          ? 'Saved draft loaded for review. Compare it with the latest values above; secret fields may be older. Submitting will explicitly apply these reviewed fields over the freshly fetched file.'
          : 'Drafts stay on this screen and are cleared when the session ends.';
    });
  }

  bool _submitContextIsCurrent({
    required int attemptGeneration,
    required int editorGeneration,
    required int draftGeneration,
    required _FleetDeviceDraft draft,
    required FleetEditSession session,
    required FleetConfiguration configuration,
    required String deviceRef,
    required DateTime originalDeadline,
  }) =>
      mounted &&
      attemptGeneration == _submissionAttemptGeneration &&
      editorGeneration == _editorGeneration &&
      draftGeneration == _draftGeneration &&
      identical(_draft, draft) &&
      identical(_session, session) &&
      identical(_configuration, configuration) &&
      _selectedDeviceRef == deviceRef &&
      session.isActive &&
      _now().isBefore(originalDeadline);

  bool _draftKeepsLatestWifiPath(
    _FleetDeviceDraft draft,
    FleetDeviceConfiguration currentBase,
  ) => _reapplyDraftReviewing
      ? draft.hasWifiProfileUnchangedFrom(currentBase)
      : draft.hasUntouchedWifiPath;

  Future<void> _submit() async {
    if (_submitting || _submissionInFlight) return;
    final draft = _draft;
    final session = _session;
    final configuration = _configuration;
    final selectedRef = _selectedDeviceRef;
    final originalDeadline = _retainedDraftAvailable
        ? _retainedDraftExpiresAt
        : _sessionExpiresAt;
    if (draft == null ||
        session == null ||
        configuration == null ||
        selectedRef == null ||
        originalDeadline == null ||
        !session.isActive ||
        !_now().isBefore(originalDeadline)) {
      _endSession(
        'Session ended. Fetch the latest configuration before continuing.',
      );
      return;
    }
    if (_retainedDraftAvailable &&
        (!_latestFetchedForReapply || !_reapplyDraftReviewing)) {
      setState(() {
        _notice =
            'Fetch the latest file and explicitly load the saved draft for review before submitting.';
      });
      return;
    }
    if (!draft.formKey.currentState!.validate()) return;
    final currentBase = configuration.devices[selectedRef];
    if (currentBase == null) {
      _endSession(
        'The selected immutable device is missing from the latest file. This draft cannot be submitted.',
      );
      return;
    }
    if (!_draftKeepsLatestWifiPath(draft, currentBase)) {
      setState(
        () => _notice = _reapplyDraftReviewing
            ? 'The latest file uses a different Wi-Fi profile. Add at least one latest profile unchanged to the reviewed draft before submitting.'
            : 'Keep at least one existing Wi-Fi profile unchanged. Add a replacement before retiring an old path.',
      );
      return;
    }
    final edited = draft.toConfiguration(currentBase);
    try {
      final nextDevices = Map<String, FleetDeviceConfiguration>.of(
        configuration.devices,
      );
      nextDevices[selectedRef] = edited;
      FleetConfiguration.parse(
        jsonEncode(
          FleetConfiguration(
            revision: configuration.revision,
            devices: nextDevices,
          ).toJson(),
        ),
      );
    } on FormatException {
      setState(
        () => _notice =
            'Some values do not meet fleet configuration rules. Review the fields and check for duplicate logical IDs.',
      );
      return;
    }
    final initialGate = _checkGate(requireFreshFetch: true);
    if (!initialGate.allowed) {
      setState(() => _gateOverride = initialGate.reason);
      return;
    }

    final attemptGeneration = ++_submissionAttemptGeneration;
    final editorGeneration = _editorGeneration;
    final draftGeneration = _draftGeneration;
    final confirmation = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Submit desired settings?'),
        content: Text(
          _reapplyDraftReviewing
              ? 'This manually reapplies reviewed draft fields over the latest fetched file. Concurrent edits to the same fields may be replaced, and saved secret values may be outdated. Review the latest values and secret fields carefully. This updates the repository only; it does not mean the device applied the change.'
              : 'This updates the private repository only. It does not mean the device has applied the change.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    if (confirmation != true || !mounted) return;
    if (!_submitContextIsCurrent(
      attemptGeneration: attemptGeneration,
      editorGeneration: editorGeneration,
      draftGeneration: draftGeneration,
      draft: draft,
      session: session,
      configuration: configuration,
      deviceRef: selectedRef,
      originalDeadline: originalDeadline,
    )) {
      return;
    }
    final latestBaseBeforeCheck = configuration.devices[selectedRef];
    if (latestBaseBeforeCheck == null ||
        !_draftKeepsLatestWifiPath(draft, latestBaseBeforeCheck)) {
      setState(() {
        _submitting = false;
        _notice =
            'The Wi-Fi profiles no longer include an unchanged profile from the latest file. Review and add one before submitting.';
      });
      return;
    }
    setState(() {
      _submitting = true;
      _notice = 'Refreshing device compatibility before submission…';
    });
    final submittedThermostatId = _thermostat!.thermostat.id;
    final requestedAt = _now();
    try {
      final provider = deviceDiagnosticsProvider(submittedThermostatId);
      ref.invalidate(provider);
      final freshSnapshot = await ref.read(provider.future);
      final latestSummaries = await ref.read(thermostatsProvider.future);
      if (!_submitContextIsCurrent(
        attemptGeneration: attemptGeneration,
        editorGeneration: editorGeneration,
        draftGeneration: draftGeneration,
        draft: draft,
        session: session,
        configuration: configuration,
        deviceRef: selectedRef,
        originalDeadline: originalDeadline,
      )) {
        return;
      }
      final currentBaseAfterCheck = configuration.devices[selectedRef];
      if (currentBaseAfterCheck == null ||
          !_draftKeepsLatestWifiPath(draft, currentBaseAfterCheck)) {
        setState(() {
          _submitting = false;
          _notice =
              'The latest Wi-Fi profile must be included unchanged in the draft. Review the latest file before trying again.';
        });
        return;
      }
      final linked = latestSummaries
          .where((item) => item.thermostat.id == submittedThermostatId)
          .toList();
      final freshGate = _gateForSnapshot(
        snapshot: freshSnapshot,
        requestedAt: requestedAt,
        summaries: latestSummaries,
        thermostatId: submittedThermostatId,
        deviceRef: selectedRef,
      );
      if (linked.length != 1 || !freshGate.allowed) {
        setState(() {
          _submitting = false;
          _gateOverride = freshGate.reason;
          _diagnostics = freshSnapshot;
          _diagnosticsRequestedAt = requestedAt;
        });
        return;
      }
      if (!_submitContextIsCurrent(
            attemptGeneration: attemptGeneration,
            editorGeneration: editorGeneration,
            draftGeneration: draftGeneration,
            draft: draft,
            session: session,
            configuration: configuration,
            deviceRef: selectedRef,
            originalDeadline: originalDeadline,
          ) ||
          !_draftKeepsLatestWifiPath(draft, currentBaseAfterCheck)) {
        return;
      }

      _submissionInFlight = true;
      final result = await session.submitChange(
        deviceRef: selectedRef,
        editedDeviceConfig: edited,
      );
      _submissionInFlight = false;
      if (!mounted) return;
      FleetConfiguration? latestAfterConflict;
      if (result.status == FleetSubmissionStatus.needsReapply &&
          result.latestSnapshot != null) {
        try {
          latestAfterConflict = FleetConfiguration.parse(
            result.latestSnapshot!.content,
          );
        } on FormatException {
          latestAfterConflict = null;
        }
      }
      final contextStillCurrent = _submitContextIsCurrent(
        attemptGeneration: attemptGeneration,
        editorGeneration: editorGeneration,
        draftGeneration: draftGeneration,
        draft: draft,
        session: session,
        configuration: configuration,
        deviceRef: selectedRef,
        originalDeadline: originalDeadline,
      );
      final preserveForManualReapply =
          result.status == FleetSubmissionStatus.needsReapply &&
          contextStillCurrent &&
          identical(_draft, draft) &&
          latestAfterConflict != null &&
          latestAfterConflict.devices.containsKey(selectedRef) &&
          _now().isBefore(originalDeadline);
      final resultNotice = switch (result.status) {
        FleetSubmissionStatus.submittedPending =>
          'Submitted; waiting for the device to report this exact change.',
        FleetSubmissionStatus.needsReapply when preserveForManualReapply =>
          'The repository changed. Its latest file is shown above; your draft is kept separately until the original session expires. Fetch again to start a new session, refresh compatibility, then review the saved draft before manually submitting.',
        FleetSubmissionStatus.needsReapply =>
          latestAfterConflict != null &&
                  !latestAfterConflict.devices.containsKey(selectedRef)
              ? 'The selected device was removed from the latest file. The draft was discarded and cannot be reapplied.'
              : 'The repository changed, but the draft was cleared because its edit session ended. Fetch the latest file and recreate your changes manually.',
        FleetSubmissionStatus.outcomeUnknown =>
          'Submission outcome is unknown. The draft was cleared and replacement submissions are disabled for this screen. Do not retry blindly.',
      };
      setState(() {
        _submitting = false;
        _editing = false;
        _pendingChangeId =
            result.status == FleetSubmissionStatus.submittedPending
            ? result.changeId
            : null;
        _pendingThermostatId =
            result.status == FleetSubmissionStatus.submittedPending
            ? submittedThermostatId
            : null;
        _pendingDeviceRef =
            result.status == FleetSubmissionStatus.submittedPending
            ? selectedRef
            : null;
        _pendingDiagnosticsGistId =
            result.status == FleetSubmissionStatus.submittedPending
            ? _thermostat?.thermostat.diagnosticsGistId
            : null;
        _pendingSince = result.status == FleetSubmissionStatus.submittedPending
            ? _now()
            : null;
        _pendingApplied = false;
        _checkingPending = false;
        _pendingGeneration++;
        _unknownOutcomeChangeId =
            result.status == FleetSubmissionStatus.outcomeUnknown
            ? result.changeId
            : null;
        _submissionOutcomeUnresolved =
            result.status == FleetSubmissionStatus.outcomeUnknown;
        if (preserveForManualReapply) {
          _retainedDraftAvailable = true;
          _latestFetchedForReapply = false;
          _reapplyDraftReviewing = false;
          _retainedDraftExpiresAt = originalDeadline;
          _retainedDraftTimer ??= Timer(
            originalDeadline.difference(_now()),
            _expireRetainedDraft,
          );
        }
        _notice = resultNotice;
      });
      _endSession(
        resultNotice,
        preserveDraft: preserveForManualReapply,
        keepConfiguration: result.status == FleetSubmissionStatus.needsReapply
            ? latestAfterConflict
            : null,
      );
    } catch (_) {
      final mayHaveBeenSent = _submissionInFlight;
      _submissionInFlight = false;
      if (!mounted || attemptGeneration != _submissionAttemptGeneration) {
        return;
      }
      if (mayHaveBeenSent) {
        _submissionOutcomeUnresolved = true;
        _unknownOutcomeChangeId ??= 'unresolved';
        _pendingGeneration++;
        _endSession(
          'Submission outcome could not be confirmed. Replacement submissions are disabled for this screen. Do not retry blindly.',
        );
        return;
      }
      if (editorGeneration == _editorGeneration) {
        setState(() {
          _submitting = false;
          _notice =
              'Could not refresh compatibility before submission. No repository update was started; refresh and try again.';
        });
      }
    }
  }

  _GateResult _gateForSnapshot({
    required DeviceDiagnosticsSnapshot? snapshot,
    required DateTime requestedAt,
    required List<ThermostatSummary> summaries,
    required String thermostatId,
    required String deviceRef,
  }) {
    final linked = summaries
        .where((item) => item.thermostat.id == thermostatId)
        .toList();
    final sameReference = summaries
        .where((item) => item.thermostat.deviceRef == deviceRef)
        .toList();
    if (linked.length != 1 ||
        sameReference.length != 1 ||
        linked.single.thermostat.deviceRef != deviceRef) {
      return const _GateResult.denied(
        'Thermostat association changed. Refresh and retry.',
      );
    }
    final linkedThermostat = linked.single.thermostat;
    if (linkedThermostat.diagnosticsGistId == null ||
        linkedThermostat.diagnosticsGistId!.isEmpty) {
      return const _GateResult.denied(
        'A diagnostics Gist is required for compatibility checks.',
      );
    }
    if (linkedThermostat.diagnosticsGistId !=
        _configuration?.devices[deviceRef]?.diagnosticsGistId) {
      return const _GateResult.denied(
        'The diagnostics Gist association changed. Refresh and retry.',
      );
    }
    if (snapshot == null || snapshot.deviceRef != deviceRef) {
      return const _GateResult.denied(
        'Fresh diagnostics do not match this device.',
      );
    }
    if (snapshot.configurationStatus == null) {
      return const _GateResult.denied(
        'This device does not report configuration acknowledgements.',
      );
    }
    if (!snapshot.supportsFleetSchema1) {
      return const _GateResult.denied(
        'Running or retained firmware cannot confirm fleet schema 1.',
      );
    }
    final published = snapshot.gistUpdatedAt;
    final pollInterval = ref
        .read(alertConfigProvider)
        .asData
        ?.value
        .pollInterval;
    if (published == null || pollInterval == null) {
      return const _GateResult.denied(
        'A fresh diagnostics timestamp is required.',
      );
    }
    final age = _now().difference(published);
    if (snapshot.fetchedAt.isAfter(_now()) ||
        age.isNegative ||
        age > staleDataThreshold(pollInterval)) {
      return const _GateResult.denied(
        'Device diagnostics are stale. Refresh and retry.',
      );
    }
    if (snapshot.fetchedAt.isBefore(requestedAt)) {
      return const _GateResult.denied(
        'Diagnostics were not fetched after the pre-submit refresh.',
      );
    }
    return const _GateResult.allowed();
  }

  Future<void> _checkPendingStatus() async {
    final changeId = _pendingChangeId;
    final thermostatId = _pendingThermostatId;
    final deviceRef = _pendingDeviceRef;
    final diagnosticsGistId = _pendingDiagnosticsGistId;
    final pendingSince = _pendingSince;
    if (changeId == null ||
        thermostatId == null ||
        deviceRef == null ||
        diagnosticsGistId == null ||
        pendingSince == null) {
      return;
    }
    final generation = _pendingGeneration;
    setState(() => _checkingPending = true);
    final requestedAt = _now();
    try {
      final provider = deviceDiagnosticsProvider(thermostatId);
      ref.invalidate(provider);
      final snapshot = await ref.read(provider.future);
      final summaries = await ref.read(thermostatsProvider.future);
      final linked = summaries
          .where((item) => item.thermostat.id == thermostatId)
          .toList();
      final sameReference = summaries
          .where((item) => item.thermostat.deviceRef == deviceRef)
          .toList();
      if (!mounted ||
          !_isCurrentPending(
            generation: generation,
            changeId: changeId,
            thermostatId: thermostatId,
            deviceRef: deviceRef,
            diagnosticsGistId: diagnosticsGistId,
            pendingSince: pendingSince,
          )) {
        return;
      }
      final alertConfig = ref.read(alertConfigProvider).asData?.value;
      if (alertConfig == null) {
        setState(() {
          _checkingPending = false;
          _notice =
              'Device status is waiting for alert settings to load. Try again shortly.';
        });
        return;
      }
      final fresh =
          linked.length == 1 &&
          sameReference.length == 1 &&
          linked.single.thermostat.deviceRef == deviceRef &&
          linked.single.thermostat.diagnosticsGistId == diagnosticsGistId &&
          snapshot?.deviceRef == deviceRef &&
          snapshot != null &&
          snapshot.configurationStatus != null &&
          snapshot.supportsFleetSchema1 &&
          snapshot.gistUpdatedAt != null &&
          !snapshot.fetchedAt.isAfter(_now()) &&
          !snapshot.gistUpdatedAt!.isAfter(_now()) &&
          snapshot.gistUpdatedAt!.isAfter(pendingSince) &&
          _now().difference(snapshot.gistUpdatedAt!) <=
              staleDataThreshold(alertConfig.pollInterval) &&
          !snapshot.fetchedAt.isBefore(requestedAt);
      if (mounted &&
          _isCurrentPending(
            generation: generation,
            changeId: changeId,
            thermostatId: thermostatId,
            deviceRef: deviceRef,
            diagnosticsGistId: diagnosticsGistId,
            pendingSince: pendingSince,
          )) {
        setState(() {
          _checkingPending = false;
          _pendingApplied =
              fresh && snapshot.isApplied(changeId, isFresh: true);
          _notice = _pendingApplied
              ? 'Applied — the device reported this exact change ID.'
              : 'Still waiting for the device to report this exact change.';
        });
      }
    } catch (_) {
      if (mounted &&
          _isCurrentPending(
            generation: generation,
            changeId: changeId,
            thermostatId: thermostatId,
            deviceRef: deviceRef,
            diagnosticsGistId: diagnosticsGistId,
            pendingSince: pendingSince,
          )) {
        setState(() {
          _checkingPending = false;
          _notice = 'A fresh device status could not be read. Try again later.';
        });
      }
    }
  }

  bool _isCurrentPending({
    required int generation,
    required String changeId,
    required String thermostatId,
    required String deviceRef,
    required String diagnosticsGistId,
    required DateTime pendingSince,
  }) =>
      _pendingGeneration == generation &&
      _pendingChangeId == changeId &&
      _pendingThermostatId == thermostatId &&
      _pendingDeviceRef == deviceRef &&
      _pendingDiagnosticsGistId == diagnosticsGistId &&
      _pendingSince == pendingSince;

  void _selectDevice(String? reference) {
    if (reference == null || reference == _selectedDeviceRef) return;
    final hadRetainedDraft = _retainedDraftAvailable;
    _discardDraft();
    setState(() {
      _selectedDeviceRef = reference;
      _diagnostics = null;
      _diagnosticsRequestedAt = null;
      _thermostat = null;
      _gateOverride = null;
      _editing = false;
      if (hadRetainedDraft) {
        _notice =
            'Changing the selected device cleared the saved draft; it cannot be applied to a different immutable device reference.';
      }
    });
  }

  void _maskSecrets({bool clear = false}) {
    _maskTimer?.cancel();
    _maskTimer = null;
    _revealUntil = null;
    if (clear) _clearDraft();
    if (mounted && _revealed) setState(() => _revealed = false);
  }

  Future<void> _toggleReveal() async {
    if (_revealed) {
      _maskSecrets();
      return;
    }
    final editorGeneration = _editorGeneration;
    final draftGeneration = _draftGeneration;
    final session = _session;
    final draft = _draft;
    final deviceRef = _selectedDeviceRef;
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.visibility_outlined),
        title: const Text('Reveal private settings?'),
        content: const Text(
          'Anyone nearby could read these values. Screenshots or copied text can expose credentials. Values will be hidden again after 30 seconds.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep hidden'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reveal for 30 seconds'),
          ),
        ],
      ),
    );
    if (allow == true &&
        mounted &&
        editorGeneration == _editorGeneration &&
        draftGeneration == _draftGeneration &&
        identical(session, _session) &&
        session?.isActive == true &&
        identical(draft, _draft) &&
        _editing &&
        deviceRef == _selectedDeviceRef) {
      setState(() {
        _revealed = true;
        _revealUntil = _now().add(const Duration(seconds: 30));
      });
      _maskTimer?.cancel();
      _maskTimer = Timer(const Duration(seconds: 30), _maskSecrets);
    }
  }

  Future<void> _toggleWriterTokenReveal() async {
    if (_writerTokenRevealed) {
      _maskWriterToken();
      return;
    }
    final consentGeneration = _writerTokenConsentGeneration;
    final controller = _writerToken;
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.visibility_outlined),
        title: const Text('Reveal writer token?'),
        content: const Text(
          'Anyone nearby could read this token. Screenshots or copied text can expose it. The token will be hidden again after 30 seconds.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep hidden'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reveal for 30 seconds'),
          ),
        ],
      ),
    );
    if (allow == true &&
        mounted &&
        consentGeneration == _writerTokenConsentGeneration &&
        identical(controller, _writerToken) &&
        controller.text.isNotEmpty) {
      setState(() => _writerTokenRevealed = true);
      _writerTokenMaskTimer?.cancel();
      _writerTokenMaskTimer = Timer(
        const Duration(seconds: 30),
        _maskWriterToken,
      );
    }
  }

  void _maskWriterToken({bool clear = false}) {
    _writerTokenMaskTimer?.cancel();
    _writerTokenMaskTimer = null;
    if (clear) _writerToken.clear();
    if (mounted && _writerTokenRevealed) {
      setState(() => _writerTokenRevealed = false);
    } else {
      _writerTokenRevealed = false;
    }
  }

  Future<void> _copySecret(TextEditingController controller) async {
    final draft = _draft;
    final session = _session;
    final deviceRef = _selectedDeviceRef;
    final editorGeneration = _editorGeneration;
    final draftGeneration = _draftGeneration;
    if (controller.text.isEmpty ||
        !_editing ||
        session?.isActive != true ||
        draft == null ||
        !draft.containsSecretController(controller)) {
      return;
    }
    final allowed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Copy private value?'),
        content: const Text(
          'Copied values may remain in the clipboard and can be seen by other apps. Continue only on a trusted device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Copy value'),
          ),
        ],
      ),
    );
    if (allowed == true &&
        mounted &&
        editorGeneration == _editorGeneration &&
        draftGeneration == _draftGeneration &&
        identical(draft, _draft) &&
        identical(session, _session) &&
        session?.isActive == true &&
        deviceRef == _selectedDeviceRef &&
        _editing &&
        draft.containsSecretController(controller) &&
        controller.text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: controller.text));
    }
  }

  Future<void> _clearConnection() async {
    _endSession('Saved connection cleared.');
    try {
      await _store.clearConnection();
      _owner.clear();
      _repo.clear();
      _branch.text = 'main';
      _path.text = 'fleet.json';
      _writerToken.clear();
      _pendingChangeId = null;
      _pendingThermostatId = null;
      _pendingDeviceRef = null;
      _pendingDiagnosticsGistId = null;
      _pendingSince = null;
      _pendingApplied = false;
      _checkingPending = false;
      _pendingGeneration++;
      if (mounted) {
        setState(() {
          _busy = false;
          _configuration = null;
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
    final summariesAsync = config == null
        ? const AsyncData<List<ThermostatSummary>>(<ThermostatSummary>[])
        : ref.watch(thermostatsProvider);
    if (config != null) ref.watch(alertConfigProvider);
    final summaries =
        summariesAsync.asData?.value ?? const <ThermostatSummary>[];
    final selectedConfig = config == null || _selectedDeviceRef == null
        ? null
        : config.devices[_selectedDeviceRef];
    final gate = _checkGate(requireFreshFetch: true);
    return Scaffold(
      appBar: AppBar(title: const Text('Device configuration')),
      body: SafeArea(
        child: _busy && config == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  _desiredStateHero(theme, colors),
                  const SizedBox(height: 14),
                  _statusCard(theme, colors),
                  if (_notice != null) ...[
                    const SizedBox(height: 12),
                    _statusBanner(message: _notice!),
                  ],
                  if (_pendingChangeId != null) ...[
                    const SizedBox(height: 14),
                    _pendingCard(theme, colors),
                  ],
                  const SizedBox(height: 20),
                  _connectionPanel(theme),
                  if (config != null) ...[
                    const SizedBox(height: 22),
                    _configurationPanel(
                      theme,
                      config,
                      selectedConfig,
                      summaries,
                    ),
                    if (_retainedDraftAvailable) ...[
                      const SizedBox(height: 12),
                      _savedDraftReviewCard(theme),
                    ],
                    if (selectedConfig != null) ...[
                      const SizedBox(height: 16),
                      _compatibilityPanel(theme, gate),
                      if (_editing && _draft != null) ...[
                        const SizedBox(height: 16),
                        _editorPanel(theme, _draft!),
                      ],
                    ],
                  ],
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      leading: Icon(
                        Icons.lock_clock_outlined,
                        color: colors.primary,
                      ),
                      title: Text(
                        _editing
                            ? 'Five-minute compatibility session'
                            : 'Editing is guarded by a fresh compatibility check',
                      ),
                      subtitle: Text(
                        _editing
                            ? 'Draft values are temporary and disappear when this session ends.'
                            : 'Changes remain unavailable until this device is freshly confirmed as compatible.',
                      ),
                      trailing: Icon(
                        _editing
                            ? Icons.verified_user_outlined
                            : Icons.lock_outline,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _desiredStateHero(ThemeData theme, ColorScheme colors) => Container(
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
          'This private file describes what devices should use. A repository update is not proof that a device applied it.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onPrimaryContainer,
          ),
        ),
      ],
    ),
  );

  Widget _statusCard(ThemeData theme, ColorScheme colors) => Card(
    color: colors.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.sync_problem_outlined, color: colors.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Device-applied status is separate. FarmCtl will show Applied only after a fresh diagnostic report confirms the exact submitted change ID.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onErrorContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _connectionPanel(ThemeData theme) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Private repository connection',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            'The connection is stored securely on this phone. The fleet file is fetched only when you ask.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          Form(
            key: _connectionForm,
            child: Column(
              children: [
                _textField(_owner, 'Repository owner'),
                _textField(_repo, 'Repository name'),
                _textField(_branch, 'Branch'),
                _textField(_path, 'Fleet file path'),
                TextFormField(
                  controller: _writerToken,
                  obscureText: !_writerTokenRevealed,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Writer token',
                    helperText: 'Used only for this private repository.',
                    suffixIcon: IconButton(
                      tooltip: _writerTokenRevealed
                          ? 'Hide token'
                          : 'Reveal writer token',
                      onPressed: _toggleWriterTokenReveal,
                      icon: Icon(
                        _writerTokenRevealed
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                    ),
                  ),
                  validator: (value) => value == null || value.isEmpty
                      ? 'Enter the writer token to save.'
                      : null,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _saveConnection,
                      icon: const Icon(Icons.lock_outline),
                      label: const Text('Save connection'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _openSession,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Fetch desired state'),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _clearConnection,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Clear connection'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _configurationPanel(
    ThemeData theme,
    FleetConfiguration config,
    FleetDeviceConfiguration? selected,
    List<ThermostatSummary> summaries,
  ) {
    final selectedRef = _selectedDeviceRef!;
    final session = _session;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fleet file', style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'Revision ${config.revision} · fetched ${_sessionOpenedAt == null ? 'just now' : TimeOfDay.fromDateTime(_sessionOpenedAt!).format(context)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: selectedRef,
              decoration: const InputDecoration(
                labelText: 'Immutable device reference',
              ),
              items: [
                for (final reference in config.devices.keys)
                  DropdownMenuItem(
                    value: reference,
                    child: Text(reference, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _editing ? null : _selectDevice,
            ),
            if (selected != null) ...[
              const SizedBox(height: 12),
              Text(
                'Logical ID · ${selected.logicalId}',
                style: theme.textTheme.bodyLarge,
              ),
              Text(
                'Sample ${selected.sampleIntervalSeconds}s · publication ${selected.publicationIntervalSeconds}s',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                '${selected.wifiProfiles.length} Wi-Fi profile${selected.wifiProfiles.length == 1 ? '' : 's'} configured · details hidden',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: session?.isActive == true && !_editing
                    ? () => _endSession(
                        'Session closed. Fetch the latest configuration to edit again.',
                      )
                    : null,
                icon: const Icon(Icons.close),
                label: const Text('Close session'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _compatibilityPanel(ThemeData theme, _GateResult gate) {
    final color = gate.allowed
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  gate.allowed
                      ? Icons.verified_outlined
                      : Icons.shield_outlined,
                  color: color,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    gate.allowed ? 'Compatibility confirmed' : 'Editing locked',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              gate.allowed
                  ? 'This device has a fresh acknowledgement-capable report and both running and retained firmware support schema 1.'
                  : gate.reason,
              style: theme.textTheme.bodyMedium,
            ),
            if (_checkingCompatibility) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: _checkingCompatibility || _editing
                      ? null
                      : _refreshCompatibility,
                  icon: const Icon(Icons.sync),
                  label: Text(
                    _checkingCompatibility
                        ? 'Checking device…'
                        : 'Refresh compatibility',
                  ),
                ),
                FilledButton.icon(
                  onPressed: gate.allowed && !_editing && !_submitting
                      ? _beginEditing
                      : null,
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(
                    _retainedDraftAvailable
                        ? 'Review saved draft'
                        : 'Edit desired settings',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _savedDraftReviewCard(ThemeData theme) {
    final selectedReference = _selectedDeviceRef;
    final latest = _selectedDeviceRef == null
        ? null
        : _configuration?.devices[_selectedDeviceRef];
    final otherLogicalIds =
        _configuration?.devices.entries
            .where((entry) => entry.key != selectedReference)
            .map((entry) => entry.value.logicalId)
            .toList(growable: false) ??
        const <String>[];
    final changes = _latestChangesSinceDraft();
    final hasFreshSession = _session?.isActive == true;
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.compare_arrows,
                  color: theme.colorScheme.onTertiaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Saved draft · review before resubmitting',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              latest == null
                  ? 'The selected immutable device is not present in the latest file. This draft cannot be used.'
                  : _latestFetchedForReapply
                  ? 'The latest file was fetched in a new five-minute session and is shown above. The saved values remain separate; no edits have been reapplied or submitted.'
                  : 'The service fetched the latest file after the conflict; its current values are shown above. Fetch desired state to start a new edit session before compatibility can be refreshed.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
            if (_latestFetchedForReapply && changes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Latest file also changed since this draft began: ${changes.join(', ')}. Current non-secret values appear above; compare before deciding which values to keep.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Private credentials and network values are not shown here. Retained secret fields may be outdated. Check that the logical ID stays unique; the schema validator will reject duplicates. The draft expires with its original session and is cleared on backgrounding or exit.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
            if (otherLogicalIds.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Other logical IDs in the latest file: ${otherLogicalIds.join(', ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ],
            if (!hasFreshSession) ...[
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: _busy ? null : _openSession,
                icon: const Icon(Icons.refresh),
                label: const Text('Fetch latest file for a new session'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<String> _latestChangesSinceDraft() {
    final original = _draftBaseDevice;
    final deviceRef = _selectedDeviceRef;
    final latest = deviceRef == null
        ? null
        : _configuration?.devices[deviceRef];
    if (original == null || latest == null) return const [];
    final changes = <String>[];
    if (original.logicalId != latest.logicalId) changes.add('logical ID');
    if (original.sampleIntervalSeconds != latest.sampleIntervalSeconds) {
      changes.add('sample interval');
    }
    if (original.publicationIntervalSeconds !=
        latest.publicationIntervalSeconds) {
      changes.add('publication interval');
    }
    if (jsonEncode(
          original.wifiProfiles.map((profile) => profile.toJson()).toList(),
        ) !=
        jsonEncode(
          latest.wifiProfiles.map((profile) => profile.toJson()).toList(),
        )) {
      changes.add('Wi-Fi profiles');
    }
    if (original.configReadCredential != latest.configReadCredential ||
        original.temperatureGistId != latest.temperatureGistId ||
        original.diagnosticsGistId != latest.diagnosticsGistId ||
        original.gistWriteCredential != latest.gistWriteCredential) {
      changes.add('private credentials or destinations');
    }
    return changes;
  }

  Widget _editorPanel(ThemeData theme, _FleetDeviceDraft draft) {
    final gate = _checkGate(requireFreshFetch: true);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Form(
          key: draft.formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Edit desired settings',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: _revealed
                        ? 'Hide private values'
                        : 'Reveal private values',
                    onPressed: _toggleReveal,
                    icon: Icon(
                      _revealed ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ],
              ),
              Text(
                'Device reference ${_selectedDeviceRef!} cannot be changed. Never remove every existing Wi-Fi path; add and verify a replacement before retiring an old one.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Private values are hidden by default. Reveal lasts 30 seconds; copied text and screenshots can expose credentials.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              const SizedBox(height: 16),
              _draftField(draft.logicalId, 'Logical ID', secret: false),
              Row(
                children: [
                  Expanded(
                    child: _draftField(
                      draft.sampleInterval,
                      'Sample interval (10–300 seconds)',
                      secret: false,
                      numeric: true,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _draftField(
                      draft.publicationInterval,
                      'Publish interval (60–300 seconds)',
                      secret: false,
                      numeric: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Wi-Fi profiles',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: draft.profiles.length >= 3
                        ? null
                        : () => setState(draft.addProfile),
                    icon: const Icon(Icons.add),
                    label: const Text('Add profile'),
                  ),
                ],
              ),
              for (var index = 0; index < draft.profiles.length; index++)
                _wifiProfileEditor(draft, index, theme),
              const SizedBox(height: 12),
              _draftField(
                draft.configReadCredential,
                'Fleet read credential',
                secret: true,
                copy: true,
              ),
              _draftField(
                draft.temperatureGistId,
                'Temperature Gist ID',
                secret: true,
                copy: true,
              ),
              _draftField(
                draft.diagnosticsGistId,
                'Diagnostics Gist ID',
                secret: true,
                copy: true,
              ),
              _draftField(
                draft.gistWriteCredential,
                'Gist write credential',
                secret: true,
                copy: true,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _submitting || !gate.allowed ? null : _submit,
                    icon: _submitting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_upload_outlined),
                    label: Text(
                      _submitting
                          ? 'Checking before submit…'
                          : 'Submit desired settings',
                    ),
                  ),
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () {
                            _discardDraft();
                            _maskSecrets(clear: true);
                            setState(() => _editing = false);
                          },
                    child: const Text('Cancel draft'),
                  ),
                ],
              ),
              if (!gate.allowed)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    gate.reason,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _wifiProfileEditor(
    _FleetDeviceDraft draft,
    int index,
    ThemeData theme,
  ) {
    final profile = draft.profiles[index];
    return Card(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Profile ${index + 1}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Remove profile',
                  onPressed: draft.canRemoveProfile(index)
                      ? () => setState(() => draft.removeProfile(index))
                      : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
            _draftField(profile.id, 'Profile ID', secret: false),
            _draftField(profile.ssid, 'Network name', secret: true, copy: true),
            _draftField(
              profile.password,
              'Network password',
              secret: true,
              copy: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _draftField(
    TextEditingController controller,
    String label, {
    required bool secret,
    bool numeric = false,
    bool copy = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextFormField(
      controller: controller,
      obscureText: secret && !_revealed,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: secret || copy
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (copy)
                    IconButton(
                      tooltip: 'Copy $label',
                      onPressed: () => _copySecret(controller),
                      icon: const Icon(Icons.copy_outlined),
                    ),
                  if (secret)
                    Icon(
                      _revealed ? Icons.visibility : Icons.visibility_off,
                      semanticLabel: _revealed
                          ? 'Value visible'
                          : 'Value hidden',
                    ),
                ],
              )
            : null,
      ),
      validator: (value) {
        final text = value?.trim() ?? '';
        if (text.isEmpty) return 'Enter $label.';
        if (numeric && int.tryParse(text) == null) {
          return 'Enter a whole number.';
        }
        if (label == 'Logical ID' &&
            !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(text)) {
          return 'Use 1–64 letters, numbers, dots, underscores or hyphens.';
        }
        if (label == 'Profile ID' &&
            !RegExp(r'^[A-Za-z0-9._-]{1,32}$').hasMatch(text)) {
          return 'Use 1–32 letters, numbers, dots, underscores or hyphens.';
        }
        if (label.contains('Sample interval')) {
          final interval = int.tryParse(text);
          if (interval == null || interval < 10 || interval > 300) {
            return 'Use a value from 10 to 300 seconds.';
          }
        }
        if (label.contains('Publish interval')) {
          final interval = int.tryParse(text);
          if (interval == null || interval < 60 || interval > 300) {
            return 'Use a value from 60 to 300 seconds.';
          }
        }
        return null;
      },
    ),
  );

  Widget _pendingCard(ThemeData theme, ColorScheme colors) => Card(
    color: _pendingApplied ? colors.primaryContainer : colors.tertiaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _pendingApplied
                    ? Icons.check_circle_outline
                    : Icons.hourglass_top,
                color: _pendingApplied
                    ? colors.onPrimaryContainer
                    : colors.onTertiaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _pendingApplied ? 'Applied' : 'Submitted; waiting for device',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Change ID ${_pendingChangeId!}',
            style: theme.textTheme.bodySmall,
          ),
          Text(
            _pendingApplied
                ? 'A fresh report confirmed this exact change.'
                : 'Repository success is not device application. An unrelated acknowledgement will not complete this change.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _checkingPending ? null : _checkPendingStatus,
              icon: const Icon(Icons.refresh),
              label: Text(
                _checkingPending ? 'Checking…' : 'Check device status',
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _textField(TextEditingController controller, String label) => Padding(
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

  Widget _statusBanner({required String message}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(message),
  );
}

class _GateResult {
  const _GateResult.allowed() : allowed = true, reason = 'Ready';
  const _GateResult.denied(this.reason) : allowed = false;
  final bool allowed;
  final String reason;
}

class _FleetDeviceDraft {
  _FleetDeviceDraft(FleetDeviceConfiguration device)
    : initialProfiles = device.wifiProfiles
          .map(
            (profile) => _WifiProfileValue(
              profile.profileId,
              profile.ssid,
              profile.password,
            ),
          )
          .toList(),
      logicalId = TextEditingController(text: device.logicalId),
      sampleInterval = TextEditingController(
        text: '${device.sampleIntervalSeconds}',
      ),
      publicationInterval = TextEditingController(
        text: '${device.publicationIntervalSeconds}',
      ),
      configReadCredential = TextEditingController(
        text: device.configReadCredential,
      ),
      temperatureGistId = TextEditingController(text: device.temperatureGistId),
      diagnosticsGistId = TextEditingController(text: device.diagnosticsGistId),
      gistWriteCredential = TextEditingController(
        text: device.gistWriteCredential,
      ) {
    profiles.addAll(device.wifiProfiles.map(_WifiDraft.from));
  }

  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  final List<_WifiProfileValue> initialProfiles;
  final List<_WifiDraft> profiles = [];
  final TextEditingController logicalId;
  final TextEditingController sampleInterval;
  final TextEditingController publicationInterval;
  final TextEditingController configReadCredential;
  final TextEditingController temperatureGistId;
  final TextEditingController diagnosticsGistId;
  final TextEditingController gistWriteCredential;

  bool containsSecretController(TextEditingController controller) =>
      identical(controller, configReadCredential) ||
      identical(controller, temperatureGistId) ||
      identical(controller, diagnosticsGistId) ||
      identical(controller, gistWriteCredential) ||
      profiles.any(
        (profile) =>
            identical(controller, profile.ssid) ||
            identical(controller, profile.password),
      );

  void addProfile() => profiles.add(_WifiDraft.empty());
  bool get hasUntouchedWifiPath => initialProfiles.any(
    (original) => profiles.any((item) => item.sameAsValue(original)),
  );
  bool hasWifiProfileUnchangedFrom(FleetDeviceConfiguration device) =>
      device.wifiProfiles.any(
        (current) => profiles.any(
          (item) =>
              item.id.text == current.profileId &&
              item.ssid.text == current.ssid &&
              item.password.text == current.password,
        ),
      );
  bool canRemoveProfile(int index) {
    final remaining = [...profiles]..removeAt(index);
    return initialProfiles.any(
      (original) => remaining.any((item) => item.sameAsValue(original)),
    );
  }

  void removeProfile(int index) {
    final profile = profiles.removeAt(index);
    profile.dispose();
  }

  FleetDeviceConfiguration toConfiguration(FleetDeviceConfiguration original) =>
      FleetDeviceConfiguration(
        changeId: original.changeId,
        logicalId: logicalId.text.trim(),
        wifiProfiles: profiles
            .map(
              (profile) => FleetWifiProfile(
                profileId: profile.id.text.trim(),
                ssid: profile.ssid.text,
                password: profile.password.text,
              ),
            )
            .toList(),
        configReadCredential: configReadCredential.text,
        temperatureGistId: temperatureGistId.text.trim(),
        diagnosticsGistId: diagnosticsGistId.text.trim(),
        gistWriteCredential: gistWriteCredential.text,
        sampleIntervalSeconds: int.tryParse(sampleInterval.text) ?? -1,
        publicationIntervalSeconds:
            int.tryParse(publicationInterval.text) ?? -1,
      );

  void dispose() {
    for (final controller in [
      logicalId,
      sampleInterval,
      publicationInterval,
      configReadCredential,
      temperatureGistId,
      diagnosticsGistId,
      gistWriteCredential,
    ]) {
      controller.clear();
      controller.dispose();
    }
    for (final profile in profiles) {
      profile.dispose();
    }
    profiles.clear();
    initialProfiles.clear();
  }
}

class _WifiDraft {
  _WifiDraft({required this.id, required this.ssid, required this.password});
  factory _WifiDraft.from(FleetWifiProfile profile) => _WifiDraft(
    id: TextEditingController(text: profile.profileId),
    ssid: TextEditingController(text: profile.ssid),
    password: TextEditingController(text: profile.password),
  );
  factory _WifiDraft.empty() => _WifiDraft(
    id: TextEditingController(),
    ssid: TextEditingController(),
    password: TextEditingController(),
  );
  final TextEditingController id;
  final TextEditingController ssid;
  final TextEditingController password;
  bool sameAsValue(_WifiProfileValue other) =>
      id.text == other.id &&
      ssid.text == other.ssid &&
      password.text == other.password;
  void dispose() {
    for (final controller in [id, ssid, password]) {
      controller.clear();
      controller.dispose();
    }
  }
}

class _WifiProfileValue {
  const _WifiProfileValue(this.id, this.ssid, this.password);
  final String id;
  final String ssid;
  final String password;
}
