import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../models/fleet_configuration.dart';
import 'fleet_contents_client.dart';

/// Transient in-memory submission coordinator. It never persists a draft or a
/// fetched fleet document and does not claim that a device applied an edit.
class FleetConfigurationService {
  FleetConfigurationService(this._client, {String Function()? uuidV4})
    : _uuidV4 = uuidV4 ?? const Uuid().v4;

  final FleetContentsClient _client;
  final String Function() _uuidV4;

  /// Submits an edit against exactly the file blob SHA captured by the edit
  /// session. A stale base is surfaced for manual draft reapplication; there is
  /// no preflight GET and no retry of the PUT.
  Future<FleetSubmissionResult> submit({
    required FleetContentsSnapshot baseSnapshot,
    required String deviceRef,
    required FleetDeviceConfiguration editedDeviceConfig,
  }) async {
    final FleetConfiguration base;
    try {
      if (!RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(baseSnapshot.blobSha)) {
        throw const FormatException();
      }
      base = FleetConfiguration.parse(baseSnapshot.content);
    } on FormatException {
      throw const FleetSubmissionException('The saved edit base is invalid.');
    }
    final current = base.devices[deviceRef];
    if (current == null) {
      throw const FleetSubmissionException(
        'The selected device is unavailable.',
      );
    }
    if (_sameEditableValues(current, editedDeviceConfig)) {
      throw const FleetSubmissionException(
        'No configuration changes to submit.',
      );
    }

    // The device key is never supplied by the edited model. Only the selected
    // existing immutable reference is replaced, and all other change IDs stay.
    final revision = _uuidV4();
    final changeId = _uuidV4();
    final nextDevices = Map<String, FleetDeviceConfiguration>.of(base.devices);
    final changedDevice = FleetDeviceConfiguration(
      changeId: changeId,
      logicalId: editedDeviceConfig.logicalId,
      wifiProfiles: List.unmodifiable(editedDeviceConfig.wifiProfiles),
      configReadCredential: editedDeviceConfig.configReadCredential,
      temperatureGistId: editedDeviceConfig.temperatureGistId,
      diagnosticsGistId: editedDeviceConfig.diagnosticsGistId,
      gistWriteCredential: editedDeviceConfig.gistWriteCredential,
      sampleIntervalSeconds: editedDeviceConfig.sampleIntervalSeconds,
      publicationIntervalSeconds: editedDeviceConfig.publicationIntervalSeconds,
    );
    nextDevices[deviceRef] = changedDevice;
    final fleet = FleetConfiguration(
      revision: revision,
      devices: Map.unmodifiable(nextDevices),
    );
    final String content;
    try {
      content = jsonEncode(fleet.toJson());
      // Enforce the complete-file schema/size constraints before any request.
      FleetConfiguration.parse(content);
    } on FormatException {
      throw const FleetSubmissionException(
        'The edited fleet configuration is invalid.',
      );
    }

    FleetContentsPutResult? putResult;
    var putStatus = 0;
    var ambiguous = false;
    try {
      putResult = await _client.putFile(
        content: content,
        blobSha: baseSnapshot.blobSha,
      );
      putStatus = putResult.statusCode;
    } on FleetContentsException {
      // Network failure, timeout, refused redirect, or malformed response can
      // follow an accepted PUT. Do one readback, never send another PUT.
      ambiguous = true;
    }

    FleetContentsSnapshot? latest;
    try {
      latest = await _client.fetch();
    } on FleetContentsException {
      return FleetSubmissionResult(
        status: FleetSubmissionStatus.outcomeUnknown,
        revision: fleet.revision,
        changeId: changedDevice.changeId,
      );
    }

    if (putStatus == 409 || putStatus == 422) {
      return FleetSubmissionResult(
        status: FleetSubmissionStatus.needsReapply,
        revision: fleet.revision,
        changeId: changedDevice.changeId,
        latestSnapshot: latest,
      );
    }
    if (putStatus >= 300 && putStatus < 500) {
      return FleetSubmissionResult(
        status: FleetSubmissionStatus.needsReapply,
        revision: fleet.revision,
        changeId: changedDevice.changeId,
        latestSnapshot: latest,
      );
    }

    final matches = _sameBytes(latest.content, content);
    if (!matches) {
      return FleetSubmissionResult(
        status: FleetSubmissionStatus.needsReapply,
        revision: fleet.revision,
        changeId: changedDevice.changeId,
        latestSnapshot: latest,
      );
    }

    final confirmedBySuccessResponse = putStatus == 200 || putStatus == 201;
    return FleetSubmissionResult(
      status: FleetSubmissionStatus.submittedPending,
      revision: fleet.revision,
      changeId: changedDevice.changeId,
      commitSha: confirmedBySuccessResponse && !ambiguous
          ? putResult?.commitSha
          : null,
      latestSnapshot: latest,
    );
  }

  static bool _sameBytes(String left, String right) {
    final a = utf8.encode(left);
    final b = utf8.encode(right);
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  static bool _sameEditableValues(
    FleetDeviceConfiguration left,
    FleetDeviceConfiguration right,
  ) {
    final leftJson = left.toJson()..remove('change_id');
    final rightJson = right.toJson()..remove('change_id');
    return jsonEncode(leftJson) == jsonEncode(rightJson);
  }
}

enum FleetSubmissionStatus { submittedPending, needsReapply, outcomeUnknown }

class FleetSubmissionResult {
  const FleetSubmissionResult({
    required this.status,
    required this.revision,
    required this.changeId,
    this.commitSha,
    this.latestSnapshot,
  });

  final FleetSubmissionStatus status;
  final String revision;
  final String changeId;
  final String? commitSha;
  final FleetContentsSnapshot? latestSnapshot;
}

class FleetSubmissionException implements Exception {
  const FleetSubmissionException(this.message);
  final String message;
  @override
  String toString() => 'FleetSubmissionException: $message';
}
