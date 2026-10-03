import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_client.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/data/thermostat_service.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';

class _SyntheticCommitAdapter implements HttpClientAdapter {
  _SyntheticCommitAdapter(this.commits);

  final List<GistCommit> commits;
  final List<int> requestedPages = [];
  int revisionRequests = 0;
  final List<String> requestedRevisions = [];
  int? failPage;
  String? failRevision;
  String? nullRevision;
  String? rawRevision;
  int rawStatusCode = 200;
  final List<String> requestedRawRevisions = [];
  Completer<void>? gate;
  Completer<void>? entered;
  int active = 0;
  int maxActive = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (entered != null && !entered!.isCompleted) entered!.complete();
      if (gate != null) await gate!.future;
      if (options.path.startsWith('https://synthetic.invalid/raw/')) {
        requestedRawRevisions.add(options.path.split('/').last);
        return ResponseBody.fromString('20 C', rawStatusCode);
      }
      if (!options.path.endsWith('/commits')) {
        revisionRequests += 1;
        final revision = options.path.split('/').last;
        requestedRevisions.add(revision);
        if (revision == failRevision) {
          return ResponseBody.fromString('{}', 503);
        }
        return ResponseBody.fromString(
          jsonEncode({
            'files': {
              'temperature.txt': {
                if (revision == rawRevision) ...{
                  'truncated': true,
                  'raw_url': 'https://synthetic.invalid/raw/$revision',
                },
                'content': revision == nullRevision
                    ? 'not a temperature'
                    : '20 C',
              },
            },
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      }
      final page = options.queryParameters['page'] as int;
      final perPage = options.queryParameters['per_page'] as int;
      requestedPages.add(page);
      if (page == failPage) return ResponseBody.fromString('{}', 503);
      final entries = commits.skip((page - 1) * perPage).take(perPage);
      return ResponseBody.fromString(
        jsonEncode([
          for (final commit in entries)
            {
              'version': commit.revisionId,
              'committed_at': commit.observedAt.toIso8601String(),
            },
        ]),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    } finally {
      active--;
    }
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'refreshHistory bounds commit-list requests on cached and rejected full pages',
    () async {
      final database = ThermostatDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = ThermostatRepository(database);
      final thermostat = await repository.create(
        ThermostatDraft(
          name: 'Synthetic history',
          rawUrl: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          minC: 0,
          maxC: 30,
        ),
      );
      final now = DateTime.utc(2026, 10, 3, 12);
      // Twenty-one full pages, then an empty page: finite even on the buggy
      // baseline. Half are cached; the rest lie inside the local history span
      // and are rejected by sampling, so no revision fetch is needed.
      final commits = List.generate(
        2100,
        (index) => GistCommit(
          revisionId: 'revision-$index',
          observedAt: now.subtract(Duration(seconds: index + 1)),
        ),
      );
      await repository.upsertHistory(
        thermostatId: thermostat.id,
        samples: [
          TemperatureSample.revision(
            thermostatId: thermostat.id,
            revisionId: 'newest-local',
            valueC: 20,
            observedAt: now,
          ),
          TemperatureSample.revision(
            thermostatId: thermostat.id,
            revisionId: 'oldest-local',
            valueC: 20,
            observedAt: now.subtract(const Duration(hours: 2)),
          ),
          for (var index = 0; index < commits.length; index += 2)
            TemperatureSample.revision(
              thermostatId: thermostat.id,
              revisionId: commits[index].revisionId,
              valueC: 20,
              observedAt: commits[index].observedAt,
            ),
        ],
      );
      final adapter = _SyntheticCommitAdapter(commits);
      final dio = Dio()..httpClientAdapter = adapter;
      // Explicit empty token and injected clients prevent environment-token
      // lookup and live HTTP, including the anonymous fallback transport.
      final network = ThermostatHttpClient(
        dio: dio,
        dioNoAuth: dio,
        githubToken: '',
        clock: () => now,
      );
      addTearDown(network.close);
      final service = ThermostatService(
        repository: repository,
        network: network,
        clock: () => now,
      );

      await service.refreshHistory(thermostat.id);

      expect(adapter.revisionRequests, 0);
      // A generous ceiling matching the existing anonymous revision budget:
      // skipped pages must not allow more than twenty list requests per run.
      expect(
        adapter.requestedPages.length,
        lessThanOrEqualTo(20),
        reason:
            'Cached or sampling-rejected pages must consume a finite '
            'commit-list request budget, not scan the entire remote history.',
      );
    },
  );

  for (final mode in ['cached', 'rejected', 'mixed']) {
    test(
      '$mode full pages have bounded lists and successive deep progress',
      () async {
        final fixture = await _Fixture.create();
        await fixture.seedSpan();
        fixture.adapter.commits.addAll(
          List.generate(
            2100,
            (index) => GistCommit(
              revisionId: 'skipped-$index',
              observedAt: fixture.now.subtract(const Duration(minutes: 30)),
            ),
          ),
        );
        if (mode != 'rejected') {
          await fixture.cache(
            fixture.adapter.commits.where(
              (commit) =>
                  mode == 'cached' ||
                  int.parse(commit.revisionId.split('-').last).isEven,
            ),
          );
        }
        fixture.adapter.commits.add(
          GistCommit(
            revisionId: 'deep-target',
            observedAt: fixture.now.subtract(const Duration(hours: 2)),
          ),
        );
        for (var run = 0; run < 12; run++) {
          final before = fixture.adapter.requestedPages.length;
          await fixture.service.refreshHistory(fixture.thermostat.id);
          expect(
            fixture.adapter.requestedPages.length - before,
            lessThanOrEqualTo(8),
          );
        }
        expect(await fixture.known(), contains('deep-target'));
      },
    );
  }

  test('a newer head EVERY run does not starve deep history', () async {
    final fixture = await _Fixture.create();
    await fixture.seedSpan();
    fixture.adapter.commits.addAll(
      List.generate(
        2100,
        (index) => GistCommit(
          revisionId: 'cached-$index',
          observedAt: fixture.now.subtract(const Duration(minutes: 30)),
        ),
      ),
    );
    await fixture.cache(fixture.adapter.commits);
    fixture.adapter.commits.add(
      GistCommit(
        revisionId: 'deep-under-prepends',
        observedAt: fixture.now.subtract(const Duration(hours: 2)),
      ),
    );
    for (var run = 0; run < 12; run++) {
      fixture.adapter.commits.insert(
        0,
        GistCommit(
          revisionId: 'new-$run',
          observedAt: fixture.now.add(Duration(hours: run + 1)),
        ),
      );
      await fixture.service.refreshHistory(fixture.thermostat.id);
      expect(await fixture.known(), contains('new-$run'));
    }
    expect(await fixture.known(), contains('deep-under-prepends'));
  });

  test(
    'multi-page prepend burst is swept without a gap or lost deep anchor',
    () async {
      final fixture = await _Fixture.create();
      await fixture.seedSpan();
      fixture.adapter.commits.addAll(
        List.generate(
          1800,
          (index) => GistCommit(
            revisionId: 'base-$index',
            observedAt: fixture.now.subtract(const Duration(minutes: 30)),
          ),
        ),
      );
      await fixture.cache(fixture.adapter.commits);
      fixture.adapter.commits.add(
        GistCommit(
          revisionId: 'burst-deep',
          observedAt: fixture.now.subtract(const Duration(hours: 2)),
        ),
      );
      await fixture.service.refreshHistory(fixture.thermostat.id);
      final burst = List.generate(
        950,
        (index) => GistCommit(
          revisionId: 'burst-$index',
          observedAt: fixture.now.add(Duration(hours: 950 - index)),
        ),
      );
      fixture.adapter.commits.insertAll(0, burst);
      for (var run = 0; run < 20; run++) {
        fixture.adapter.commits.insert(
          0,
          GistCommit(
            revisionId: 'during-burst-$run',
            observedAt: fixture.now.add(Duration(hours: 951 + run)),
          ),
        );
        final before = fixture.adapter.revisionRequests;
        await fixture.service.refreshHistory(fixture.thermostat.id);
        expect(
          fixture.adapter.revisionRequests - before,
          lessThanOrEqualTo(400),
        );
      }
      final known = await fixture.known();
      expect(known, containsAll(burst.map((commit) => commit.revisionId)));
      expect(known, contains('burst-deep'));
    },
  );

  test(
    'revision cap resumes a partial page rather than losing its tail',
    () async {
      final fixture = await _Fixture.create();
      fixture.adapter.commits.addAll(
        List.generate(
          650,
          (index) => GistCommit(
            revisionId: 'selected-$index',
            observedAt: fixture.now.add(Duration(hours: 650 - index)),
          ),
        ),
      );
      await fixture.service.refreshHistory(fixture.thermostat.id);
      expect(fixture.adapter.revisionRequests, lessThanOrEqualTo(400));
      expect((await fixture.known()).length, lessThan(650));
      for (var run = 0; run < 8; run++) {
        await fixture.service.refreshHistory(fixture.thermostat.id);
      }
      expect(
        await fixture.known(),
        containsAll(fixture.adapter.commits.map((commit) => commit.revisionId)),
      );
    },
  );

  test(
    'anonymous revision attempts stay within twenty and resume the tail',
    () async {
      final fixture = await _Fixture.create(anonymous: true);
      fixture.adapter.commits.addAll(
        List.generate(
          25,
          (index) => GistCommit(
            revisionId: 'anonymous-$index',
            observedAt: fixture.now.add(Duration(hours: 25 - index)),
          ),
        ),
      );
      await fixture.service.refreshHistory(fixture.thermostat.id);
      expect(fixture.adapter.revisionRequests, lessThanOrEqualTo(20));
      expect((await fixture.known()).length, lessThan(25));
      await fixture.service.refreshHistory(fixture.thermostat.id);
      expect(
        await fixture.known(),
        containsAll(fixture.adapter.commits.map((commit) => commit.revisionId)),
      );
    },
  );

  test(
    'a later-page list error preserves earlier acknowledged progress',
    () async {
      final fixture = await _Fixture.create();
      await fixture.seedSpan();
      fixture.adapter.commits.addAll(
        List.generate(
          1100,
          (index) => GistCommit(
            revisionId: 'before-list-error-$index',
            observedAt: fixture.now.subtract(const Duration(minutes: 30)),
          ),
        ),
      );
      fixture.adapter.commits.add(
        GistCommit(
          revisionId: 'after-list-error',
          observedAt: fixture.now.subtract(const Duration(hours: 2)),
        ),
      );
      fixture.adapter.failPage = 6;
      await expectLater(
        fixture.service.refreshHistory(fixture.thermostat.id),
        throwsA(anything),
      );
      fixture.adapter.failPage = null;
      for (var run = 0; run < 5; run++) {
        await fixture.service.refreshHistory(fixture.thermostat.id);
      }
      expect(await fixture.known(), contains('after-list-error'));
    },
  );

  test(
    'null revision is skipped without blocking deeper or successive progress',
    () async {
      final fixture = await _Fixture.create();
      await fixture.seedSpan();
      fixture.adapter.commits.addAll([
        GistCommit(
          revisionId: 'null-value',
          observedAt: fixture.now.subtract(
            const Duration(hours: 2, minutes: 1),
          ),
        ),
        // Same bucket: the null response must not consume it.
        GistCommit(
          revisionId: 'valid-after-null',
          observedAt: fixture.now.subtract(
            const Duration(hours: 2, minutes: 2),
          ),
        ),
        ...List.generate(
          1100,
          (index) => GistCommit(
            revisionId: 'skipped-after-null-$index',
            observedAt: fixture.now.subtract(const Duration(minutes: 30)),
          ),
        ),
        GistCommit(
          revisionId: 'deep-after-null',
          observedAt: fixture.now.subtract(const Duration(hours: 3)),
        ),
      ]);
      fixture.adapter.nullRevision = 'null-value';
      final before = fixture.adapter.revisionRequests;
      await fixture.service.refreshHistory(fixture.thermostat.id);
      expect(fixture.adapter.revisionRequests - before, lessThanOrEqualTo(400));
      expect(fixture.adapter.requestedRevisions, contains('null-value'));
      expect(await fixture.known(), isNot(contains('null-value')));
      expect(await fixture.known(), contains('valid-after-null'));
      // Leave the immutable null response in place across subsequent runs.
      for (var run = 0; run < 5; run++) {
        await fixture.service.refreshHistory(fixture.thermostat.id);
      }
      expect(await fixture.known(), contains('deep-after-null'));
      expect(await fixture.known(), isNot(contains('null-value')));
    },
  );

  for (final failure in ['list', 'revision', 'store']) {
    test('$failure failure leaves selected position replayable', () async {
      final fixture = await _Fixture.create();
      fixture.adapter.commits.addAll([
        GistCommit(revisionId: 'first', observedAt: fixture.now),
        GistCommit(
          revisionId: 'failed',
          observedAt: fixture.now.subtract(const Duration(hours: 1)),
        ),
        GistCommit(
          revisionId: 'after',
          observedAt: fixture.now.subtract(const Duration(hours: 2)),
        ),
      ]);
      if (failure == 'list') fixture.adapter.failPage = 1;
      if (failure == 'revision') fixture.adapter.failRevision = 'failed';
      if (failure == 'store') fixture.repository.failRevision = 'failed';
      await expectLater(
        fixture.service.refreshHistory(fixture.thermostat.id),
        throwsA(anything),
      );
      expect(await fixture.known(), isNot(contains('failed')));
      expect(await fixture.known(), isNot(contains('after')));
      fixture.adapter.failPage = null;
      fixture.adapter.failRevision = null;
      fixture.repository.failRevision = null;
      await fixture.service.refreshHistory(fixture.thermostat.id);
      expect(await fixture.known(), containsAll(['first', 'failed', 'after']));
    });
  }

  for (final statusCode in [503, 429]) {
    test(
      'HTTP $statusCode on a page-two revision is not acknowledged and recovers',
      () async {
        final fixture = await _Fixture.create();
        await fixture.seedSpan();
        fixture.adapter.commits.addAll([
          ...List.generate(
            100,
            (index) => GistCommit(
              revisionId: 'before-http-error-$index',
              observedAt: fixture.now.subtract(const Duration(minutes: 30)),
            ),
          ),
          GistCommit(
            revisionId: 'retryable-deep',
            observedAt: fixture.now.subtract(
              const Duration(hours: 2, minutes: 1),
            ),
          ),
          GistCommit(
            revisionId: 'after-retryable-deep',
            observedAt: fixture.now.subtract(
              const Duration(hours: 3, minutes: 1),
            ),
          ),
        ]);
        // Exercise actual HTTP -> Dio -> ThermostatFetchException conversion for
        // truncated raw content, which formerly became null and a permanent skip.
        fixture.adapter.rawRevision = 'retryable-deep';
        fixture.adapter.rawStatusCode = statusCode;
        await expectLater(
          fixture.service.refreshHistory(fixture.thermostat.id),
          throwsA(
            isA<ThermostatFetchException>()
                .having(
                  (error) => error.status,
                  'status',
                  ThermostatReadingStatus.httpError,
                )
                .having((error) => error.statusCode, 'HTTP status', statusCode),
          ),
        );
        expect(fixture.adapter.requestedPages, contains(2));
        expect(
          fixture.adapter.requestedRawRevisions,
          contains('retryable-deep'),
        );
        expect(await fixture.known(), isNot(contains('retryable-deep')));
        expect(await fixture.known(), isNot(contains('after-retryable-deep')));
        fixture.adapter.rawStatusCode = 200;
        await fixture.service.refreshHistory(fixture.thermostat.id);
        expect(
          await fixture.known(),
          containsAll(['retryable-deep', 'after-retryable-deep']),
        );
        await fixture.service.refreshHistory(fixture.thermostat.id);
        expect(await fixture.known(), contains('retryable-deep'));
      },
    );
  }

  test(
    'source reset ignores old-source coverage across successive refreshes',
    () async {
      final fixture = await _Fixture.create();
      fixture.adapter.commits.addAll([
        GistCommit(
          revisionId: 'source-a-newest',
          observedAt: fixture.now.add(const Duration(hours: 500)),
        ),
        GistCommit(
          revisionId: 'source-a-oldest',
          observedAt: fixture.now.subtract(const Duration(hours: 1)),
        ),
      ]);
      await fixture.service.refreshHistory(fixture.thermostat.id);
      await fixture.repository.update(
        fixture.thermostat,
        ThermostatDraft(
          name: 'Source B',
          rawUrl: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          minC: 0,
          maxC: 30,
        ),
      );
      // Every B revision lies inside A's retained span, including a partial-page
      // tail that must be selected on a later run rather than marked covered by A.
      final sourceCommits = List.generate(
        450,
        (index) => GistCommit(
          revisionId: 'source-b-$index',
          observedAt: fixture.now.add(Duration(hours: 450 - index)),
        ),
      );
      fixture.adapter.commits
        ..clear()
        ..addAll(sourceCommits);
      await fixture.service.refreshHistory(fixture.thermostat.id);
      expect(await fixture.known(), contains('source-b-0'));
      expect(await fixture.known(), isNot(contains('source-b-449')));
      for (var run = 0; run < 5; run++) {
        await fixture.service.refreshHistory(fixture.thermostat.id);
      }
      expect(
        await fixture.known(),
        containsAll(sourceCommits.map((commit) => commit.revisionId)),
      );
      expect(
        await fixture.known(),
        containsAll(['source-a-newest', 'source-a-oldest']),
      );
    },
  );

  test('end of history and source change restart safely', () async {
    final fixture = await _Fixture.create();
    await fixture.service.refreshHistory(fixture.thermostat.id);
    fixture.adapter.commits.add(
      GistCommit(revisionId: 'end-head', observedAt: fixture.now),
    );
    await fixture.service.refreshHistory(fixture.thermostat.id);
    fixture.adapter.commits.insert(
      0,
      GistCommit(
        revisionId: 'after-end',
        observedAt: fixture.now.add(const Duration(hours: 1)),
      ),
    );
    await fixture.service.refreshHistory(fixture.thermostat.id);
    await fixture.repository.update(
      fixture.thermostat,
      ThermostatDraft(
        name: 'Changed source',
        rawUrl: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        minC: 0,
        maxC: 30,
      ),
    );
    fixture.adapter.commits
      ..clear()
      ..add(
        GistCommit(
          revisionId: 'changed-source',
          observedAt: fixture.now.add(const Duration(hours: 2)),
        ),
      );
    await fixture.service.refreshHistory(fixture.thermostat.id);
    expect(
      await fixture.known(),
      containsAll(['end-head', 'after-end', 'changed-source']),
    );
  });

  test('missing anchors conservatively replay rewritten history', () async {
    final fixture = await _Fixture.create();
    await fixture.seedSpan();
    fixture.adapter.commits.addAll(
      List.generate(
        1100,
        (index) => GistCommit(
          revisionId: 'removed-$index',
          observedAt: fixture.now.subtract(const Duration(minutes: 30)),
        ),
      ),
    );
    await fixture.service.refreshHistory(fixture.thermostat.id);
    fixture.adapter.commits
      ..clear()
      ..addAll(
        List.generate(
          950,
          (index) => GistCommit(
            revisionId: 'replacement-$index',
            observedAt: fixture.now.subtract(const Duration(minutes: 30)),
          ),
        ),
      )
      ..add(
        GistCommit(
          revisionId: 'rewrite-target',
          observedAt: fixture.now.subtract(const Duration(hours: 2)),
        ),
      );
    for (var run = 0; run < 8; run++) {
      await fixture.service.refreshHistory(fixture.thermostat.id);
    }
    expect(await fixture.known(), contains('rewrite-target'));
    await fixture.repository.delete(fixture.thermostat.id);
    await expectLater(
      fixture.service.refreshHistory(fixture.thermostat.id),
      throwsStateError,
    );
  });

  test('same thermostat refreshes serialize even after a failed run', () async {
    final fixture = await _Fixture.create();
    fixture.adapter.commits.add(
      GistCommit(revisionId: 'serialized', observedAt: fixture.now),
    );
    fixture.adapter.gate = Completer<void>();
    fixture.adapter.entered = Completer<void>();
    final first = fixture.service.refreshHistory(fixture.thermostat.id);
    final second = fixture.service.refreshHistory(fixture.thermostat.id);
    await fixture.adapter.entered!.future;
    fixture.adapter.gate!.complete();
    await Future.wait([first, second]);
    expect(fixture.adapter.maxActive, 1);
    expect(
      fixture.adapter.requestedRevisions
          .where((revision) => revision == 'serialized')
          .length,
      1,
    );
    fixture.adapter.failPage = 1;
    await expectLater(
      fixture.service.refreshHistory(fixture.thermostat.id),
      throwsA(anything),
    );
    fixture.adapter.failPage = null;
    await fixture.service.refreshHistory(fixture.thermostat.id);
  });
}

class _FailingRepository extends ThermostatRepository {
  _FailingRepository(super.database);
  String? failRevision;

  @override
  Future<void> upsertHistory({
    required String thermostatId,
    required Iterable<TemperatureSample> samples,
  }) async {
    if (samples.any(
      (sample) => sample.sourceId == failRevision && failRevision != null,
    )) {
      throw StateError('Synthetic store failure');
    }
    await super.upsertHistory(thermostatId: thermostatId, samples: samples);
  }
}

class _Fixture {
  _Fixture(this.repository, this.thermostat, this.adapter, this.service);
  final _FailingRepository repository;
  final Thermostat thermostat;
  final _SyntheticCommitAdapter adapter;
  final ThermostatService service;
  final now = DateTime.utc(2026, 10, 3, 12);

  static Future<_Fixture> create({bool anonymous = false}) async {
    final database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = _FailingRepository(database);
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Synthetic history',
        rawUrl: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        minC: 0,
        maxC: 30,
      ),
    );
    final adapter = _SyntheticCommitAdapter([]);
    final dio = Dio()..httpClientAdapter = adapter;
    final now = DateTime.utc(2026, 10, 3, 12);
    // Safe explicit synthetic token avoids real credentials and makes the
    // existing authenticated no-delay path suitable for fast budget tests.
    final network = ThermostatHttpClient(
      dio: dio,
      dioNoAuth: dio,
      githubToken: anonymous ? '' : 'synthetic-only',
      clock: () => now,
    );
    addTearDown(network.close);
    return _Fixture(
      repository,
      thermostat,
      adapter,
      ThermostatService(
        repository: repository,
        network: network,
        clock: () => now,
      ),
    );
  }

  Future<Set<String>> known() => repository.listKnownRevisionIds(thermostat.id);

  Future<void> cache(Iterable<GistCommit> commits) => repository.upsertHistory(
    thermostatId: thermostat.id,
    samples: [
      for (final commit in commits)
        TemperatureSample.revision(
          thermostatId: thermostat.id,
          revisionId: commit.revisionId,
          valueC: 20,
          observedAt: commit.observedAt,
        ),
    ],
  );

  Future<void> seedSpan() => cache([
    GistCommit(revisionId: 'local-newest', observedAt: now),
    GistCommit(
      revisionId: 'local-oldest',
      observedAt: now.subtract(const Duration(hours: 1)),
    ),
  ]);
}
