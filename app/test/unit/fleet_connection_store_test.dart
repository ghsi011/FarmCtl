import 'package:farmctl/features/fleet/data/fleet_connection_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements FleetConnectionStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test(
    'saves only validated phone-side connection in feature-specific keys',
    () async {
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

      expect(
        storage.values.keys,
        containsAll([
          'fleet_connection_v1_owner',
          'fleet_connection_v1_repo',
          'fleet_connection_v1_branch',
          'fleet_connection_v1_path',
          'fleet_connection_v1_writer_token',
        ]),
      );
      expect(storage.values.keys, isNot(contains('github_token')));
      final connection = await store.loadConnection();
      expect(connection?.owner, 'farmctl');
      expect(connection?.writerToken, 'phone-writer-token');
      expect(connection.toString(), isNot(contains('phone-writer-token')));
      await expectLater(
        store.saveConnection('owner', 'repo', 'main', '../fleet.json', 'token'),
        throwsA(isA<FleetConnectionException>()),
      );
      await store.clearConnection();
      expect(storage.values, isEmpty);
      store.dispose();
    },
  );
}
