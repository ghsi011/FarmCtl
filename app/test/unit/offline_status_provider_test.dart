import 'dart:async';

import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Pin "now" so the provider's freshness windows are evaluated against the same
  // instant the fixtures are built around, keeping the tests deterministic.
  final fixedNow = DateTime.utc(2025, 10, 20, 12);

  Thermostat createThermostat(String id) {
    final now = DateTime.utc(2025, 10, 20);
    return Thermostat(
      id: id,
      name: 'Thermostat $id',
      rawUrl: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      minC: 2,
      maxC: 8,
      hysteresisEnabled: false,
      monitoringEnabled: true,
      createdAt: now,
      updatedAt: now,
    );
  }

  ThermostatState createState({
    required String thermostatId,
    required ThermostatReadingStatus status,
    DateTime? lastFetchedAt,
  }) {
    final now = DateTime.utc(2025, 10, 20, 12);
    return ThermostatState(
      thermostatId: thermostatId,
      status: status,
      lastValueC: status == ThermostatReadingStatus.ok ? 5.5 : null,
      lastFetchedAt: lastFetchedAt,
      etag: null,
      statusMessage: null,
      lastAlarmAt: null,
      snoozedUntil: null,
      silenceUntilOk: false,
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<OfflineStatus> readStatus(ProviderContainer container) async {
    final completer = Completer<OfflineStatus>();
    final sub = container.listen<OfflineStatus>(offlineStatusProvider, (
      previous,
      next,
    ) {
      if (!completer.isCompleted && next != OfflineStatus.unknown) {
        completer.complete(next);
      }
    }, fireImmediately: true);

    try {
      return await completer.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () => container.read(offlineStatusProvider),
      );
    } finally {
      sub.close();
    }
  }

  test(
    'offlineStatusProvider reports offline when only network errors',
    () async {
      final container = ProviderContainer(
        overrides: [
          nowProvider.overrideWithValue(() => fixedNow),
          thermostatsProvider.overrideWith(
            (ref) => Stream.value([
              ThermostatSummary(
                thermostat: createThermostat('1'),
                state: createState(
                  thermostatId: '1',
                  status: ThermostatReadingStatus.networkError,
                  lastFetchedAt: DateTime.utc(2025, 10, 20, 11, 55),
                ),
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final status = await readStatus(container);
      expect(status, OfflineStatus.offline);
    },
  );

  test('offlineStatusProvider reports degraded when mixed results', () async {
    final container = ProviderContainer(
      overrides: [
        nowProvider.overrideWithValue(() => fixedNow),
        thermostatsProvider.overrideWith(
          (ref) => Stream.value([
            ThermostatSummary(
              thermostat: createThermostat('1'),
              state: createState(
                thermostatId: '1',
                status: ThermostatReadingStatus.networkError,
                lastFetchedAt: DateTime.utc(2025, 10, 20, 11, 55),
              ),
            ),
            ThermostatSummary(
              thermostat: createThermostat('2'),
              state: createState(
                thermostatId: '2',
                status: ThermostatReadingStatus.ok,
                lastFetchedAt: DateTime.utc(2025, 10, 20, 11, 58),
              ),
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);

    final status = await readStatus(container);
    expect(status, OfflineStatus.degraded);
  });

  test(
    'offlineStatusProvider reports online when no network failures',
    () async {
      final container = ProviderContainer(
        overrides: [
          nowProvider.overrideWithValue(() => fixedNow),
          thermostatsProvider.overrideWith(
            (ref) => Stream.value([
              ThermostatSummary(
                thermostat: createThermostat('1'),
                state: createState(
                  thermostatId: '1',
                  status: ThermostatReadingStatus.ok,
                  lastFetchedAt: DateTime.utc(2025, 10, 20, 11, 55),
                ),
              ),
              ThermostatSummary(
                thermostat: createThermostat('2'),
                state: createState(
                  thermostatId: '2',
                  status: ThermostatReadingStatus.outOfRange,
                  lastFetchedAt: DateTime.utc(2025, 10, 20, 11, 54),
                ),
              ),
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);

      final status = await readStatus(container);
      expect(status, OfflineStatus.online);
    },
  );

  ProviderContainer containerWith(List<ThermostatSummary> summaries) {
    final container = ProviderContainer(
      overrides: [
        nowProvider.overrideWithValue(() => fixedNow),
        thermostatsProvider.overrideWith((ref) => Stream.value(summaries)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  ThermostatSummary summaryWith(
    String id,
    ThermostatReadingStatus status, {
    required DateTime fetchedAt,
  }) {
    return ThermostatSummary(
      thermostat: createThermostat(id),
      state: createState(
        thermostatId: id,
        status: status,
        lastFetchedAt: fetchedAt,
      ),
    );
  }

  test('online when there are no thermostats', () async {
    expect(await readStatus(containerWith([])), OfflineStatus.online);
  });

  test('online when the only network error is older than 30 minutes', () async {
    final container = containerWith([
      summaryWith(
        '1',
        ThermostatReadingStatus.networkError,
        fetchedAt: fixedNow.subtract(const Duration(minutes: 40)),
      ),
    ]);
    expect(await readStatus(container), OfflineStatus.online);
  });

  test(
    'offline when a recent failure coexists with only stale successes',
    () async {
      final container = containerWith([
        summaryWith(
          '1',
          ThermostatReadingStatus.networkError,
          fetchedAt: fixedNow.subtract(const Duration(minutes: 10)),
        ),
        summaryWith(
          '2',
          ThermostatReadingStatus.ok,
          // Older than the 15-minute "recent success" window.
          fetchedAt: fixedNow.subtract(const Duration(minutes: 20)),
        ),
      ]);
      expect(await readStatus(container), OfflineStatus.offline);
    },
  );

  test('httpError is not treated as a connectivity failure', () async {
    final container = containerWith([
      summaryWith(
        '1',
        ThermostatReadingStatus.httpError,
        fetchedAt: fixedNow.subtract(const Duration(minutes: 5)),
      ),
    ]);
    expect(await readStatus(container), OfflineStatus.online);
  });

  test('unknown while the thermostats stream is loading/errored', () async {
    final container = ProviderContainer(
      overrides: [
        nowProvider.overrideWithValue(() => fixedNow),
        thermostatsProvider.overrideWith(
          (ref) => Stream<List<ThermostatSummary>>.error(Exception('boom')),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(offlineStatusProvider), OfflineStatus.unknown);
  });
}
