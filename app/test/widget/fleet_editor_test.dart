import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:farmctl/features/fleet/data/fleet_connection_store.dart';
import 'package:farmctl/features/fleet/data/fleet_contents_client.dart';
import 'package:farmctl/features/fleet/providers/fleet_providers.dart';
import 'package:farmctl/features/fleet/view/fleet_configuration_page.dart';
import 'package:farmctl/features/settings/models/alert_config.dart';
import 'package:farmctl/features/settings/providers/settings_providers.dart';
import 'package:farmctl/features/thermostats/models/device_diagnostics.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _deviceRef = 'immutable-ref-001';
const _changeId = '22222222-2222-4222-8222-222222222222';
const _revision = '11111111-1111-4111-8111-111111111111';
const _secretSsid = 'private-network-name';
const _secretPassword = 'private-network-password';
const _secretRead = 'private-config-read-token';
const _secretWrite = 'private-gist-write-token';

String _fleetFile({String logicalId = 'monitor-one', String? wifiSsid}) =>
    jsonEncode({
      'schema_version': 1,
      'fleet_revision': _revision,
      'devices': {
        _deviceRef: {
          'change_id': _changeId,
          'logical_id': logicalId,
          'wifi_profiles': [
            {
              'profile_id': 'primary',
              'ssid': wifiSsid ?? _secretSsid,
              'password': _secretPassword,
            },
          ],
          'config_read_credential': _secretRead,
          'temperature_gist_id': 'a' * 32,
          'diagnostics_gist_id': 'b' * 32,
          'gist_write_credential': _secretWrite,
          'sample_interval_seconds': 60,
          'publication_interval_seconds': 300,
        },
      },
    });

class _Storage implements FleetConnectionStorage {
  final values = <String, String>{
    'fleet_connection_v1_owner': 'private-owner',
    'fleet_connection_v1_repo': 'fleet-config',
    'fleet_connection_v1_branch': 'main',
    'fleet_connection_v1_path': 'fleet.json',
    'fleet_connection_v1_writer_token': 'writer-secret',
  };
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _GitHubAdapter implements HttpClientAdapter {
  _GitHubAdapter({
    this.putStatus = 201,
    this.failReadback = false,
    this.conflictLogicalId = 'monitor-latest',
    this.conflictWifiSsid,
    this.putStarted,
    this.holdPut,
  });
  int putStatus;
  final bool failReadback;
  final String conflictLogicalId;
  final String? conflictWifiSsid;
  final Completer<void>? putStarted;
  final Completer<void>? holdPut;
  bool _readbackFailed = false;
  String content = _fleetFile();
  int getCount = 0;
  int putCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'PUT') {
      putCount++;
      if (putStarted != null && !putStarted!.isCompleted) {
        putStarted!.complete();
      }
      if (holdPut != null) await holdPut!.future;
      final responseStatus = putCount == 1 ? putStatus : 201;
      if (responseStatus == 200 || responseStatus == 201) {
        final body = jsonDecode(options.data as String) as Map<String, dynamic>;
        content = utf8.decode(base64Decode(body['content'] as String));
      } else if (responseStatus == 409 || responseStatus == 422) {
        content = _fleetFile(
          logicalId: conflictLogicalId,
          wifiSsid: conflictWifiSsid,
        );
      }
      return _response(responseStatus, '{}');
    }
    getCount++;
    if (failReadback && putCount > 0 && !_readbackFailed) {
      _readbackFailed = true;
      throw DioException(
        requestOptions: options,
        message: 'private readback unavailable',
      );
    }
    return _response(
      200,
      jsonEncode({
        'type': 'file',
        'encoding': 'base64',
        'sha': 'c' * 40,
        'content': base64Encode(utf8.encode(content)),
      }),
    );
  }

  ResponseBody _response(int status, String content) => ResponseBody(
    Stream.value(Uint8List.fromList(utf8.encode(content))),
    status,
  );

  @override
  void close({bool force = false}) {}
}

