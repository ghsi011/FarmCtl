import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/fleet_connection_store.dart';

final fleetConnectionStorageProvider = Provider<FleetConnectionStorage>(
  (ref) => FlutterFleetConnectionStorage(),
);

final fleetClientFactoryProvider = Provider<FleetClientFactory>(
  (ref) => FleetConnectionStore.defaultClientFactory,
);

final fleetClockProvider = Provider<FleetClock>((ref) => DateTime.now);

/// Auto-disposed service seam. Consumers should close edit sessions when the
/// editor is abandoned; provider disposal is an additional cleanup boundary.
final fleetConnectionStoreProvider = Provider.autoDispose<FleetConnectionStore>(
  (ref) {
    final store = FleetConnectionStore(
      storage: ref.watch(fleetConnectionStorageProvider),
      clientFactory: ref.watch(fleetClientFactoryProvider),
      clock: ref.watch(fleetClockProvider),
    );
    ref.onDispose(store.dispose);
    return store;
  },
);
