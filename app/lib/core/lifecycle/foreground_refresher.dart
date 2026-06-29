import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/thermostats/providers/thermostat_providers.dart';

/// Wraps the app and re-fetches every thermostat's current reading whenever the
/// app is launched or brought back to the foreground.
///
/// Background checks (WorkManager + the AlarmManager one-shot chain) can be
/// deferred for long stretches by Android Doze and OEM battery optimisation, so
/// without this the first thing a user sees on opening the app is a stale,
/// possibly hours-old reading until they pull-to-refresh by hand. Refreshing on
/// resume makes that manual step automatic, which is the behaviour users expect
/// when they "enter the app to check the temperature".
class ForegroundRefresher extends ConsumerStatefulWidget {
  const ForegroundRefresher({
    required this.child,
    this.minInterval = const Duration(seconds: 15),
    super.key,
  });

  final Widget child;

  /// Lower bound between two automatic refreshes. Collapses a burst of resume
  /// events (or a resume landing right after a cold-launch refresh) into a
  /// single network sweep instead of stacking overlapping ones.
  final Duration minInterval;

  @override
  ConsumerState<ForegroundRefresher> createState() =>
      _ForegroundRefresherState();
}

class _ForegroundRefresherState extends ConsumerState<ForegroundRefresher> {
  late final AppLifecycleListener _lifecycleListener;
  DateTime? _lastRefreshAt;
  bool _refreshing = false;
  bool _initialRefreshDone = false;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _refreshAll);
    // Cold launch: the thermostat list is usually still loading on the first
    // frame, so the real kick happens from the `ref.listen` in build once data
    // arrives. This post-frame attempt covers the case where rows are already
    // cached and resolve synchronously.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshAll();
      }
    });
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    if (_refreshing) {
      return;
    }
    final thermostats = ref.read(thermostatsProvider).valueOrNull;
    if (thermostats == null || thermostats.isEmpty) {
      return;
    }

    final now = ref.read(nowProvider)();
    final last = _lastRefreshAt;
    if (last != null && now.difference(last) < widget.minInterval) {
      return;
    }

    _refreshing = true;
    _lastRefreshAt = now;
    try {
      await ref.read(thermostatBatchRefreshProvider)(thermostats);
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Cold launch: kick a refresh the first time the list resolves to a
    // non-empty value, then leave subsequent refreshes to the lifecycle resume
    // handler so we don't re-fetch on every DB write.
    ref.listen(thermostatsProvider, (_, next) {
      if (_initialRefreshDone) {
        return;
      }
      final thermostats = next.valueOrNull;
      if (thermostats != null && thermostats.isNotEmpty) {
        _initialRefreshDone = true;
        _refreshAll();
      }
    });
    return widget.child;
  }
}
