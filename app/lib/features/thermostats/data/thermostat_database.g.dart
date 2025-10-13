// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'thermostat_database.dart';

// ignore_for_file: type=lint
class $ThermostatEntriesTable extends ThermostatEntries
    with TableInfo<$ThermostatEntriesTable, ThermostatEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ThermostatEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    additionalChecks: GeneratedColumn.checkTextLength(
      minTextLength: 1,
      maxTextLength: 40,
    ),
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rawUrlMeta = const VerificationMeta('rawUrl');
  @override
  late final GeneratedColumn<String> rawUrl = GeneratedColumn<String>(
    'raw_url',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _minCMeta = const VerificationMeta('minC');
  @override
  late final GeneratedColumn<double> minC = GeneratedColumn<double>(
    'min_c',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _maxCMeta = const VerificationMeta('maxC');
  @override
  late final GeneratedColumn<double> maxC = GeneratedColumn<double>(
    'max_c',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hysteresisEnabledMeta = const VerificationMeta(
    'hysteresisEnabled',
  );
  @override
  late final GeneratedColumn<bool> hysteresisEnabled = GeneratedColumn<bool>(
    'hysteresis_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("hysteresis_enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _monitoringEnabledMeta = const VerificationMeta(
    'monitoringEnabled',
  );
  @override
  late final GeneratedColumn<bool> monitoringEnabled = GeneratedColumn<bool>(
    'monitoring_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("monitoring_enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    rawUrl,
    minC,
    maxC,
    hysteresisEnabled,
    monitoringEnabled,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'thermostat_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<ThermostatEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('raw_url')) {
      context.handle(
        _rawUrlMeta,
        rawUrl.isAcceptableOrUnknown(data['raw_url']!, _rawUrlMeta),
      );
    } else if (isInserting) {
      context.missing(_rawUrlMeta);
    }
    if (data.containsKey('min_c')) {
      context.handle(
        _minCMeta,
        minC.isAcceptableOrUnknown(data['min_c']!, _minCMeta),
      );
    } else if (isInserting) {
      context.missing(_minCMeta);
    }
    if (data.containsKey('max_c')) {
      context.handle(
        _maxCMeta,
        maxC.isAcceptableOrUnknown(data['max_c']!, _maxCMeta),
      );
    } else if (isInserting) {
      context.missing(_maxCMeta);
    }
    if (data.containsKey('hysteresis_enabled')) {
      context.handle(
        _hysteresisEnabledMeta,
        hysteresisEnabled.isAcceptableOrUnknown(
          data['hysteresis_enabled']!,
          _hysteresisEnabledMeta,
        ),
      );
    }
    if (data.containsKey('monitoring_enabled')) {
      context.handle(
        _monitoringEnabledMeta,
        monitoringEnabled.isAcceptableOrUnknown(
          data['monitoring_enabled']!,
          _monitoringEnabledMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ThermostatEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ThermostatEntry(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      rawUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}raw_url'],
      )!,
      minC: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}min_c'],
      )!,
      maxC: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}max_c'],
      )!,
      hysteresisEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}hysteresis_enabled'],
      )!,
      monitoringEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}monitoring_enabled'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ThermostatEntriesTable createAlias(String alias) {
    return $ThermostatEntriesTable(attachedDatabase, alias);
  }
}