ThermostatSummary _summary({
  String? deviceRef = _deviceRef,
  String? diagnosticsId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
}) {
  final now = DateTime.utc(2026, 9, 26, 12);
  return ThermostatSummary(
    thermostat: Thermostat(
      id: 'thermostat-1',
      name: 'Cooler',
      rawUrl: 'a' * 32,
      diagnosticsGistId: diagnosticsId,
      deviceRef: deviceRef,
      minC: 2,
      maxC: 8,
      hysteresisEnabled: false,
      monitoringEnabled: true,
      createdAt: now,
      updatedAt: now,
    ),
    state: ThermostatState(
      thermostatId: 'thermostat-1',
      status: ThermostatReadingStatus.ok,
      createdAt: DateTime.utc(2026, 9, 26),
      updatedAt: DateTime.utc(2026, 9, 26),
    ),
  );
}

DeviceDiagnosticsSnapshot _snapshot({
  String deviceRef = _deviceRef,
  DateTime? now,
  DateTime? updatedAt,
  int? runningSchema = 1,
  int? retainedSchema = 1,
  String? retainedGood = 'pico-1.2.2',
  DeviceDiagnosticsConfigurationStatus? status =
      const DeviceDiagnosticsConfigurationStatus(appliedId: 'old-change'),
}) {
  final instant = now ?? DateTime.utc(2026, 9, 26, 12);
  return DeviceDiagnosticsSnapshot(
    deviceRef: deviceRef,
    firmwareRunning: 'release-1',
    sensorState: 'ready',
    consecutiveFailures: 0,
    heartbeatSeq: 20,
    gistUpdatedAt: updatedAt ?? instant,
    fetchedAt: instant,
    firmwareRetainedGood: retainedGood,
    firmwareRunningConfigSchema: runningSchema,
    firmwareRetainedConfigSchema: retainedSchema,
    configurationStatus: status,
  );
}

Future<void> _pumpEditor(
  WidgetTester tester, {
  required DeviceDiagnosticsSnapshot Function(DateTime now) snapshot,
  String? linkedRef = _deviceRef,
  String? diagnosticsId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  int putStatus = 201,
  bool failReadback = false,
  String conflictLogicalId = 'monitor-latest',
  String? conflictWifiSsid,
  Completer<void>? putStarted,
  Completer<void>? holdPut,
  void Function(int calls)? onDiagnostics,
  Future<DeviceDiagnosticsSnapshot?> Function(int call, DateTime now)?
  diagnosticsRequest,
  DateTime Function()? clock,
  bool alertSettingsUnavailable = false,
}) async {
  tester.view.physicalSize = const Size(800, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final adapter = _GitHubAdapter(
    putStatus: putStatus,
    failReadback: failReadback,
    conflictLogicalId: conflictLogicalId,
    conflictWifiSsid: conflictWifiSsid,
    putStarted: putStarted,
    holdPut: holdPut,
  );
  var diagnosticCalls = 0;
  final currentTime = clock ?? () => DateTime.utc(2026, 9, 26, 12);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        fleetConnectionStorageProvider.overrideWithValue(_Storage()),
        fleetClockProvider.overrideWithValue(currentTime),
        fleetClientFactoryProvider.overrideWithValue(
          (connection) => FleetContentsClient(
            owner: connection.owner,
            repository: connection.repo,
            branch: connection.branch,
            path: connection.path,
            token: connection.writerToken,
            dio: Dio()..httpClientAdapter = adapter,
          ),
        ),
        nowProvider.overrideWithValue(currentTime),
        alertConfigProvider.overrideWith(
          (ref) => alertSettingsUnavailable
              ? Stream.error(StateError('settings unavailable'))
              : Stream.value(
                  AlertConfig(
                    pollInterval: const Duration(minutes: 5),
                    soundUri: null,
                    vibrate: true,
                    volumeBoost: false,
                    pauseAllUntil: null,
                    githubToken: null,
                    lastMonitorRunAt: null,
                  ),
                ),
        ),
        thermostatsProvider.overrideWith(
          (ref) => Stream.value([
            _summary(deviceRef: linkedRef, diagnosticsId: diagnosticsId),
          ]),
        ),
        deviceDiagnosticsProvider.overrideWith((ref, thermostatId) async {
          diagnosticCalls++;
          onDiagnostics?.call(diagnosticCalls);
          if (diagnosticsRequest != null) {
            return diagnosticsRequest(diagnosticCalls, currentTime());
          }
          return snapshot(currentTime());
        }),
      ],
      child: const MaterialApp(home: FleetConfigurationPage()),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    adapter.getCount,
    0,
    reason: 'The fleet file must not fetch on page entry.',
  );
  expect(
    diagnosticCalls,
    0,
    reason: 'Diagnostics must be fetched only after the user asks.',
  );
  await tester.ensureVisible(find.text('Fetch desired state'));
  await tester.tap(find.text('Fetch desired state'));
  await tester.pumpAndSettle();
  _AdapterRegistry.adapter = adapter;
}

