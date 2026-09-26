import 'dart:convert';

import 'package:farmctl/features/fleet/data/fleet_connection_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements FleetConnectionStorage {
  final values = <String, String>{};
  String? failWriteKey;
  bool commitThenFail = false;
  String? failDeleteKey;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWriteKey == key && !commitThenFail) {
      throw StateError('secret-token');
    }
    values[key] = value;
    if (failWriteKey == key) throw StateError('secret-token');
  }

  @override
  Future<void> delete(String key) async {
    if (failDeleteKey == key) throw StateError('delete failed');
    values.remove(key);
  }
}

const _recordKey = 'fleet_connection_v2_record';
const _legacyPrefix = 'fleet_connection_v1_';

void _seedLegacy(_MemoryStorage storage, {String token = 'legacy-secret'}) {
  storage.values.addAll({
    '${_legacyPrefix}owner': 'old-owner',
    '${_legacyPrefix}repo': 'old-repo',
    '${_legacyPrefix}branch': 'main',
    '${_legacyPrefix}path': 'fleet.json',
    '${_legacyPrefix}writer_token': token,
  });
}

FleetConnectionStore _store(_MemoryStorage storage) =>
    FleetConnectionStore(storage: storage, observeLifecycle: false);

void main() {
  test('saves one versioned validated phone-side connection record', () async {
    final storage = _MemoryStorage();
    final store = FleetConnectionStore(
      storage: storage,
      observeLifecycle: false,
    );
    await store.saveConnection(
      'farmctl',
      'private-config',
      'main',
      'fleet.json',
      'phone-writer-token',
    );

    expect(storage.values.keys, {_recordKey});
    expect(storage.values.keys, isNot(contains('github_token')));
    expect(jsonDecode(storage.values[_recordKey]!)['version'], 2);
    final connection = await store.loadConnection();
    expect(connection?.owner, 'farmctl');
    expect(connection?.writerToken, 'phone-writer-token');
    expect(connection.toString(), isNot(contains('phone-writer-token')));
    await expectLater(
      store.saveConnection('owner', 'repo', 'main', '../fleet.json', 'token'),
      throwsA(isA<FleetConnectionException>()),
    );
    await store.clearConnection();
    expect(await store.loadConnection(), isNull);
    expect(jsonDecode(storage.values[_recordKey]!)['state'], 'cleared');
    store.dispose();
  });

  test('loads complete legacy tuples but does not migrate on read', () async {
    final storage = _MemoryStorage();
    _seedLegacy(storage);
    final store = _store(storage);
    expect((await store.loadConnection())?.writerToken, 'legacy-secret');
    expect(storage.values, hasLength(5));
    store.dispose();
  });

  test('rejects incomplete legacy tuples', () async {
    final storage = _MemoryStorage();
    _seedLegacy(storage);
    storage.values.remove('${_legacyPrefix}repo');
    final store = _store(storage);
    await expectLater(
      store.loadConnection(),
      throwsA(isA<FleetConnectionException>()),
    );
    store.dispose();
  });

  test(
    'a malformed or unsupported v2 record never falls back to legacy',
    () async {
      for (final record in [
        '{bad',
        '{"version":3,"state":"cleared"}',
        '{"version":2,"state":"connected","owner":"x"}',
      ]) {
        final storage = _MemoryStorage()..values[_recordKey] = record;
        _seedLegacy(storage);
        final store = _store(storage);
        await expectLater(
          store.loadConnection(),
          throwsA(isA<FleetConnectionException>()),
        );
        store.dispose();
      }
    },
  );

  test(
    'write failure before and after mutation preserves a whole old or new record',
    () async {
      for (final commitThenFail in [false, true]) {
        final storage = _MemoryStorage();
        final store = _store(storage);
        await store.saveConnection(
          'old',
          'repo',
          'main',
          'fleet.json',
          'old-secret',
        );
        storage.failWriteKey = _recordKey;
        storage.commitThenFail = commitThenFail;
        await expectLater(
          store.saveConnection(
            'new',
            'repo',
            'main',
            'fleet.json',
            'new-secret',
          ),
          throwsA(isA<FleetConnectionException>()),
        );
        storage.failWriteKey = null;
        final connection = await store.loadConnection();
        expect(connection?.owner, commitThenFail ? 'new' : 'old');
        expect(
          connection?.writerToken,
          commitThenFail ? 'new-secret' : 'old-secret',
        );
        store.dispose();
      }
    },
  );

  test(
    'clear tombstone masks legacy despite interrupted legacy deletion',
    () async {
      for (final field in ['owner', 'repo', 'branch', 'path', 'writer_token']) {
        final storage = _MemoryStorage();
        _seedLegacy(storage);
        storage.failDeleteKey = '$_legacyPrefix$field';
        final store = _store(storage);
        await expectLater(
          store.clearConnection(),
          throwsA(
            isA<FleetConnectionException>().having(
              (error) => error.message,
              'message',
              'Could not remove all old saved values. Try again.',
            ),
          ),
        );
        expect(await store.loadConnection(), isNull);
        expect(storage.values[_recordKey], contains('cleared'));
        expect(storage.values, contains(storage.failDeleteKey));
        storage.failDeleteKey = null;
        await store.clearConnection();
        expect(
          storage.values.keys.where((key) => key.startsWith(_legacyPrefix)),
          isEmpty,
        );
        expect(await store.loadConnection(), isNull);
        store.dispose();
      }
    },
  );

  test(
    'failed tombstone write does not delete legacy; committed failure masks it',
    () async {
      for (final commitThenFail in [false, true]) {
        final storage = _MemoryStorage();
        _seedLegacy(storage);
        storage.failWriteKey = _recordKey;
        storage.commitThenFail = commitThenFail;
        final store = _store(storage);
        await expectLater(
          store.clearConnection(),
          throwsA(isA<FleetConnectionException>()),
        );
        expect(
          storage.values.keys.where((key) => key.startsWith(_legacyPrefix)),
          hasLength(5),
        );
        storage.failWriteKey = null;
        expect(
          (await store.loadConnection())?.owner,
          commitThenFail ? null : 'old-owner',
        );
        store.dispose();
      }
    },
  );

  test('concurrent save and clear execute in invocation order', () async {
    final storage = _MemoryStorage();
    final store = _store(storage);
    final save = store.saveConnection(
      'farm',
      'repo',
      'main',
      'fleet.json',
      'token',
    );
    final clear = store.clearConnection();
    await Future.wait([save, clear]);
    expect(await store.loadConnection(), isNull);
    store.dispose();
  });

  test('storage errors never include the writer token', () async {
    final storage = _MemoryStorage()..failWriteKey = _recordKey;
    final store = _store(storage);
    try {
      await store.saveConnection(
        'farm',
        'repo',
        'main',
        'fleet.json',
        'do-not-leak',
      );
      fail('expected failure');
    } on FleetConnectionException catch (error) {
      expect(error.toString(), isNot(contains('do-not-leak')));
    }
    store.dispose();
  });
}