class ThermostatEntry extends DataClass implements Insertable<ThermostatEntry> {
  final String id;
  final String name;
  final String rawUrl;
  final double minC;
  final double maxC;
  final bool hysteresisEnabled;
  final bool monitoringEnabled;
  final DateTime createdAt;
  final DateTime updatedAt;
  const ThermostatEntry({
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
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['raw_url'] = Variable<String>(rawUrl);
    map['min_c'] = Variable<double>(minC);
    map['max_c'] = Variable<double>(maxC);
    map['hysteresis_enabled'] = Variable<bool>(hysteresisEnabled);
    map['monitoring_enabled'] = Variable<bool>(monitoringEnabled);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  ThermostatEntriesCompanion toCompanion(bool nullToAbsent) {
    return ThermostatEntriesCompanion(
      id: Value(id),
      name: Value(name),
      rawUrl: Value(rawUrl),
      minC: Value(minC),
      maxC: Value(maxC),
      hysteresisEnabled: Value(hysteresisEnabled),
      monitoringEnabled: Value(monitoringEnabled),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ThermostatEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ThermostatEntry(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      rawUrl: serializer.fromJson<String>(json['rawUrl']),
      minC: serializer.fromJson<double>(json['minC']),
      maxC: serializer.fromJson<double>(json['maxC']),
      hysteresisEnabled: serializer.fromJson<bool>(json['hysteresisEnabled']),
      monitoringEnabled: serializer.fromJson<bool>(json['monitoringEnabled']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'rawUrl': serializer.toJson<String>(rawUrl),
      'minC': serializer.toJson<double>(minC),
      'maxC': serializer.toJson<double>(maxC),
      'hysteresisEnabled': serializer.toJson<bool>(hysteresisEnabled),
      'monitoringEnabled': serializer.toJson<bool>(monitoringEnabled),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  ThermostatEntry copyWith({
    String? id,
    String? name,
    String? rawUrl,
    double? minC,
    double? maxC,
    bool? hysteresisEnabled,
    bool? monitoringEnabled,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => ThermostatEntry(
    id: id ?? this.id,
    name: name ?? this.name,
    rawUrl: rawUrl ?? this.rawUrl,
    minC: minC ?? this.minC,
    maxC: maxC ?? this.maxC,
    hysteresisEnabled: hysteresisEnabled ?? this.hysteresisEnabled,
    monitoringEnabled: monitoringEnabled ?? this.monitoringEnabled,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ThermostatEntry copyWithCompanion(ThermostatEntriesCompanion data) {
    return ThermostatEntry(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      rawUrl: data.rawUrl.present ? data.rawUrl.value : this.rawUrl,
      minC: data.minC.present ? data.minC.value : this.minC,
      maxC: data.maxC.present ? data.maxC.value : this.maxC,
      hysteresisEnabled: data.hysteresisEnabled.present
          ? data.hysteresisEnabled.value
          : this.hysteresisEnabled,
      monitoringEnabled: data.monitoringEnabled.present
          ? data.monitoringEnabled.value
          : this.monitoringEnabled,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ThermostatEntry(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('rawUrl: $rawUrl, ')
          ..write('minC: $minC, ')
          ..write('maxC: $maxC, ')
          ..write('hysteresisEnabled: $hysteresisEnabled, ')
          ..write('monitoringEnabled: $monitoringEnabled, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    rawUrl,
    minC,
    maxC,
    hysteresisEnabled,
    monitoringEnabled,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ThermostatEntry &&
          other.id == this.id &&
          other.name == this.name &&
          other.rawUrl == this.rawUrl &&
          other.minC == this.minC &&
          other.maxC == this.maxC &&
          other.hysteresisEnabled == this.hysteresisEnabled &&
          other.monitoringEnabled == this.monitoringEnabled &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ThermostatEntriesCompanion extends UpdateCompanion<ThermostatEntry> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> rawUrl;
  final Value<double> minC;
  final Value<double> maxC;
  final Value<bool> hysteresisEnabled;
  final Value<bool> monitoringEnabled;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const ThermostatEntriesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.rawUrl = const Value.absent(),
    this.minC = const Value.absent(),
    this.maxC = const Value.absent(),
    this.hysteresisEnabled = const Value.absent(),
    this.monitoringEnabled = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ThermostatEntriesCompanion.insert({
    required String id,
    required String name,
    required String rawUrl,
    required double minC,
    required double maxC,
    this.hysteresisEnabled = const Value.absent(),
    this.monitoringEnabled = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       rawUrl = Value(rawUrl),
       minC = Value(minC),
       maxC = Value(maxC);
  static Insertable<ThermostatEntry> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? rawUrl,
    Expression<double>? minC,
    Expression<double>? maxC,
    Expression<bool>? hysteresisEnabled,
    Expression<bool>? monitoringEnabled,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (rawUrl != null) 'raw_url': rawUrl,
      if (minC != null) 'min_c': minC,
      if (maxC != null) 'max_c': maxC,
      if (hysteresisEnabled != null) 'hysteresis_enabled': hysteresisEnabled,
      if (monitoringEnabled != null) 'monitoring_enabled': monitoringEnabled,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ThermostatEntriesCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? rawUrl,
    Value<double>? minC,
    Value<double>? maxC,
    Value<bool>? hysteresisEnabled,
    Value<bool>? monitoringEnabled,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return ThermostatEntriesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      rawUrl: rawUrl ?? this.rawUrl,
      minC: minC ?? this.minC,
      maxC: maxC ?? this.maxC,
      hysteresisEnabled: hysteresisEnabled ?? this.hysteresisEnabled,
      monitoringEnabled: monitoringEnabled ?? this.monitoringEnabled,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (rawUrl.present) {
      map['raw_url'] = Variable<String>(rawUrl.value);
    }
    if (minC.present) {
      map['min_c'] = Variable<double>(minC.value);
    }
    if (maxC.present) {
      map['max_c'] = Variable<double>(maxC.value);
    }
    if (hysteresisEnabled.present) {
      map['hysteresis_enabled'] = Variable<bool>(hysteresisEnabled.value);
    }
    if (monitoringEnabled.present) {
      map['monitoring_enabled'] = Variable<bool>(monitoringEnabled.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ThermostatEntriesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('rawUrl: $rawUrl, ')
          ..write('minC: $minC, ')
          ..write('maxC: $maxC, ')
          ..write('hysteresisEnabled: $hysteresisEnabled, ')
          ..write('monitoringEnabled: $monitoringEnabled, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AlertConfigEntriesTable extends AlertConfigEntries
    with TableInfo<$AlertConfigEntriesTable, AlertConfigEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AlertConfigEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _pollIntervalMinMeta = const VerificationMeta(
    'pollIntervalMin',
  );
  @override
  late final GeneratedColumn<int> pollIntervalMin = GeneratedColumn<int>(
    'poll_interval_min',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(5),
  );
  static const VerificationMeta _exactAlarmsEnabledMeta =
      const VerificationMeta('exactAlarmsEnabled');
  @override
  late final GeneratedColumn<bool> exactAlarmsEnabled = GeneratedColumn<bool>(
    'exact_alarms_enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("exact_alarms_enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _soundUriMeta = const VerificationMeta(
    'soundUri',
  );
  @override
  late final GeneratedColumn<String> soundUri = GeneratedColumn<String>(
    'sound_uri',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _vibrateMeta = const VerificationMeta(
    'vibrate',
  );
  @override
  late final GeneratedColumn<bool> vibrate = GeneratedColumn<bool>(
    'vibrate',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("vibrate" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _volumeBoostMeta = const VerificationMeta(
    'volumeBoost',
  );
  @override
  late final GeneratedColumn<bool> volumeBoost = GeneratedColumn<bool>(
    'volume_boost',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("volume_boost" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _pauseAllUntilMeta = const VerificationMeta(
    'pauseAllUntil',
  );
  @override
  late final GeneratedColumn<DateTime> pauseAllUntil =
      GeneratedColumn<DateTime>(
        'pause_all_until',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    pollIntervalMin,
    exactAlarmsEnabled,
    soundUri,
    vibrate,
    volumeBoost,
    pauseAllUntil,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'alert_config_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<AlertConfigEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('poll_interval_min')) {
      context.handle(
        _pollIntervalMinMeta,
        pollIntervalMin.isAcceptableOrUnknown(
          data['poll_interval_min']!,
          _pollIntervalMinMeta,
        ),
      );
    }
    if (data.containsKey('exact_alarms_enabled')) {
      context.handle(
        _exactAlarmsEnabledMeta,
        exactAlarmsEnabled.isAcceptableOrUnknown(
          data['exact_alarms_enabled']!,
          _exactAlarmsEnabledMeta,
        ),
      );
    }
    if (data.containsKey('sound_uri')) {
      context.handle(
        _soundUriMeta,
        soundUri.isAcceptableOrUnknown(data['sound_uri']!, _soundUriMeta),
      );
    }
    if (data.containsKey('vibrate')) {
      context.handle(
        _vibrateMeta,
        vibrate.isAcceptableOrUnknown(data['vibrate']!, _vibrateMeta),
      );
    }
    if (data.containsKey('volume_boost')) {
      context.handle(
        _volumeBoostMeta,
        volumeBoost.isAcceptableOrUnknown(
          data['volume_boost']!,
          _volumeBoostMeta,
        ),
      );
    }
    if (data.containsKey('pause_all_until')) {
      context.handle(
        _pauseAllUntilMeta,
        pauseAllUntil.isAcceptableOrUnknown(
          data['pause_all_until']!,
          _pauseAllUntilMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  AlertConfigEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AlertConfigEntry(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      pollIntervalMin: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}poll_interval_min'],
      )!,
      exactAlarmsEnabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}exact_alarms_enabled'],
      )!,
      soundUri: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sound_uri'],
      ),
      vibrate: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}vibrate'],
      )!,
      volumeBoost: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}volume_boost'],
      )!,
      pauseAllUntil: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}pause_all_until'],
      ),
    );
  }

  @override
  $AlertConfigEntriesTable createAlias(String alias) {
    return $AlertConfigEntriesTable(attachedDatabase, alias);
  }
}

class AlertConfigEntry extends DataClass
    implements Insertable<AlertConfigEntry> {
  final int id;
  final int pollIntervalMin;
  final bool exactAlarmsEnabled;
  final String? soundUri;
  final bool vibrate;
  final bool volumeBoost;
  final DateTime? pauseAllUntil;
  const AlertConfigEntry({
    required this.id,
    required this.pollIntervalMin,
    required this.exactAlarmsEnabled,
    this.soundUri,
    required this.vibrate,
    required this.volumeBoost,
    this.pauseAllUntil,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['poll_interval_min'] = Variable<int>(pollIntervalMin);
    map['exact_alarms_enabled'] = Variable<bool>(exactAlarmsEnabled);
    if (!nullToAbsent || soundUri != null) {
      map['sound_uri'] = Variable<String>(soundUri);
    }
    map['vibrate'] = Variable<bool>(vibrate);
    map['volume_boost'] = Variable<bool>(volumeBoost);
    if (!nullToAbsent || pauseAllUntil != null) {
      map['pause_all_until'] = Variable<DateTime>(pauseAllUntil);
    }
    return map;
  }

  AlertConfigEntriesCompanion toCompanion(bool nullToAbsent) {
    return AlertConfigEntriesCompanion(
      id: Value(id),
      pollIntervalMin: Value(pollIntervalMin),
      exactAlarmsEnabled: Value(exactAlarmsEnabled),
      soundUri: soundUri == null && nullToAbsent
          ? const Value.absent()
          : Value(soundUri),
      vibrate: Value(vibrate),
      volumeBoost: Value(volumeBoost),
      pauseAllUntil: pauseAllUntil == null && nullToAbsent
          ? const Value.absent()
          : Value(pauseAllUntil),
    );
  }

  factory AlertConfigEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AlertConfigEntry(
      id: serializer.fromJson<int>(json['id']),
      pollIntervalMin: serializer.fromJson<int>(json['pollIntervalMin']),
      exactAlarmsEnabled: serializer.fromJson<bool>(json['exactAlarmsEnabled']),
      soundUri: serializer.fromJson<String?>(json['soundUri']),
      vibrate: serializer.fromJson<bool>(json['vibrate']),
      volumeBoost: serializer.fromJson<bool>(json['volumeBoost']),
      pauseAllUntil: serializer.fromJson<DateTime?>(json['pauseAllUntil']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'pollIntervalMin': serializer.toJson<int>(pollIntervalMin),
      'exactAlarmsEnabled': serializer.toJson<bool>(exactAlarmsEnabled),
      'soundUri': serializer.toJson<String?>(soundUri),
      'vibrate': serializer.toJson<bool>(vibrate),
      'volumeBoost': serializer.toJson<bool>(volumeBoost),
      'pauseAllUntil': serializer.toJson<DateTime?>(pauseAllUntil),
    };
  }

  AlertConfigEntry copyWith({
    int? id,
    int? pollIntervalMin,
    bool? exactAlarmsEnabled,
    Value<String?> soundUri = const Value.absent(),
    bool? vibrate,
    bool? volumeBoost,
    Value<DateTime?> pauseAllUntil = const Value.absent(),
  }) => AlertConfigEntry(
    id: id ?? this.id,
    pollIntervalMin: pollIntervalMin ?? this.pollIntervalMin,
    exactAlarmsEnabled: exactAlarmsEnabled ?? this.exactAlarmsEnabled,
    soundUri: soundUri.present ? soundUri.value : this.soundUri,
    vibrate: vibrate ?? this.vibrate,
    volumeBoost: volumeBoost ?? this.volumeBoost,
    pauseAllUntil: pauseAllUntil.present
        ? pauseAllUntil.value
        : this.pauseAllUntil,
  );
  AlertConfigEntry copyWithCompanion(AlertConfigEntriesCompanion data) {
    return AlertConfigEntry(
      id: data.id.present ? data.id.value : this.id,
      pollIntervalMin: data.pollIntervalMin.present
          ? data.pollIntervalMin.value
          : this.pollIntervalMin,
      exactAlarmsEnabled: data.exactAlarmsEnabled.present
          ? data.exactAlarmsEnabled.value
          : this.exactAlarmsEnabled,
      soundUri: data.soundUri.present ? data.soundUri.value : this.soundUri,
      vibrate: data.vibrate.present ? data.vibrate.value : this.vibrate,
      volumeBoost: data.volumeBoost.present
          ? data.volumeBoost.value
          : this.volumeBoost,
      pauseAllUntil: data.pauseAllUntil.present
          ? data.pauseAllUntil.value
          : this.pauseAllUntil,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AlertConfigEntry(')
          ..write('id: $id, ')
          ..write('pollIntervalMin: $pollIntervalMin, ')
          ..write('exactAlarmsEnabled: $exactAlarmsEnabled, ')
          ..write('soundUri: $soundUri, ')
          ..write('vibrate: $vibrate, ')
          ..write('volumeBoost: $volumeBoost, ')
          ..write('pauseAllUntil: $pauseAllUntil')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    pollIntervalMin,
    exactAlarmsEnabled,
    soundUri,
    vibrate,
    volumeBoost,
    pauseAllUntil,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AlertConfigEntry &&
          other.id == this.id &&
          other.pollIntervalMin == this.pollIntervalMin &&
          other.exactAlarmsEnabled == this.exactAlarmsEnabled &&
          other.soundUri == this.soundUri &&
          other.vibrate == this.vibrate &&
          other.volumeBoost == this.volumeBoost &&
          other.pauseAllUntil == this.pauseAllUntil);
}

class AlertConfigEntriesCompanion extends UpdateCompanion<AlertConfigEntry> {
  final Value<int> id;
  final Value<int> pollIntervalMin;
  final Value<bool> exactAlarmsEnabled;
  final Value<String?> soundUri;
  final Value<bool> vibrate;
  final Value<bool> volumeBoost;
  final Value<DateTime?> pauseAllUntil;
  const AlertConfigEntriesCompanion({
    this.id = const Value.absent(),
    this.pollIntervalMin = const Value.absent(),
    this.exactAlarmsEnabled = const Value.absent(),
    this.soundUri = const Value.absent(),
    this.vibrate = const Value.absent(),
    this.volumeBoost = const Value.absent(),
    this.pauseAllUntil = const Value.absent(),
  });
  AlertConfigEntriesCompanion.insert({
    this.id = const Value.absent(),
    this.pollIntervalMin = const Value.absent(),
    this.exactAlarmsEnabled = const Value.absent(),
    this.soundUri = const Value.absent(),
    this.vibrate = const Value.absent(),
    this.volumeBoost = const Value.absent(),
    this.pauseAllUntil = const Value.absent(),
  });
  static Insertable<AlertConfigEntry> custom({
    Expression<int>? id,
    Expression<int>? pollIntervalMin,
    Expression<bool>? exactAlarmsEnabled,
    Expression<String>? soundUri,
    Expression<bool>? vibrate,
    Expression<bool>? volumeBoost,
    Expression<DateTime>? pauseAllUntil,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (pollIntervalMin != null) 'poll_interval_min': pollIntervalMin,
      if (exactAlarmsEnabled != null)
        'exact_alarms_enabled': exactAlarmsEnabled,
      if (soundUri != null) 'sound_uri': soundUri,
      if (vibrate != null) 'vibrate': vibrate,
      if (volumeBoost != null) 'volume_boost': volumeBoost,
      if (pauseAllUntil != null) 'pause_all_until': pauseAllUntil,
    });
  }

  AlertConfigEntriesCompanion copyWith({
    Value<int>? id,
    Value<int>? pollIntervalMin,
    Value<bool>? exactAlarmsEnabled,
    Value<String?>? soundUri,
    Value<bool>? vibrate,
    Value<bool>? volumeBoost,
    Value<DateTime?>? pauseAllUntil,
  }) {
    return AlertConfigEntriesCompanion(
      id: id ?? this.id,
      pollIntervalMin: pollIntervalMin ?? this.pollIntervalMin,
      exactAlarmsEnabled: exactAlarmsEnabled ?? this.exactAlarmsEnabled,
      soundUri: soundUri ?? this.soundUri,
      vibrate: vibrate ?? this.vibrate,
      volumeBoost: volumeBoost ?? this.volumeBoost,
      pauseAllUntil: pauseAllUntil ?? this.pauseAllUntil,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (pollIntervalMin.present) {
      map['poll_interval_min'] = Variable<int>(pollIntervalMin.value);
    }
    if (exactAlarmsEnabled.present) {
      map['exact_alarms_enabled'] = Variable<bool>(exactAlarmsEnabled.value);
    }
    if (soundUri.present) {
      map['sound_uri'] = Variable<String>(soundUri.value);
    }
    if (vibrate.present) {
      map['vibrate'] = Variable<bool>(vibrate.value);
    }
    if (volumeBoost.present) {
      map['volume_boost'] = Variable<bool>(volumeBoost.value);
    }
    if (pauseAllUntil.present) {
      map['pause_all_until'] = Variable<DateTime>(pauseAllUntil.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AlertConfigEntriesCompanion(')
          ..write('id: $id, ')
          ..write('pollIntervalMin: $pollIntervalMin, ')
          ..write('exactAlarmsEnabled: $exactAlarmsEnabled, ')
          ..write('soundUri: $soundUri, ')
          ..write('vibrate: $vibrate, ')
          ..write('volumeBoost: $volumeBoost, ')
          ..write('pauseAllUntil: $pauseAllUntil')
          ..write(')'))
        .toString();
  }
}

class $ThermostatStateEntriesTable extends ThermostatStateEntries
    with TableInfo<$ThermostatStateEntriesTable, ThermostatStateEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ThermostatStateEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _thermostatIdMeta = const VerificationMeta(
    'thermostatId',
  );
  @override
  late final GeneratedColumn<String> thermostatId = GeneratedColumn<String>(
    'thermostat_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastValueCMeta = const VerificationMeta(
    'lastValueC',
  );
  @override
  late final GeneratedColumn<double> lastValueC = GeneratedColumn<double>(
    'last_value_c',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastStatusMeta = const VerificationMeta(
    'lastStatus',
  );
  @override
  late final GeneratedColumn<String> lastStatus = GeneratedColumn<String>(
    'last_status',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastFetchedAtMeta = const VerificationMeta(
    'lastFetchedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastFetchedAt =
      GeneratedColumn<DateTime>(
        'last_fetched_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _etagMeta = const VerificationMeta('etag');
  @override
  late final GeneratedColumn<String> etag = GeneratedColumn<String>(
    'etag',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMessageMeta = const VerificationMeta(
    'statusMessage',
  );
  @override
  late final GeneratedColumn<String> statusMessage = GeneratedColumn<String>(
    'status_message',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastAlarmAtMeta = const VerificationMeta(
    'lastAlarmAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastAlarmAt = GeneratedColumn<DateTime>(
    'last_alarm_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _snoozedUntilMeta = const VerificationMeta(
    'snoozedUntil',
  );
  @override
  late final GeneratedColumn<DateTime> snoozedUntil = GeneratedColumn<DateTime>(
    'snoozed_until',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _silenceUntilOkMeta = const VerificationMeta(
    'silenceUntilOk',
  );
  @override
  late final GeneratedColumn<bool> silenceUntilOk = GeneratedColumn<bool>(
    'silence_until_ok',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("silence_until_ok" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [
    thermostatId,
    lastValueC,
    lastStatus,
    lastFetchedAt,
    etag,
    statusMessage,
    lastAlarmAt,
    snoozedUntil,
    silenceUntilOk,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'thermostat_state_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<ThermostatStateEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('thermostat_id')) {
      context.handle(
        _thermostatIdMeta,
        thermostatId.isAcceptableOrUnknown(
          data['thermostat_id']!,
          _thermostatIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_thermostatIdMeta);
    }
    if (data.containsKey('last_value_c')) {
      context.handle(
        _lastValueCMeta,
        lastValueC.isAcceptableOrUnknown(
          data['last_value_c']!,
          _lastValueCMeta,
        ),
      );
    }
    if (data.containsKey('last_status')) {
      context.handle(
        _lastStatusMeta,
        lastStatus.isAcceptableOrUnknown(data['last_status']!, _lastStatusMeta),
      );
    }
    if (data.containsKey('last_fetched_at')) {
      context.handle(
        _lastFetchedAtMeta,
        lastFetchedAt.isAcceptableOrUnknown(
          data['last_fetched_at']!,
          _lastFetchedAtMeta,
        ),
      );
    }
    if (data.containsKey('etag')) {
      context.handle(
        _etagMeta,
        etag.isAcceptableOrUnknown(data['etag']!, _etagMeta),
      );
    }
    if (data.containsKey('status_message')) {
      context.handle(
        _statusMessageMeta,
        statusMessage.isAcceptableOrUnknown(
          data['status_message']!,
          _statusMessageMeta,
        ),
      );
    }
    if (data.containsKey('last_alarm_at')) {
      context.handle(
        _lastAlarmAtMeta,
        lastAlarmAt.isAcceptableOrUnknown(
          data['last_alarm_at']!,
          _lastAlarmAtMeta,
        ),
      );
    }
    if (data.containsKey('snoozed_until')) {
      context.handle(
        _snoozedUntilMeta,
        snoozedUntil.isAcceptableOrUnknown(
          data['snoozed_until']!,
          _snoozedUntilMeta,
        ),
      );
    }
    if (data.containsKey('silence_until_ok')) {
      context.handle(
        _silenceUntilOkMeta,
        silenceUntilOk.isAcceptableOrUnknown(
          data['silence_until_ok']!,
          _silenceUntilOkMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {thermostatId};
  @override
  ThermostatStateEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ThermostatStateEntry(
      thermostatId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thermostat_id'],
      )!,
      lastValueC: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}last_value_c'],
      ),
      lastStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_status'],
      ),
      lastFetchedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_fetched_at'],
      ),
      etag: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}etag'],
      ),
      statusMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status_message'],
      ),
      lastAlarmAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_alarm_at'],
      ),
      snoozedUntil: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}snoozed_until'],
      ),
      silenceUntilOk: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}silence_until_ok'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $ThermostatStateEntriesTable createAlias(String alias) {
    return $ThermostatStateEntriesTable(attachedDatabase, alias);
  }
}

class ThermostatStateEntry extends DataClass
    implements Insertable<ThermostatStateEntry> {
  final String thermostatId;
  final double? lastValueC;
  final String? lastStatus;
  final DateTime? lastFetchedAt;
  final String? etag;
  final String? statusMessage;
  final DateTime? lastAlarmAt;
  final DateTime? snoozedUntil;
  final bool silenceUntilOk;
  final DateTime createdAt;
  final DateTime updatedAt;
  const ThermostatStateEntry({
    required this.thermostatId,
    this.lastValueC,
    this.lastStatus,
    this.lastFetchedAt,
    this.etag,
    this.statusMessage,
    this.lastAlarmAt,
    this.snoozedUntil,
    required this.silenceUntilOk,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['thermostat_id'] = Variable<String>(thermostatId);
    if (!nullToAbsent || lastValueC != null) {
      map['last_value_c'] = Variable<double>(lastValueC);
    }
    if (!nullToAbsent || lastStatus != null) {
      map['last_status'] = Variable<String>(lastStatus);
    }
    if (!nullToAbsent || lastFetchedAt != null) {
      map['last_fetched_at'] = Variable<DateTime>(lastFetchedAt);
    }
    if (!nullToAbsent || etag != null) {
      map['etag'] = Variable<String>(etag);
    }
    if (!nullToAbsent || statusMessage != null) {
      map['status_message'] = Variable<String>(statusMessage);
    }
    if (!nullToAbsent || lastAlarmAt != null) {
      map['last_alarm_at'] = Variable<DateTime>(lastAlarmAt);
    }
    if (!nullToAbsent || snoozedUntil != null) {
      map['snoozed_until'] = Variable<DateTime>(snoozedUntil);
    }
    map['silence_until_ok'] = Variable<bool>(silenceUntilOk);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  ThermostatStateEntriesCompanion toCompanion(bool nullToAbsent) {
    return ThermostatStateEntriesCompanion(
      thermostatId: Value(thermostatId),
      lastValueC: lastValueC == null && nullToAbsent
          ? const Value.absent()
          : Value(lastValueC),
      lastStatus: lastStatus == null && nullToAbsent
          ? const Value.absent()
          : Value(lastStatus),
      lastFetchedAt: lastFetchedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastFetchedAt),
      etag: etag == null && nullToAbsent ? const Value.absent() : Value(etag),
      statusMessage: statusMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(statusMessage),
      lastAlarmAt: lastAlarmAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastAlarmAt),
      snoozedUntil: snoozedUntil == null && nullToAbsent
          ? const Value.absent()
          : Value(snoozedUntil),
      silenceUntilOk: Value(silenceUntilOk),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory ThermostatStateEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ThermostatStateEntry(
      thermostatId: serializer.fromJson<String>(json['thermostatId']),
      lastValueC: serializer.fromJson<double?>(json['lastValueC']),
      lastStatus: serializer.fromJson<String?>(json['lastStatus']),
      lastFetchedAt: serializer.fromJson<DateTime?>(json['lastFetchedAt']),
      etag: serializer.fromJson<String?>(json['etag']),
      statusMessage: serializer.fromJson<String?>(json['statusMessage']),
      lastAlarmAt: serializer.fromJson<DateTime?>(json['lastAlarmAt']),
      snoozedUntil: serializer.fromJson<DateTime?>(json['snoozedUntil']),
      silenceUntilOk: serializer.fromJson<bool>(json['silenceUntilOk']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'thermostatId': serializer.toJson<String>(thermostatId),
      'lastValueC': serializer.toJson<double?>(lastValueC),
      'lastStatus': serializer.toJson<String?>(lastStatus),
      'lastFetchedAt': serializer.toJson<DateTime?>(lastFetchedAt),
      'etag': serializer.toJson<String?>(etag),
      'statusMessage': serializer.toJson<String?>(statusMessage),
      'lastAlarmAt': serializer.toJson<DateTime?>(lastAlarmAt),
      'snoozedUntil': serializer.toJson<DateTime?>(snoozedUntil),
      'silenceUntilOk': serializer.toJson<bool>(silenceUntilOk),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  ThermostatStateEntry copyWith({
    String? thermostatId,
    Value<double?> lastValueC = const Value.absent(),
    Value<String?> lastStatus = const Value.absent(),
    Value<DateTime?> lastFetchedAt = const Value.absent(),
    Value<String?> etag = const Value.absent(),
    Value<String?> statusMessage = const Value.absent(),
    Value<DateTime?> lastAlarmAt = const Value.absent(),
    Value<DateTime?> snoozedUntil = const Value.absent(),
    bool? silenceUntilOk,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => ThermostatStateEntry(
    thermostatId: thermostatId ?? this.thermostatId,
    lastValueC: lastValueC.present ? lastValueC.value : this.lastValueC,
    lastStatus: lastStatus.present ? lastStatus.value : this.lastStatus,
    lastFetchedAt: lastFetchedAt.present
        ? lastFetchedAt.value
        : this.lastFetchedAt,
    etag: etag.present ? etag.value : this.etag,
    statusMessage: statusMessage.present
        ? statusMessage.value
        : this.statusMessage,
    lastAlarmAt: lastAlarmAt.present ? lastAlarmAt.value : this.lastAlarmAt,
    snoozedUntil: snoozedUntil.present ? snoozedUntil.value : this.snoozedUntil,
    silenceUntilOk: silenceUntilOk ?? this.silenceUntilOk,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  ThermostatStateEntry copyWithCompanion(ThermostatStateEntriesCompanion data) {
    return ThermostatStateEntry(
      thermostatId: data.thermostatId.present
          ? data.thermostatId.value
          : this.thermostatId,
      lastValueC: data.lastValueC.present
          ? data.lastValueC.value
          : this.lastValueC,
      lastStatus: data.lastStatus.present
          ? data.lastStatus.value
          : this.lastStatus,
      lastFetchedAt: data.lastFetchedAt.present
          ? data.lastFetchedAt.value
          : this.lastFetchedAt,
      etag: data.etag.present ? data.etag.value : this.etag,
      statusMessage: data.statusMessage.present
          ? data.statusMessage.value
          : this.statusMessage,
      lastAlarmAt: data.lastAlarmAt.present
          ? data.lastAlarmAt.value
          : this.lastAlarmAt,
      snoozedUntil: data.snoozedUntil.present
          ? data.snoozedUntil.value
          : this.snoozedUntil,
      silenceUntilOk: data.silenceUntilOk.present
          ? data.silenceUntilOk.value
          : this.silenceUntilOk,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ThermostatStateEntry(')
          ..write('thermostatId: $thermostatId, ')
          ..write('lastValueC: $lastValueC, ')
          ..write('lastStatus: $lastStatus, ')
          ..write('lastFetchedAt: $lastFetchedAt, ')
          ..write('etag: $etag, ')
          ..write('statusMessage: $statusMessage, ')
          ..write('lastAlarmAt: $lastAlarmAt, ')
          ..write('snoozedUntil: $snoozedUntil, ')
          ..write('silenceUntilOk: $silenceUntilOk, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    thermostatId,
    lastValueC,
    lastStatus,
    lastFetchedAt,
    etag,
    statusMessage,
    lastAlarmAt,
    snoozedUntil,
    silenceUntilOk,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ThermostatStateEntry &&
          other.thermostatId == this.thermostatId &&
          other.lastValueC == this.lastValueC &&
          other.lastStatus == this.lastStatus &&
          other.lastFetchedAt == this.lastFetchedAt &&
          other.etag == this.etag &&
          other.statusMessage == this.statusMessage &&
          other.lastAlarmAt == this.lastAlarmAt &&
          other.snoozedUntil == this.snoozedUntil &&
          other.silenceUntilOk == this.silenceUntilOk &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class ThermostatStateEntriesCompanion
    extends UpdateCompanion<ThermostatStateEntry> {
  final Value<String> thermostatId;
  final Value<double?> lastValueC;
  final Value<String?> lastStatus;
  final Value<DateTime?> lastFetchedAt;
  final Value<String?> etag;
  final Value<String?> statusMessage;
  final Value<DateTime?> lastAlarmAt;
  final Value<DateTime?> snoozedUntil;
  final Value<bool> silenceUntilOk;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const ThermostatStateEntriesCompanion({
    this.thermostatId = const Value.absent(),
    this.lastValueC = const Value.absent(),
    this.lastStatus = const Value.absent(),
    this.lastFetchedAt = const Value.absent(),
    this.etag = const Value.absent(),
    this.statusMessage = const Value.absent(),
    this.lastAlarmAt = const Value.absent(),
    this.snoozedUntil = const Value.absent(),
    this.silenceUntilOk = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ThermostatStateEntriesCompanion.insert({
    required String thermostatId,
    this.lastValueC = const Value.absent(),
    this.lastStatus = const Value.absent(),
    this.lastFetchedAt = const Value.absent(),
    this.etag = const Value.absent(),
    this.statusMessage = const Value.absent(),
    this.lastAlarmAt = const Value.absent(),
    this.snoozedUntil = const Value.absent(),
    this.silenceUntilOk = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : thermostatId = Value(thermostatId);
  static Insertable<ThermostatStateEntry> custom({
    Expression<String>? thermostatId,
    Expression<double>? lastValueC,
    Expression<String>? lastStatus,
    Expression<DateTime>? lastFetchedAt,
    Expression<String>? etag,
    Expression<String>? statusMessage,
    Expression<DateTime>? lastAlarmAt,
    Expression<DateTime>? snoozedUntil,
    Expression<bool>? silenceUntilOk,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (thermostatId != null) 'thermostat_id': thermostatId,
      if (lastValueC != null) 'last_value_c': lastValueC,
      if (lastStatus != null) 'last_status': lastStatus,
      if (lastFetchedAt != null) 'last_fetched_at': lastFetchedAt,
      if (etag != null) 'etag': etag,
      if (statusMessage != null) 'status_message': statusMessage,
      if (lastAlarmAt != null) 'last_alarm_at': lastAlarmAt,
      if (snoozedUntil != null) 'snoozed_until': snoozedUntil,
      if (silenceUntilOk != null) 'silence_until_ok': silenceUntilOk,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ThermostatStateEntriesCompanion copyWith({
    Value<String>? thermostatId,
    Value<double?>? lastValueC,
    Value<String?>? lastStatus,
    Value<DateTime?>? lastFetchedAt,
    Value<String?>? etag,
    Value<String?>? statusMessage,
    Value<DateTime?>? lastAlarmAt,
    Value<DateTime?>? snoozedUntil,
    Value<bool>? silenceUntilOk,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return ThermostatStateEntriesCompanion(
      thermostatId: thermostatId ?? this.thermostatId,
      lastValueC: lastValueC ?? this.lastValueC,
      lastStatus: lastStatus ?? this.lastStatus,
      lastFetchedAt: lastFetchedAt ?? this.lastFetchedAt,
      etag: etag ?? this.etag,
      statusMessage: statusMessage ?? this.statusMessage,
      lastAlarmAt: lastAlarmAt ?? this.lastAlarmAt,
      snoozedUntil: snoozedUntil ?? this.snoozedUntil,
      silenceUntilOk: silenceUntilOk ?? this.silenceUntilOk,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (thermostatId.present) {
      map['thermostat_id'] = Variable<String>(thermostatId.value);
    }
    if (lastValueC.present) {
      map['last_value_c'] = Variable<double>(lastValueC.value);
    }
    if (lastStatus.present) {
      map['last_status'] = Variable<String>(lastStatus.value);
    }
    if (lastFetchedAt.present) {
      map['last_fetched_at'] = Variable<DateTime>(lastFetchedAt.value);
    }
    if (etag.present) {
      map['etag'] = Variable<String>(etag.value);
    }
    if (statusMessage.present) {
      map['status_message'] = Variable<String>(statusMessage.value);
    }
    if (lastAlarmAt.present) {
      map['last_alarm_at'] = Variable<DateTime>(lastAlarmAt.value);
    }
    if (snoozedUntil.present) {
      map['snoozed_until'] = Variable<DateTime>(snoozedUntil.value);
    }
    if (silenceUntilOk.present) {
      map['silence_until_ok'] = Variable<bool>(silenceUntilOk.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ThermostatStateEntriesCompanion(')
          ..write('thermostatId: $thermostatId, ')
          ..write('lastValueC: $lastValueC, ')
          ..write('lastStatus: $lastStatus, ')
          ..write('lastFetchedAt: $lastFetchedAt, ')
          ..write('etag: $etag, ')
          ..write('statusMessage: $statusMessage, ')
          ..write('lastAlarmAt: $lastAlarmAt, ')
          ..write('snoozedUntil: $snoozedUntil, ')
          ..write('silenceUntilOk: $silenceUntilOk, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$ThermostatDatabase extends GeneratedDatabase {
  _$ThermostatDatabase(QueryExecutor e) : super(e);
  $ThermostatDatabaseManager get managers => $ThermostatDatabaseManager(this);
  late final $ThermostatEntriesTable thermostatEntries =
      $ThermostatEntriesTable(this);
  late final $AlertConfigEntriesTable alertConfigEntries =
      $AlertConfigEntriesTable(this);
  late final $ThermostatStateEntriesTable thermostatStateEntries =
      $ThermostatStateEntriesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    thermostatEntries,
    alertConfigEntries,
    thermostatStateEntries,
  ];
}

typedef $$ThermostatEntriesTableCreateCompanionBuilder =
    ThermostatEntriesCompanion Function({
      required String id,
      required String name,
      required String rawUrl,
      required double minC,
      required double maxC,
      Value<bool> hysteresisEnabled,
      Value<bool> monitoringEnabled,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });
typedef $$ThermostatEntriesTableUpdateCompanionBuilder =
    ThermostatEntriesCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> rawUrl,
      Value<double> minC,
      Value<double> maxC,
      Value<bool> hysteresisEnabled,
      Value<bool> monitoringEnabled,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$ThermostatEntriesTableFilterComposer
    extends Composer<_$ThermostatDatabase, $ThermostatEntriesTable> {
  $$ThermostatEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rawUrl => $composableBuilder(
    column: $table.rawUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get minC => $composableBuilder(
    column: $table.minC,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get maxC => $composableBuilder(
    column: $table.maxC,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hysteresisEnabled => $composableBuilder(
    column: $table.hysteresisEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get monitoringEnabled => $composableBuilder(
    column: $table.monitoringEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ThermostatEntriesTableOrderingComposer
    extends Composer<_$ThermostatDatabase, $ThermostatEntriesTable> {
  $$ThermostatEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rawUrl => $composableBuilder(
    column: $table.rawUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get minC => $composableBuilder(
    column: $table.minC,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get maxC => $composableBuilder(
    column: $table.maxC,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hysteresisEnabled => $composableBuilder(
    column: $table.hysteresisEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get monitoringEnabled => $composableBuilder(
    column: $table.monitoringEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ThermostatEntriesTableAnnotationComposer
    extends Composer<_$ThermostatDatabase, $ThermostatEntriesTable> {
  $$ThermostatEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get rawUrl =>
      $composableBuilder(column: $table.rawUrl, builder: (column) => column);

  GeneratedColumn<double> get minC =>
      $composableBuilder(column: $table.minC, builder: (column) => column);

  GeneratedColumn<double> get maxC =>
      $composableBuilder(column: $table.maxC, builder: (column) => column);

  GeneratedColumn<bool> get hysteresisEnabled => $composableBuilder(
    column: $table.hysteresisEnabled,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get monitoringEnabled => $composableBuilder(
    column: $table.monitoringEnabled,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ThermostatEntriesTableTableManager
    extends
        RootTableManager<
          _$ThermostatDatabase,
          $ThermostatEntriesTable,
          ThermostatEntry,
          $$ThermostatEntriesTableFilterComposer,
          $$ThermostatEntriesTableOrderingComposer,
          $$ThermostatEntriesTableAnnotationComposer,
          $$ThermostatEntriesTableCreateCompanionBuilder,
          $$ThermostatEntriesTableUpdateCompanionBuilder,
          (
            ThermostatEntry,
            BaseReferences<
              _$ThermostatDatabase,
              $ThermostatEntriesTable,
              ThermostatEntry
            >,
          ),
          ThermostatEntry,
          PrefetchHooks Function()
        > {
  $$ThermostatEntriesTableTableManager(
    _$ThermostatDatabase db,
    $ThermostatEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ThermostatEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ThermostatEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ThermostatEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> rawUrl = const Value.absent(),
                Value<double> minC = const Value.absent(),
                Value<double> maxC = const Value.absent(),
                Value<bool> hysteresisEnabled = const Value.absent(),
                Value<bool> monitoringEnabled = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ThermostatEntriesCompanion(
                id: id,
                name: name,
                rawUrl: rawUrl,
                minC: minC,
                maxC: maxC,
                hysteresisEnabled: hysteresisEnabled,
                monitoringEnabled: monitoringEnabled,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String rawUrl,
                required double minC,
                required double maxC,
                Value<bool> hysteresisEnabled = const Value.absent(),
                Value<bool> monitoringEnabled = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ThermostatEntriesCompanion.insert(
                id: id,
                name: name,
                rawUrl: rawUrl,
                minC: minC,
                maxC: maxC,
                hysteresisEnabled: hysteresisEnabled,
                monitoringEnabled: monitoringEnabled,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ThermostatEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$ThermostatDatabase,
      $ThermostatEntriesTable,
      ThermostatEntry,
      $$ThermostatEntriesTableFilterComposer,
      $$ThermostatEntriesTableOrderingComposer,
      $$ThermostatEntriesTableAnnotationComposer,
      $$ThermostatEntriesTableCreateCompanionBuilder,
      $$ThermostatEntriesTableUpdateCompanionBuilder,
      (
        ThermostatEntry,
        BaseReferences<
          _$ThermostatDatabase,
          $ThermostatEntriesTable,
          ThermostatEntry
        >,
      ),
      ThermostatEntry,
      PrefetchHooks Function()
    >;
typedef $$AlertConfigEntriesTableCreateCompanionBuilder =
    AlertConfigEntriesCompanion Function({
      Value<int> id,
      Value<int> pollIntervalMin,
      Value<bool> exactAlarmsEnabled,
      Value<String?> soundUri,
      Value<bool> vibrate,
      Value<bool> volumeBoost,
      Value<DateTime?> pauseAllUntil,
    });
typedef $$AlertConfigEntriesTableUpdateCompanionBuilder =
    AlertConfigEntriesCompanion Function({
      Value<int> id,
      Value<int> pollIntervalMin,
      Value<bool> exactAlarmsEnabled,
      Value<String?> soundUri,
      Value<bool> vibrate,
      Value<bool> volumeBoost,
      Value<DateTime?> pauseAllUntil,
    });

class $$AlertConfigEntriesTableFilterComposer
    extends Composer<_$ThermostatDatabase, $AlertConfigEntriesTable> {
  $$AlertConfigEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pollIntervalMin => $composableBuilder(
    column: $table.pollIntervalMin,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get exactAlarmsEnabled => $composableBuilder(
    column: $table.exactAlarmsEnabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get soundUri => $composableBuilder(
    column: $table.soundUri,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get vibrate => $composableBuilder(
    column: $table.vibrate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get volumeBoost => $composableBuilder(
    column: $table.volumeBoost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get pauseAllUntil => $composableBuilder(
    column: $table.pauseAllUntil,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AlertConfigEntriesTableOrderingComposer
    extends Composer<_$ThermostatDatabase, $AlertConfigEntriesTable> {
  $$AlertConfigEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pollIntervalMin => $composableBuilder(
    column: $table.pollIntervalMin,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get exactAlarmsEnabled => $composableBuilder(
    column: $table.exactAlarmsEnabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get soundUri => $composableBuilder(
    column: $table.soundUri,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get vibrate => $composableBuilder(
    column: $table.vibrate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get volumeBoost => $composableBuilder(
    column: $table.volumeBoost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get pauseAllUntil => $composableBuilder(
    column: $table.pauseAllUntil,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AlertConfigEntriesTableAnnotationComposer
    extends Composer<_$ThermostatDatabase, $AlertConfigEntriesTable> {
  $$AlertConfigEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get pollIntervalMin => $composableBuilder(
    column: $table.pollIntervalMin,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get exactAlarmsEnabled => $composableBuilder(
    column: $table.exactAlarmsEnabled,
    builder: (column) => column,
  );

  GeneratedColumn<String> get soundUri =>
      $composableBuilder(column: $table.soundUri, builder: (column) => column);

  GeneratedColumn<bool> get vibrate =>
      $composableBuilder(column: $table.vibrate, builder: (column) => column);

  GeneratedColumn<bool> get volumeBoost => $composableBuilder(
    column: $table.volumeBoost,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get pauseAllUntil => $composableBuilder(
    column: $table.pauseAllUntil,
    builder: (column) => column,
  );
}

class $$AlertConfigEntriesTableTableManager
    extends
        RootTableManager<
          _$ThermostatDatabase,
          $AlertConfigEntriesTable,
          AlertConfigEntry,
          $$AlertConfigEntriesTableFilterComposer,
          $$AlertConfigEntriesTableOrderingComposer,
          $$AlertConfigEntriesTableAnnotationComposer,
          $$AlertConfigEntriesTableCreateCompanionBuilder,
          $$AlertConfigEntriesTableUpdateCompanionBuilder,
          (
            AlertConfigEntry,
            BaseReferences<
              _$ThermostatDatabase,
              $AlertConfigEntriesTable,
              AlertConfigEntry
            >,
          ),
          AlertConfigEntry,
          PrefetchHooks Function()
        > {
  $$AlertConfigEntriesTableTableManager(
    _$ThermostatDatabase db,
    $AlertConfigEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AlertConfigEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AlertConfigEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AlertConfigEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> pollIntervalMin = const Value.absent(),
                Value<bool> exactAlarmsEnabled = const Value.absent(),
                Value<String?> soundUri = const Value.absent(),
                Value<bool> vibrate = const Value.absent(),
                Value<bool> volumeBoost = const Value.absent(),
                Value<DateTime?> pauseAllUntil = const Value.absent(),
              }) => AlertConfigEntriesCompanion(
                id: id,
                pollIntervalMin: pollIntervalMin,
                exactAlarmsEnabled: exactAlarmsEnabled,
                soundUri: soundUri,
                vibrate: vibrate,
                volumeBoost: volumeBoost,
                pauseAllUntil: pauseAllUntil,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> pollIntervalMin = const Value.absent(),
                Value<bool> exactAlarmsEnabled = const Value.absent(),
                Value<String?> soundUri = const Value.absent(),
                Value<bool> vibrate = const Value.absent(),
                Value<bool> volumeBoost = const Value.absent(),
                Value<DateTime?> pauseAllUntil = const Value.absent(),
              }) => AlertConfigEntriesCompanion.insert(
                id: id,
                pollIntervalMin: pollIntervalMin,
                exactAlarmsEnabled: exactAlarmsEnabled,
                soundUri: soundUri,
                vibrate: vibrate,
                volumeBoost: volumeBoost,
                pauseAllUntil: pauseAllUntil,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AlertConfigEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$ThermostatDatabase,
      $AlertConfigEntriesTable,
      AlertConfigEntry,
      $$AlertConfigEntriesTableFilterComposer,
      $$AlertConfigEntriesTableOrderingComposer,
      $$AlertConfigEntriesTableAnnotationComposer,
      $$AlertConfigEntriesTableCreateCompanionBuilder,
      $$AlertConfigEntriesTableUpdateCompanionBuilder,
      (
        AlertConfigEntry,
        BaseReferences<
          _$ThermostatDatabase,
          $AlertConfigEntriesTable,
          AlertConfigEntry
        >,
      ),
      AlertConfigEntry,
      PrefetchHooks Function()
    >;
typedef $$ThermostatStateEntriesTableCreateCompanionBuilder =
    ThermostatStateEntriesCompanion Function({
      required String thermostatId,
      Value<double?> lastValueC,
      Value<String?> lastStatus,
      Value<DateTime?> lastFetchedAt,
      Value<String?> etag,
      Value<String?> statusMessage,
      Value<DateTime?> lastAlarmAt,
      Value<DateTime?> snoozedUntil,
      Value<bool> silenceUntilOk,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });
typedef $$ThermostatStateEntriesTableUpdateCompanionBuilder =
    ThermostatStateEntriesCompanion Function({
      Value<String> thermostatId,
      Value<double?> lastValueC,
      Value<String?> lastStatus,
      Value<DateTime?> lastFetchedAt,
      Value<String?> etag,
      Value<String?> statusMessage,
      Value<DateTime?> lastAlarmAt,
      Value<DateTime?> snoozedUntil,
      Value<bool> silenceUntilOk,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$ThermostatStateEntriesTableFilterComposer
    extends Composer<_$ThermostatDatabase, $ThermostatStateEntriesTable> {
  $$ThermostatStateEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get thermostatId => $composableBuilder(
    column: $table.thermostatId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get lastValueC => $composableBuilder(
    column: $table.lastValueC,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastStatus => $composableBuilder(
    column: $table.lastStatus,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastFetchedAt => $composableBuilder(
    column: $table.lastFetchedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get statusMessage => $composableBuilder(
    column: $table.statusMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastAlarmAt => $composableBuilder(
    column: $table.lastAlarmAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get snoozedUntil => $composableBuilder(
    column: $table.snoozedUntil,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get silenceUntilOk => $composableBuilder(
    column: $table.silenceUntilOk,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ThermostatStateEntriesTableOrderingComposer
    extends Composer<_$ThermostatDatabase, $ThermostatStateEntriesTable> {
  $$ThermostatStateEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get thermostatId => $composableBuilder(
    column: $table.thermostatId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get lastValueC => $composableBuilder(
    column: $table.lastValueC,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastStatus => $composableBuilder(
    column: $table.lastStatus,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastFetchedAt => $composableBuilder(
    column: $table.lastFetchedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get etag => $composableBuilder(
    column: $table.etag,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get statusMessage => $composableBuilder(
    column: $table.statusMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastAlarmAt => $composableBuilder(
    column: $table.lastAlarmAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get snoozedUntil => $composableBuilder(
    column: $table.snoozedUntil,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get silenceUntilOk => $composableBuilder(
    column: $table.silenceUntilOk,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ThermostatStateEntriesTableAnnotationComposer
    extends Composer<_$ThermostatDatabase, $ThermostatStateEntriesTable> {
  $$ThermostatStateEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get thermostatId => $composableBuilder(
    column: $table.thermostatId,
    builder: (column) => column,
  );

  GeneratedColumn<double> get lastValueC => $composableBuilder(
    column: $table.lastValueC,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastStatus => $composableBuilder(
    column: $table.lastStatus,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastFetchedAt => $composableBuilder(
    column: $table.lastFetchedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get etag =>
      $composableBuilder(column: $table.etag, builder: (column) => column);

  GeneratedColumn<String> get statusMessage => $composableBuilder(
    column: $table.statusMessage,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastAlarmAt => $composableBuilder(
    column: $table.lastAlarmAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get snoozedUntil => $composableBuilder(
    column: $table.snoozedUntil,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get silenceUntilOk => $composableBuilder(
    column: $table.silenceUntilOk,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$ThermostatStateEntriesTableTableManager
    extends
        RootTableManager<
          _$ThermostatDatabase,
          $ThermostatStateEntriesTable,
          ThermostatStateEntry,
          $$ThermostatStateEntriesTableFilterComposer,
          $$ThermostatStateEntriesTableOrderingComposer,
          $$ThermostatStateEntriesTableAnnotationComposer,
          $$ThermostatStateEntriesTableCreateCompanionBuilder,
          $$ThermostatStateEntriesTableUpdateCompanionBuilder,
          (
            ThermostatStateEntry,
            BaseReferences<
              _$ThermostatDatabase,
              $ThermostatStateEntriesTable,
              ThermostatStateEntry
            >,
          ),
          ThermostatStateEntry,
          PrefetchHooks Function()
        > {
  $$ThermostatStateEntriesTableTableManager(
    _$ThermostatDatabase db,
    $ThermostatStateEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ThermostatStateEntriesTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$ThermostatStateEntriesTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$ThermostatStateEntriesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> thermostatId = const Value.absent(),
                Value<double?> lastValueC = const Value.absent(),
                Value<String?> lastStatus = const Value.absent(),
                Value<DateTime?> lastFetchedAt = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<String?> statusMessage = const Value.absent(),
                Value<DateTime?> lastAlarmAt = const Value.absent(),
                Value<DateTime?> snoozedUntil = const Value.absent(),
                Value<bool> silenceUntilOk = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ThermostatStateEntriesCompanion(
                thermostatId: thermostatId,
                lastValueC: lastValueC,
                lastStatus: lastStatus,
                lastFetchedAt: lastFetchedAt,
                etag: etag,
                statusMessage: statusMessage,
                lastAlarmAt: lastAlarmAt,
                snoozedUntil: snoozedUntil,
                silenceUntilOk: silenceUntilOk,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String thermostatId,
                Value<double?> lastValueC = const Value.absent(),
                Value<String?> lastStatus = const Value.absent(),
                Value<DateTime?> lastFetchedAt = const Value.absent(),
                Value<String?> etag = const Value.absent(),
                Value<String?> statusMessage = const Value.absent(),
                Value<DateTime?> lastAlarmAt = const Value.absent(),
                Value<DateTime?> snoozedUntil = const Value.absent(),
                Value<bool> silenceUntilOk = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ThermostatStateEntriesCompanion.insert(
                thermostatId: thermostatId,
                lastValueC: lastValueC,
                lastStatus: lastStatus,
                lastFetchedAt: lastFetchedAt,
                etag: etag,
                statusMessage: statusMessage,
                lastAlarmAt: lastAlarmAt,
                snoozedUntil: snoozedUntil,
                silenceUntilOk: silenceUntilOk,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ThermostatStateEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$ThermostatDatabase,
      $ThermostatStateEntriesTable,
      ThermostatStateEntry,
      $$ThermostatStateEntriesTableFilterComposer,
      $$ThermostatStateEntriesTableOrderingComposer,
      $$ThermostatStateEntriesTableAnnotationComposer,
      $$ThermostatStateEntriesTableCreateCompanionBuilder,
      $$ThermostatStateEntriesTableUpdateCompanionBuilder,
      (
        ThermostatStateEntry,
        BaseReferences<
          _$ThermostatDatabase,
          $ThermostatStateEntriesTable,
          ThermostatStateEntry
        >,
      ),
      ThermostatStateEntry,
      PrefetchHooks Function()
    >;

class $ThermostatDatabaseManager {
  final _$ThermostatDatabase _db;
  $ThermostatDatabaseManager(this._db);
  $$ThermostatEntriesTableTableManager get thermostatEntries =>
      $$ThermostatEntriesTableTableManager(_db, _db.thermostatEntries);
  $$AlertConfigEntriesTableTableManager get alertConfigEntries =>
      $$AlertConfigEntriesTableTableManager(_db, _db.alertConfigEntries);
  $$ThermostatStateEntriesTableTableManager get thermostatStateEntries =>
      $$ThermostatStateEntriesTableTableManager(
        _db,
        _db.thermostatStateEntries,
      );
}