class _AdapterRegistry {
  static _GitHubAdapter? adapter;
}

Future<void> _refreshCompatibility(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Refresh compatibility'));
  await tester.tap(find.text('Refresh compatibility'));
  await tester.pumpAndSettle();
}

Future<void> _pumpSubmission(WidgetTester tester) async {
  for (var attempt = 0; attempt < 250; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.textContaining('Submitted;').evaluate().isNotEmpty ||
        find
            .textContaining('repository changed or rejected')
            .evaluate()
            .isNotEmpty ||
        find.textContaining('outcome is unknown').evaluate().isNotEmpty ||
        find
            .textContaining('Could not validate or submit')
            .evaluate()
            .isNotEmpty) {
      return;
    }
  }
}

Future<void> _submitLogicalId(WidgetTester tester, String logicalId) async {
  await tester.tap(find.text('Edit desired settings'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Logical ID'),
    logicalId,
  );
  await tester.tap(find.text('Submit desired settings'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Submit'));
  await _pumpSubmission(tester);
}

bool _editEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(
          find.ancestor(
            of: find.text('Edit desired settings'),
            matching: find.byType(FilledButton),
          ),
        )
        .onPressed !=
    null;

void main() {
  testWidgets('legacy, stale, and mismatched reports keep editing locked', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      snapshot: (now) => _snapshot(runningSchema: null),
    );
    await _refreshCompatibility(tester);
    expect(_editEnabled(tester), isFalse);
    expect(
      find.text('Running or retained firmware cannot confirm fleet schema 1.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());

    await _pumpEditor(tester, snapshot: (now) => _snapshot(status: null));
    await _refreshCompatibility(tester);
    expect(_editEnabled(tester), isFalse);
    expect(
      find.text('This device does not report configuration acknowledgements.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());

    await _pumpEditor(tester, snapshot: (now) => _snapshot(retainedSchema: 2));
    await _refreshCompatibility(tester);
    expect(_editEnabled(tester), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());

    await _pumpEditor(
      tester,
      snapshot: (now) =>
          _snapshot(updatedAt: now.subtract(const Duration(days: 1))),
    );
    await _refreshCompatibility(tester);
    expect(_editEnabled(tester), isFalse);
    expect(
      find.text(
        'Device diagnostics are stale or have an invalid timestamp. Refresh and retry.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());

    await _pumpEditor(
      tester,
      snapshot: (now) => _snapshot(deviceRef: 'different-device'),
    );
    await _refreshCompatibility(tester);
    expect(_editEnabled(tester), isFalse);
    expect(
      find.text('Fresh diagnostics for this device are not available.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'valid fresh report unlocks editor, while secrets stay obscured',
    (tester) async {
      await _pumpEditor(tester, snapshot: (now) => _snapshot(now: now));
      await _refreshCompatibility(tester);
      expect(find.text('Compatibility confirmed'), findsOneWidget);
      expect(_editEnabled(tester), isTrue);
      expect(find.text(_secretSsid), findsNothing);
      await tester.tap(find.text('Edit desired settings'));
      await tester.pumpAndSettle();
      for (final field in {
        'Network name': _secretSsid,
        'Network password': _secretPassword,
        'Fleet read credential': _secretRead,
        'Gist write credential': _secretWrite,
      }.entries) {
        final formField = tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, field.key),
        );
        final editable = tester.widget<EditableText>(
          find.byWidgetPredicate(
            (widget) =>
                widget is EditableText &&
                identical(widget.controller, formField.controller),
          ),
        );
        expect(
          editable.obscureText,
          isTrue,
          reason: '${field.key} must be hidden by default.',
        );
        expect(editable.controller.text, field.value);
      }
      expect(find.text('Submit desired settings'), findsOneWidget);
    },
  );

  testWidgets('backgrounding closes the session and clears a private draft', (
    tester,
  ) async {
    await _pumpEditor(tester, snapshot: (now) => _snapshot(now: now));
    await _refreshCompatibility(tester);
    await tester.tap(find.text('Edit desired settings'));
    await tester.pumpAndSettle();
    final secretController = tester
        .widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Network password'),
        )
        .controller!;
    expect(secretController.text, _secretPassword);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Writer token'),
      'temporary-writer-token',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(secretController.text, isEmpty);
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Writer token'),
          )
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('Submit desired settings'), findsNothing);
    expect(find.textContaining('went to the background'), findsOneWidget);
    expect(_AdapterRegistry.adapter!.putCount, 0);
  });

  testWidgets('backgrounding invalidates pending secret copy consent', (
    tester,
  ) async {
    final clipboardWrites = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardWrites.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pumpEditor(tester, snapshot: (now) => _snapshot(now: now));
    await _refreshCompatibility(tester);
    await tester.tap(find.text('Edit desired settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy Network password'));
    await tester.pumpAndSettle();
    expect(find.text('Copy private value?'), findsOneWidget);
    await tester.tap(find.text('Copy value'));
    await tester.pumpAndSettle();
    expect(clipboardWrites, equals([_secretPassword]));
    clipboardWrites.clear();

    await tester.tap(find.byTooltip('Copy Network password'));
    await tester.pumpAndSettle();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.tap(find.text('Copy value'));
    await tester.pumpAndSettle();

    expect(clipboardWrites, isEmpty);
  });

  testWidgets(
    'backgrounding invalidates pending device and writer reveal consent',
    (tester) async {
      await _pumpEditor(tester, snapshot: (now) => _snapshot(now: now));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Writer token'),
        'temporary-writer-token',
      );
      await tester.tap(find.byTooltip('Reveal writer token'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.tap(find.text('Reveal for 30 seconds'));
      await tester.pumpAndSettle();
      final writerField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Writer token'),
      );
      final writerEditable = tester.widget<EditableText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is EditableText &&
              identical(widget.controller, writerField.controller),
        ),
      );
      expect(writerEditable.obscureText, isTrue);

      await tester.ensureVisible(find.text('Fetch desired state'));
      await tester.tap(find.text('Fetch desired state'));
      await tester.pumpAndSettle();
      await _refreshCompatibility(tester);
      await tester.tap(find.text('Edit desired settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Reveal private values'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.tap(find.text('Reveal for 30 seconds'));
      await tester.pumpAndSettle();
      expect(find.text('Submit desired settings'), findsNothing);
    },
  );

  testWidgets(
    'writer token reveal requires warning and masks after 30 seconds',
    (tester) async {
      await _pumpEditor(tester, snapshot: (now) => _snapshot(now: now));
      final tokenField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Writer token'),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Writer token'),
        'temporary-writer-token',
      );
      EditableText editableToken() => tester.widget<EditableText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is EditableText &&
              identical(widget.controller, tokenField.controller),
        ),
      );
      expect(editableToken().obscureText, isTrue);

      await tester.tap(find.byTooltip('Reveal writer token'));
      await tester.pumpAndSettle();
      expect(find.text('Reveal writer token?'), findsOneWidget);
      expect(editableToken().obscureText, isTrue);
      await tester.tap(find.text('Reveal for 30 seconds'));
      await tester.pumpAndSettle();
      expect(editableToken().obscureText, isFalse);

      await tester.pump(const Duration(seconds: 30));
      expect(editableToken().obscureText, isTrue);
      expect(tokenField.controller!.text, 'temporary-writer-token');
    },
  );

  testWidgets('expired session clears the draft and blocks submission', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 9, 26, 12);
    await _pumpEditor(
      tester,
      snapshot: (instant) => _snapshot(now: instant),
      clock: () => now,
    );
    await _refreshCompatibility(tester);
    await tester.tap(find.text('Edit desired settings'));
    await tester.pumpAndSettle();
    final secretController = tester
        .widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Network password'),
        )
        .controller!;
    now = now.add(const Duration(minutes: 5, seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(secretController.text, isEmpty);
    expect(find.text('Submit desired settings'), findsNothing);
    expect(find.textContaining('session expired'), findsOneWidget);
    expect(_AdapterRegistry.adapter!.putCount, 0);
  });

  testWidgets(
    'submission rechecks diagnostics before PUT and remains pending until exact fresh acknowledgement',
    (tester) async {
      var diagnosticsCalls = 0;
      String? appliedChangeId;
      var now = DateTime.utc(2026, 9, 26, 12);
      await _pumpEditor(
        tester,
        snapshot: (instant) => _snapshot(
          now: instant,
          status: DeviceDiagnosticsConfigurationStatus(
            appliedId: appliedChangeId ?? 'previous',
          ),
        ),
        onDiagnostics: (calls) => diagnosticsCalls = calls,
        clock: () => now,
      );
      await _refreshCompatibility(tester);
      await tester.tap(find.text('Edit desired settings'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Logical ID'),
        'monitor-two',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.ancestor(
                of: find.text('Submit desired settings'),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Submit desired settings'));
      await tester.pumpAndSettle();
      expect(_AdapterRegistry.adapter!.putCount, 0);
      expect(find.text('Submit desired settings'), findsOneWidget);
      expect(find.text('Submit'), findsOneWidget);
      await tester.tap(find.text('Submit'));
      await _pumpSubmission(tester);
      expect(diagnosticsCalls, greaterThanOrEqualTo(2));
      expect(_AdapterRegistry.adapter!.putCount, 1);
      expect(find.text('Submitted; waiting for device'), findsOneWidget);
      expect(find.text('Applied'), findsNothing);
      final saved =
          jsonDecode(_AdapterRegistry.adapter!.content) as Map<String, dynamic>;
      final devices = saved['devices'] as Map<String, dynamic>;
      expect(devices.keys, equals([_deviceRef]));
      appliedChangeId =
          (devices[_deviceRef] as Map<String, dynamic>)['change_id'] as String;
      now = now.add(const Duration(seconds: 1));
      await tester.tap(find.text('Check device status'));
      await tester.pumpAndSettle();
      expect(find.text('Applied'), findsOneWidget);
      expect(find.textContaining(appliedChangeId), findsOneWidget);
    },
  );

  testWidgets(
    'late acknowledgement for an older pending change cannot apply a newer one',
    (tester) async {
      var now = DateTime.utc(2026, 9, 26, 12);
      var diagnosticCalls = 0;
      String? oldChangeId;
      final delayedOldReport = Completer<DeviceDiagnosticsSnapshot?>();
      await _pumpEditor(
        tester,
        clock: () => now,
        snapshot: (instant) => _snapshot(now: instant),
        diagnosticsRequest: (call, instant) {
          diagnosticCalls = call;
          if (call == 3) return delayedOldReport.future;
          final appliedId = call == 5 ? oldChangeId : 'previous';
          return Future.value(
            _snapshot(
              now: instant,
              status: DeviceDiagnosticsConfigurationStatus(
                appliedId: appliedId,
              ),
            ),
          );
        },
      );

      await _refreshCompatibility(tester); // 1
      await _submitLogicalId(tester, 'monitor-two'); // pre-submit refresh 2
      expect(_AdapterRegistry.adapter!.putCount, 1);
      final firstFile =
          jsonDecode(_AdapterRegistry.adapter!.content) as Map<String, dynamic>;
      oldChangeId =
          ((firstFile['devices'] as Map<String, dynamic>)[_deviceRef]
                  as Map<String, dynamic>)['change_id']
              as String;

      await tester.tap(find.text('Check device status'));
      await tester.pump(); // diagnostics request 3 is intentionally held open
      expect(find.text('Checking…'), findsOneWidget);

      await tester.tap(find.text('Fetch desired state'));
      await tester.pumpAndSettle();
      await _refreshCompatibility(tester); // 4
      await _submitLogicalId(tester, 'monitor-three'); // pre-submit refresh 5
      expect(_AdapterRegistry.adapter!.putCount, 2);
      final secondFile =
          jsonDecode(_AdapterRegistry.adapter!.content) as Map<String, dynamic>;
      final newChangeId =
          ((secondFile['devices'] as Map<String, dynamic>)[_deviceRef]
                  as Map<String, dynamic>)['change_id']
              as String;
      expect(newChangeId, isNot(oldChangeId));

      now = now.add(const Duration(seconds: 1));
      delayedOldReport.complete(
        _snapshot(
          now: now,
          status: DeviceDiagnosticsConfigurationStatus(appliedId: oldChangeId),
        ),
      );
      await tester.pumpAndSettle();

      expect(diagnosticCalls, 5);
      expect(find.text('Applied'), findsNothing);
      expect(find.text('Submitted; waiting for device'), findsOneWidget);
      expect(find.textContaining(newChangeId), findsOneWidget);
    },
  );

  testWidgets(
    'late failed status check cannot overwrite cleared connection notice',
    (tester) async {
      final delayedOldStatus = Completer<DeviceDiagnosticsSnapshot?>();
      await _pumpEditor(
        tester,
        snapshot: (instant) => _snapshot(now: instant),
        diagnosticsRequest: (call, instant) => call == 3
            ? delayedOldStatus.future
            : Future.value(_snapshot(now: instant)),
      );
      await _refreshCompatibility(tester); // 1
      await _submitLogicalId(tester, 'pending-change'); // pre-submit call 2
      expect(find.text('Submitted; waiting for device'), findsOneWidget);

      await tester.tap(find.text('Check device status'));
      await tester.pump(); // call 3 held open
      expect(find.text('Checking…'), findsOneWidget);

      await tester.ensureVisible(find.text('Clear connection'));
      await tester.tap(find.text('Clear connection'));
      await tester.pumpAndSettle();
      expect(find.text('Saved connection cleared.'), findsOneWidget);

      delayedOldStatus.completeError(StateError('old request failed'));
      await tester.pumpAndSettle();
      expect(find.text('Saved connection cleared.'), findsOneWidget);
      expect(
        find.text('A fresh device status could not be read. Try again later.'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'conflict preserves a temporary draft for explicit manual reapply',
    (tester) async {
      await _pumpEditor(
        tester,
        snapshot: (now) => _snapshot(now: now),
        putStatus: 409,
        conflictLogicalId: 'latest-concurrent-id',
      );
      await _refreshCompatibility(tester);
      await _submitLogicalId(tester, 'my-reviewed-id');

      expect(_AdapterRegistry.adapter!.putCount, 1);
      expect(
        find.text('Saved draft · review before resubmitting'),
        findsOneWidget,
      );
      expect(find.text('Logical ID · latest-concurrent-id'), findsOneWidget);
      expect(find.text(_secretSsid), findsNothing);
      expect(find.text(_secretPassword), findsNothing);
      expect(find.text(_secretRead), findsNothing);
      expect(find.text(_secretWrite), findsNothing);
      expect(find.text('Submit desired settings'), findsNothing);

      await tester.tap(find.text('Fetch desired state'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Latest file fetched in a new five-minute session.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Latest file also changed'), findsOneWidget);
      await _refreshCompatibility(tester);
      expect(_AdapterRegistry.adapter!.putCount, 1);
      await tester.tap(find.text('Review saved draft'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Logical ID'),
            )
            .controller!
            .text,
        'my-reviewed-id',
      );
      expect(find.text('Logical ID · latest-concurrent-id'), findsOneWidget);
      expect(_AdapterRegistry.adapter!.putCount, 1);

      _AdapterRegistry.adapter!.putStatus = 201;
      await tester.tap(find.text('Submit desired settings'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('manually reapplies reviewed draft fields'),
        findsOneWidget,
      );
      await tester.tap(find.text('Submit'));
      await _pumpSubmission(tester);
      expect(_AdapterRegistry.adapter!.putCount, 2);
      expect(find.text('Submitted; waiting for device'), findsOneWidget);
    },
  );

  testWidgets(
    'retained conflict draft is cleared on background and original expiry',
    (tester) async {
      await _pumpEditor(
        tester,
        snapshot: (now) => _snapshot(now: now),
        putStatus: 409,
      );
      await _refreshCompatibility(tester);
      await _submitLogicalId(tester, 'my-reviewed-id');
      expect(
        find.text('Saved draft · review before resubmitting'),
        findsOneWidget,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(
        find.text('Saved draft · review before resubmitting'),
        findsNothing,
      );
      expect(find.textContaining('went to the background'), findsOneWidget);
      expect(_AdapterRegistry.adapter!.putCount, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      var now = DateTime.utc(2026, 9, 26, 12);
      await _pumpEditor(
        tester,
        snapshot: (instant) => _snapshot(now: instant),
        putStatus: 409,
        clock: () => now,
      );
      await _refreshCompatibility(tester);
      await _submitLogicalId(tester, 'my-reviewed-id');
      expect(
        find.text('Saved draft · review before resubmitting'),
        findsOneWidget,
      );
      now = now.add(const Duration(minutes: 5, seconds: 1));
      await tester.pump(const Duration(minutes: 5, seconds: 1));
      expect(
        find.text('Saved draft · review before resubmitting'),
        findsNothing,
      );
      expect(
        find.textContaining('expired with its original edit session'),
        findsOneWidget,
      );
      expect(_AdapterRegistry.adapter!.putCount, 1);
    },
  );

  testWidgets(
    'saving a replacement connection clears ordinary draft secrets and invalidates editor',
    (tester) async {
      await _pumpEditor(tester, snapshot: (now) => _snapshot(now: now));
      await _refreshCompatibility(tester);
      await tester.tap(find.text('Edit desired settings'));
      await tester.pumpAndSettle();
      final secretController = tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Network password'),
          )
          .controller!;
      expect(secretController.text, _secretPassword);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Repository owner'),
        'replacement-owner',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Repository name'),
        'replacement-repo',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Writer token'),
        'replacement-writer',
      );
      await tester.ensureVisible(find.text('Save connection'));
      await tester.tap(find.text('Save connection'));
      await tester.pumpAndSettle();
      expect(secretController.text, isEmpty);
      expect(find.text('Submit desired settings'), findsNothing);
      expect(_AdapterRegistry.adapter!.putCount, 0);
      await tester.ensureVisible(find.text('Fetch desired state'));
      await tester.tap(find.text('Fetch desired state'));
      await tester.pumpAndSettle();
      expect(find.text('Edit desired settings'), findsOneWidget);
      expect(_editEnabled(tester), isFalse);
      expect(_AdapterRegistry.adapter!.putCount, 0);
    },
  );

  testWidgets(
    'expired retained conflict draft cannot submit or extend deadline',
    (tester) async {
      var now = DateTime.utc(2026, 9, 26, 12);
      await _pumpEditor(
        tester,
        snapshot: (instant) => _snapshot(now: instant),
        putStatus: 409,
        clock: () => now,
      );
      await _refreshCompatibility(tester);
      await _submitLogicalId(tester, 'my-reviewed-id');
      await tester.tap(find.text('Fetch desired state'));
      await tester.pumpAndSettle();
      await _refreshCompatibility(tester);
      await tester.tap(find.text('Review saved draft'));
      await tester.pumpAndSettle();
      now = now.add(const Duration(minutes: 5, seconds: 1));
      await tester.tap(find.text('Submit desired settings'));
      await tester.pumpAndSettle();
      expect(_AdapterRegistry.adapter!.putCount, 1);
      expect(find.text('Submit desired settings'), findsNothing);
    },
  );

  testWidgets(
    'unknown submission outcome blocks replacement edits after a fetch',
    (tester) async {
      await _pumpEditor(
        tester,
        snapshot: (now) => _snapshot(now: now),
        failReadback: true,
      );
      await _refreshCompatibility(tester);
      await _submitLogicalId(tester, 'my-reviewed-id');
      expect(_AdapterRegistry.adapter!.putCount, 1);
      expect(find.textContaining('outcome is unknown'), findsOneWidget);
      expect(find.text('Submit desired settings'), findsNothing);

      await tester.tap(find.text('Fetch desired state'));
      await tester.pumpAndSettle();
      await _refreshCompatibility(tester);
      expect(_editEnabled(tester), isFalse);
      expect(
        find.textContaining('Replacement submissions are disabled'),
        findsOneWidget,
      );
      expect(_AdapterRegistry.adapter!.putCount, 1);
    },
  );

  testWidgets(
    'background during delayed PUT leaves outcome unresolved after refetch',
    (tester) async {
      final putStarted = Completer<void>();
      final releasePut = Completer<void>();
      await _pumpEditor(
        tester,
        snapshot: (now) => _snapshot(now: now),
        putStarted: putStarted,
        holdPut: releasePut,
      );
      await _refreshCompatibility(tester);
      await tester.tap(find.text('Edit desired settings'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Logical ID'),
        'delayed-put',
      );
      await tester.tap(find.text('Submit desired settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Submit'));
      for (
        var attempt = 0;
        attempt < 20 && !putStarted.isCompleted;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        putStarted.isCompleted,
        isTrue,
        reason: 'The real adapter PUT should have started.',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      releasePut.complete();
      await _pumpSubmission(tester);
      expect(_AdapterRegistry.adapter!.putCount, 1);
      expect(find.textContaining('outcome is unknown'), findsOneWidget);
      await tester.ensureVisible(find.text('Fetch desired state'));
      await tester.tap(find.text('Fetch desired state'));
      await tester.pumpAndSettle();
      await _refreshCompatibility(tester);
      expect(_editEnabled(tester), isFalse);
      expect(
        find.textContaining('Replacement submissions are disabled'),
        findsOneWidget,
      );
      expect(_AdapterRegistry.adapter!.putCount, 1);
    },
  );

  testWidgets(
    'conflict draft without unchanged latest Wi-Fi profile cannot be reapplied',
    (tester) async {
      await _pumpEditor(
        tester,
        snapshot: (now) => _snapshot(now: now),
        putStatus: 409,
        conflictWifiSsid: 'latest-wifi-B',
      );
      await _refreshCompatibility(tester);
      await _submitLogicalId(tester, 'my-reviewed-id');
      expect(_AdapterRegistry.adapter!.putCount, 1);
      await tester.tap(find.text('Fetch desired state'));
      await tester.pumpAndSettle();
      await _refreshCompatibility(tester);
      await tester.tap(find.text('Review saved draft'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Wi-Fi profiles'), findsWidgets);
      expect(find.text('Logical ID · monitor-latest'), findsOneWidget);
      await tester.tap(find.text('Submit desired settings'));
      await tester.pumpAndSettle();
      expect(find.text('Submit'), findsNothing);
      expect(find.textContaining('different Wi-Fi profile'), findsOneWidget);
      expect(_AdapterRegistry.adapter!.putCount, 1);
    },
  );

  testWidgets('session expiry while submit confirmation is open prevents PUT', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 9, 26, 12);
    await _pumpEditor(
      tester,
      snapshot: (instant) => _snapshot(now: instant),
      clock: () => now,
    );
    await _refreshCompatibility(tester);
    await tester.tap(find.text('Edit desired settings'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Logical ID'),
      'expires-before-confirm',
    );
    await tester.tap(find.text('Submit desired settings'));
    await tester.pumpAndSettle();
    expect(find.text('Submit'), findsOneWidget);

    now = now.add(const Duration(minutes: 5, seconds: 1));
    await tester.pump(const Duration(minutes: 5, seconds: 1));
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(_AdapterRegistry.adapter!.putCount, 0);
    expect(find.text('Applied'), findsNothing);
  });
}
