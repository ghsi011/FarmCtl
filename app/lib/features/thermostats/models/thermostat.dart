import 'package:flutter/foundation.dart';

import '../data/thermostat_database.dart';

@immutable
class Thermostat {
  const Thermostat({
    required this.id,
    required this.name,
    required this.rawUrl,
    required this.minC,
    required this.maxC,
    required this.hysteresisEnabled,
    required this.monitoringEnabled,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String rawUrl;
  final double minC;
  final double maxC;
  final bool hysteresisEnabled;
  final bool monitoringEnabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  Thermostat copyWith({
    String? name,
    String? rawUrl,
    double? minC,
    double? maxC,
    bool? hysteresisEnabled,
    bool? monitoringEnabled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Thermostat(
      id: id,
      name: name ?? this.name,
      rawUrl: rawUrl ?? this.rawUrl,
      minC: minC ?? this.minC,
      maxC: maxC ?? this.maxC,
      hysteresisEnabled: hysteresisEnabled ?? this.hysteresisEnabled,
      monitoringEnabled: monitoringEnabled ?? this.monitoringEnabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory Thermostat.fromEntry(ThermostatEntry entry) {
    return Thermostat(
      id: entry.id,
      name: entry.name,
      rawUrl: entry.rawUrl,
      minC: entry.minC,
      maxC: entry.maxC,
      hysteresisEnabled: entry.hysteresisEnabled,
      monitoringEnabled: entry.monitoringEnabled,
      createdAt: entry.createdAt,
      updatedAt: entry.updatedAt,
    );
  }
}

class ThermostatDraft {
  ThermostatDraft({
    required this.name,
    required this.rawUrl,
    required this.minC,
    required this.maxC,
  });

  final String name;
  final String rawUrl;
  final double minC;
  final double maxC;

  ThermostatDraft copyWith({
    String? name,
    String? rawUrl,
    double? minC,
    double? maxC,
  }) {
    return ThermostatDraft(
      name: name ?? this.name,
      rawUrl: rawUrl ?? this.rawUrl,
      minC: minC ?? this.minC,
      maxC: maxC ?? this.maxC,
    );
  }
}

class ThermostatValidationResult {
  ThermostatValidationResult(this.errors);

  final List<ThermostatValidationError> errors;

  bool get isValid => errors.isEmpty;
}

class ThermostatValidationError {
  ThermostatValidationError({required this.field, required this.message});

  final ThermostatValidationField field;
  final String message;
}

enum ThermostatValidationField { name, rawUrl, minC, maxC, range }

class ThermostatValidationException implements Exception {
  ThermostatValidationException(this.result);

  final ThermostatValidationResult result;

  @override
  String toString() => 'ThermostatValidationException(${result.errors})';
}

class ThermostatValidator {
  static const double minAllowed = -80.0;
  static const double maxAllowed = 200.0;

  static ThermostatValidationResult validate(ThermostatDraft draft) {
    final errors = <ThermostatValidationError>[];

    final name = draft.name.trim();
    if (name.isEmpty || name.length > 40) {
      errors.add(
        ThermostatValidationError(
          field: ThermostatValidationField.name,
          message: 'Name must be between 1 and 40 characters.',
        ),
      );
    }

    final url = draft.rawUrl.trim();
    final parsed = Uri.tryParse(url);
    final hasValidScheme = parsed?.scheme == 'https';
    if (url.isEmpty ||
        parsed == null ||
        !parsed.isAbsolute ||
        parsed.host.isEmpty ||
        !hasValidScheme) {
      errors.add(
        ThermostatValidationError(
          field: ThermostatValidationField.rawUrl,
          message: 'Provide a valid HTTPS raw URL.',
        ),
      );
    }

    if (draft.minC < minAllowed || draft.minC > maxAllowed) {
      errors.add(
        ThermostatValidationError(
          field: ThermostatValidationField.minC,
          message: 'Minimum must be between -80°C and 200°C.',
        ),
      );
    }

    if (draft.maxC < minAllowed || draft.maxC > maxAllowed) {
      errors.add(
        ThermostatValidationError(
          field: ThermostatValidationField.maxC,
          message: 'Maximum must be between -80°C and 200°C.',
        ),
      );
    }

    if (draft.minC >= draft.maxC) {
      errors.add(
        ThermostatValidationError(
          field: ThermostatValidationField.range,
          message: 'Minimum must be less than maximum.',
        ),
      );
    }

    return ThermostatValidationResult(errors);
  }
}
