import 'dart:convert';

/// Schema-v1 bounds: 1-16 devices; 1-3 profiles/device; device refs 1-256 ASCII chars;
/// logical/profile IDs 1-64/1-32 ASCII chars; SSIDs 1-32 UTF-8 bytes;
/// WPA passphrases 8-63 UTF-8 bytes or 64 hex PSK; credentials 1-2048 visible
/// ASCII chars without whitespace/control; gist IDs 32-40 hex chars.
/// The envelope limit is 65,536 UTF-8 bytes (not characters).
class FleetConfiguration {
  const FleetConfiguration({required this.revision, required this.devices});

  final String revision;
  final Map<String, FleetDeviceConfiguration> devices;

  static const maxBytes = 65536;
  static const maxDevices = 16;
  static const maxProfilesPerDevice = 3;

  static FleetConfiguration parse(String source) {
    if (utf8.encode(source).length > maxBytes) {
      throw const FormatException('Fleet configuration exceeds size limit.');
    }
    _DuplicateKeyScanner(source).scan();
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('Fleet configuration is malformed.');
    }
    final root = _object(decoded, 'root');
    _fields(root, const {'schema_version', 'fleet_revision', 'devices'});
    if (root['schema_version'] != 1 || root['schema_version'] is! int) {
      throw const FormatException('Unsupported fleet schema.');
    }
    final revision = _uuid(root['fleet_revision'], 'fleet_revision');
    final rawDevices = _object(root['devices'], 'devices');
    if (rawDevices.isEmpty || rawDevices.length > maxDevices) {
      _invalid('Invalid device count.');
    }
    final devices = <String, FleetDeviceConfiguration>{};
    final logicalIds = <String>{};
    for (final entry in rawDevices.entries) {
      final ref = entry.key;
      if (!_bounded(ref, 1, 256) ||
          !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(ref)) {
        _invalid('Invalid device reference.');
      }
      final raw = _object(entry.value, 'device');
      _fields(raw, const {
        'change_id',
        'logical_id',
        'wifi_profiles',
        'config_read_credential',
        'temperature_gist_id',
        'diagnostics_gist_id',
        'gist_write_credential',
        'sample_interval_seconds',
        'publication_interval_seconds',
      });
      final logical = _string(raw['logical_id'], 'logical_id', 1, 64);
      if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(logical) ||
          !logicalIds.add(logical)) {
        _invalid('Invalid or duplicate logical ID.');
      }
      final profiles = raw['wifi_profiles'];
      if (profiles is! List ||
          profiles.isEmpty ||
          profiles.length > maxProfilesPerDevice) {
        _invalid('Invalid Wi-Fi profiles.');
      }
      final profileIds = <String>{};
      final parsedProfiles = <FleetWifiProfile>[];
      for (final item in profiles) {
        final profile = _object(item, 'Wi-Fi profile');
        _fields(profile, const {'profile_id', 'ssid', 'password'});
        final id = _string(profile['profile_id'], 'profile_id', 1, 32);
        if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id) || !profileIds.add(id)) {
          _invalid('Invalid or duplicate Wi-Fi profile ID.');
        }
        final ssid = _string(profile['ssid'], 'ssid', 1, 32);
        if (utf8.encode(ssid).length > 32) {
          _invalid('Invalid SSID.');
        }
        final password = _string(profile['password'], 'password', 1, 64);
        final passwordBytes = utf8.encode(password).length;
        if (!((passwordBytes >= 8 && passwordBytes <= 63) ||
            (passwordBytes == 64 &&
                RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(password)))) {
          _invalid('Invalid Wi-Fi password.');
        }
        parsedProfiles.add(
          FleetWifiProfile(profileId: id, ssid: ssid, password: password),
        );
      }
      final sample = _int(raw['sample_interval_seconds'], 'sample interval');
      final publication = _int(
        raw['publication_interval_seconds'],
        'publication interval',
      );
      if (sample < 10 ||
          sample > 300 ||
          publication < 60 ||
          publication > 300 ||
          sample > publication) {
        _invalid('Invalid sampling intervals.');
      }
      devices[ref] = FleetDeviceConfiguration(
        changeId: _uuid(raw['change_id'], 'change_id'),
        logicalId: logical,
        wifiProfiles: List.unmodifiable(parsedProfiles),
        configReadCredential: _credential(raw['config_read_credential']),
        temperatureGistId: _gist(raw['temperature_gist_id']),
        diagnosticsGistId: _gist(raw['diagnostics_gist_id']),
        gistWriteCredential: _credential(raw['gist_write_credential']),
        sampleIntervalSeconds: sample,
        publicationIntervalSeconds: publication,
      );
    }
    return FleetConfiguration(
      revision: revision,
      devices: Map.unmodifiable(devices),
    );
  }

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'fleet_revision': revision,
    'devices': {for (final e in devices.entries) e.key: e.value.toJson()},
  };

  static Map<String, dynamic> _object(Object? value, String field) {
    if (value is Map<String, dynamic>) return value;
    _invalid('Invalid $field object.');
  }

  static void _fields(Map<String, dynamic> value, Set<String> known) {
    if (value.keys.any((key) => !known.contains(key))) {
      _invalid('Unknown field.');
    }
    if (value.length != known.length) _invalid('Required field missing.');
  }

  static bool _bounded(String value, int min, int max) =>
      value.length >= min && value.length <= max;
  static String _string(Object? value, String name, int min, int max) {
    if (value is! String || !_bounded(value, min, max)) {
      _invalid('Invalid $name.');
    }
    return value;
  }

  static int _int(Object? value, String name) {
    if (value is! int) {
      _invalid('Invalid $name.');
    }
    return value;
  }

  static String _credential(Object? value) {
    final string = _string(value, 'credential', 1, 2048);
    if (!RegExp(r'^[!-~]+$').hasMatch(string)) _invalid('Invalid credential.');
    return string;
  }

  static String _uuid(Object? value, String name) {
    final string = _string(value, name, 36, 36);
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    ).hasMatch(string)) {
      _invalid('Invalid $name.');
    }
    return string;
  }

  static String _gist(Object? value) {
    final string = _string(value, 'Gist ID', 32, 40);
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(string)) {
      _invalid('Invalid Gist ID.');
    }
    return string;
  }

  static Never _invalid(String message) => throw FormatException(message);
}

