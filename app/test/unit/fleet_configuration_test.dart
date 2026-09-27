import 'dart:convert';

import 'package:farmctl/features/fleet/models/fleet_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

const _revision = '11111111-1111-4111-8111-111111111111';
const _change = '22222222-2222-4222-8222-222222222222';

String _valid({String ssid = 'farm', String extra = ''}) =>
    '''{
  "schema_version":1,"fleet_revision":"$_revision","devices":{
    "device-a":{"change_id":"$_change","logical_id":"monitor-a",
    "wifi_profiles":[{"profile_id":"primary","ssid":${jsonEncode(ssid)},"password":"password123"}],
    "config_read_credential":"read-secret","temperature_gist_id":"${'a' * 32}",
    "diagnostics_gist_id":"${'b' * 32}","gist_write_credential":"write-secret",
    "sample_interval_seconds":60,"publication_interval_seconds":300$extra}
  }
}''';

void main() {
  test(
    'accepts a semantically populated 65,536-byte envelope and rejects 65,537',
    () {
      final fleet = <String, Object?>{
        'schema_version': 1,
        'fleet_revision': _revision,
        'devices': {
          for (var index = 0; index < 16; index++)
            'device-$index': {
              'change_id': _change,
              'logical_id': 'monitor-$index',
              'wifi_profiles': [
                for (var profile = 0; profile < 3; profile++)
                  {
                    'profile_id': 'wifi-$profile',
                    'ssid': 'ssid-$profile',
                    'password': 'password123',
                  },
              ],
              'config_read_credential': 'x',
              'temperature_gist_id': 'a' * 32,
              'diagnostics_gist_id': 'b' * 32,
              'gist_write_credential': 'x',
              'sample_interval_seconds': 60,
              'publication_interval_seconds': 300,
            },
        },
      };
      final devices = fleet['devices']! as Map<String, Object?>;
      var current = utf8.encode(jsonEncode(fleet)).length;
      var remaining = 65536 - current;
      for (final device in devices.values) {
        final entry = device as Map<String, Object?>;
        for (final key in const [
          'config_read_credential',
          'gist_write_credential',
        ]) {
          final amount = remaining.clamp(0, 2047);
          entry[key] = 'x' * (1 + amount);
          remaining -= amount;
        }
      }
      current = utf8.encode(jsonEncode(fleet)).length;
      expect(remaining, 0);
      final allowed = jsonEncode(fleet);
      expect(current, 65536);
      expect(utf8.encode(allowed).length, 65536);
      expect(FleetConfiguration.parse(allowed).devices, hasLength(16));
      expect(
        () => FleetConfiguration.parse('$allowed '),
        throwsFormatException,
      );
    },
  );

  test(
    'enforces SSID UTF-8 bytes, escaped duplicate keys, unknown fields and numeric types',
    () {
      expect(
        () => FleetConfiguration.parse(_valid(ssid: 'é' * 17)),
        throwsFormatException,
      );
      expect(
        () => FleetConfiguration.parse(
          '{"schema_version":1,"fleet_revision":"$_revision","devices":{"device-a":{},"device-a":{}}}',
        ),
        throwsFormatException,
      );
      expect(
        () => FleetConfiguration.parse(
          '{"schema_version":1,"fleet_revision":"$_revision","devices":{"device-a":{}},"dev\\u0069ces":{}}',
        ),
        throwsFormatException,
      );
      expect(
        () => FleetConfiguration.parse(_valid(extra: ',"extra":true')),
        throwsFormatException,
      );
      expect(
        () => FleetConfiguration.parse(
          _valid().replaceAll(
            '"sample_interval_seconds":60',
            '"sample_interval_seconds":60.0',
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => FleetConfiguration.parse(
          '{"schema_version":1,"devices":{"device-a":{}}}',
        ),
        throwsFormatException,
      );
      expect(
        () => FleetConfiguration.parse(
          _valid().replaceAll('"password":"password123"', '"password":"short"'),
        ),
        throwsFormatException,
      );
      expect(
        () => FleetConfiguration.parse(
          _valid().replaceAll('"read-secret"', '"read\\nsecret"'),
        ),
        throwsFormatException,
      );
      expect(
        () => FleetConfiguration.parse(
          '{"schema_version":1,"fleet_revision":"$_revision","devices":{}}',
        ),
        throwsFormatException,
      );
    },
  );

  test('accepts Wi-Fi password with eight UTF-8 bytes in four characters', () {
    final source = _valid().replaceAll(
      '"password":"password123"',
      '"password":"éééé"',
    );
    final configuration = FleetConfiguration.parse(source);
    expect(
      configuration.devices['device-a']!.wifiProfiles.single.password,
      'éééé',
    );
    expect(utf8.encode('éééé'), hasLength(8));
  });

  test('enforces diagnostic device-ref bounds and Gist publisher contract', () {
    final ref64 = 'd' * 64;
    final acceptedRef = _valid().replaceFirst('"device-a"', '"$ref64"');
    expect(FleetConfiguration.parse(acceptedRef).devices, contains(ref64));
    for (final ref in ['d' * 65, 'device:a']) {
      final invalidRef = _valid().replaceFirst('"device-a"', '"$ref"');
      expect(() => FleetConfiguration.parse(invalidRef), throwsFormatException);
    }

    for (final length in [33, 40]) {
      final invalidGist = _valid().replaceFirst(
        '"${'a' * 32}"',
        '"${'a' * length}"',
      );
      expect(
        () => FleetConfiguration.parse(invalidGist),
        throwsFormatException,
      );
    }
    final duplicateGists = _valid().replaceFirst(
      '"${'b' * 32}"',
      '"${'a' * 32}"',
    );
    expect(
      () => FleetConfiguration.parse(duplicateGists),
      throwsFormatException,
    );
  });

  test('rejects duplicate IDs and malformed trailing JSON', () {
    final duplicateLogical = _valid()
        .replaceAll('"monitor-a"', '"monitor-a"')
        .replaceFirst(
          '"devices":{',
          '"devices":{"device-b":{"change_id":"$_change","logical_id":"monitor-a",'
              '"wifi_profiles":[{"profile_id":"p","ssid":"ssid","password":"password123"}],"config_read_credential":"read-secret","temperature_gist_id":"${'a' * 32}",'
              '"diagnostics_gist_id":"${'b' * 32}","gist_write_credential":"write-secret",'
              '"sample_interval_seconds":60,"publication_interval_seconds":300},',
        );
    expect(
      () => FleetConfiguration.parse(duplicateLogical),
      throwsFormatException,
    );
    final duplicateProfile = _valid().replaceFirst(
      '"wifi_profiles":[{"profile_id":"primary","ssid":"farm","password":"password123"}]',
      '"wifi_profiles":[{"profile_id":"primary","ssid":"farm","password":"password123"},'
          '{"profile_id":"primary","ssid":"other","password":"password123"}]',
    );
    expect(
      () => FleetConfiguration.parse(duplicateProfile),
      throwsFormatException,
    );
    expect(
      () => FleetConfiguration.parse('${_valid()} trailing'),
      throwsFormatException,
    );
  });
}