class FleetWifiProfile {
  const FleetWifiProfile({
    required this.profileId,
    required this.ssid,
    required this.password,
  });
  final String profileId, ssid, password;
  Map<String, Object?> toJson() => {
    'profile_id': profileId,
    'ssid': ssid,
    'password': password,
  };
}

class FleetDeviceConfiguration {
  const FleetDeviceConfiguration({
    required this.changeId,
    required this.logicalId,
    required this.wifiProfiles,
    required this.configReadCredential,
    required this.temperatureGistId,
    required this.diagnosticsGistId,
    required this.gistWriteCredential,
    required this.sampleIntervalSeconds,
    required this.publicationIntervalSeconds,
  });
  final String changeId,
      logicalId,
      configReadCredential,
      temperatureGistId,
      diagnosticsGistId,
      gistWriteCredential;
  final List<FleetWifiProfile> wifiProfiles;
  final int sampleIntervalSeconds, publicationIntervalSeconds;
  Map<String, Object?> toJson() => {
    'change_id': changeId,
    'logical_id': logicalId,
    'wifi_profiles': wifiProfiles.map((profile) => profile.toJson()).toList(),
    'config_read_credential': configReadCredential,
    'temperature_gist_id': temperatureGistId,
    'diagnostics_gist_id': diagnosticsGistId,
    'gist_write_credential': gistWriteCredential,
    'sample_interval_seconds': sampleIntervalSeconds,
    'publication_interval_seconds': publicationIntervalSeconds,
  };
}

/// Structural preflight checks decoded object keys before Dart's map decoder
/// can silently collapse duplicates. Nesting counts arrays and objects.
class _DuplicateKeyScanner {
  _DuplicateKeyScanner(this.source);
  final String source;
  int index = 0;
  void scan() {
    _space();
    _value(0);
    _space();
    if (index != source.length) _bad();
  }

  void _value(int depth) {
    _space();
    if (depth > 8 || index >= source.length) _bad();
    final char = source[index];
    if (char == '{') {
      _object(depth + 1);
      return;
    }
    if (char == '[') {
      _array(depth + 1);
      return;
    }
    if (char == '"') {
      _string();
      return;
    }
    while (index < source.length && !',]} \r\n\t'.contains(source[index])) {
      index++;
    }
    if (index == 0) _bad();
  }

  void _object(int depth) {
    index++;
    _space();
    final keys = <String>{};
    if (_take('}')) return;
    while (true) {
      _space();
      final start = index;
      if (!_take('"')) _bad();
      index = start;
      _string();
      final key = jsonDecode(source.substring(start, index));
      if (key is! String || !keys.add(key)) _bad();
      _space();
      if (!_take(':')) _bad();
      _value(depth);
      _space();
      if (_take('}')) return;
      if (!_take(',')) _bad();
    }
  }

  void _array(int depth) {
    index++;
    _space();
    if (_take(']')) return;
    while (true) {
      _value(depth);
      _space();
      if (_take(']')) return;
      if (!_take(',')) _bad();
    }
  }

  void _string() {
    if (!_take('"')) _bad();
    while (index < source.length) {
      final unit = source.codeUnitAt(index++);
      if (unit == 0x22) return;
      if (unit == 0x5c) {
        if (index >= source.length) _bad();
        index++;
      } else if (unit < 0x20) {
        _bad();
      }
    }
    _bad();
  }

  void _space() {
    while (index < source.length && ' \r\n\t'.contains(source[index])) {
      index++;
    }
  }

  bool _take(String char) {
    if (index < source.length && source[index] == char) {
      index++;
      return true;
    }
    return false;
  }

  Never _bad() => throw const FormatException(
    'Fleet configuration is malformed or contains duplicate keys.',
  );
}
