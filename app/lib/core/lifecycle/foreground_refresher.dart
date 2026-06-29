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
  // A launch/resume wants a refresh, but the thermostat list may not have
  // resolved yet. We latch the intent here and let the `ref.listen` in build
  // fulfil it once data arrives, so a launch/resume during a loading window is
  // never silently dropped. Cleared once a refresh actually runs (or is
  // satisfied by the throttle).
  bool _refreshPending = false;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onResume: _requestRefresh);
    // Cold launch: the list is usually still loading on the first frame, so this
    // marks the intent and the `ref.listen` below runs it once data arrives. If
    // rows are already cached it refreshes synchronously here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _requestRefresh();
      }
    });
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  /// Marks a refresh as wanted and attempts it immediately. If the thermostat
  /// list hasn't resolved yet the request stays pending (see [_refreshPending]).
  void _requestRefresh() {
    _refreshPending = true;
    _refreshAll();
  }

  Future<void> _refreshAll() async {
    if (_refreshing) {
      return;
    }
    final thermostats = ref.read(thermostatsProvider).asData?.value;
    if (thermostats == null || thermostats.isEmpty) {
      // No data to refresh yet; keep the request pending for the listener.
      return;
    }

    final now = ref.read(nowProvider)();
    final last = _lastRefreshAt;
    if (last != null && now.difference(last) < widget.minInterval) {
      // Refreshed recently enough; the request is considered satisfied.
      _refreshPending = false;
      return;
    }

    _refreshPending = false;
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
    // Fulfil a pending launch/resume refresh the moment the list resolves to a
    // non-empty value. Gated on `_refreshPending` so we don't re-fetch on every
    // DB write — only when a launch/resume is actually waiting on data.
    ref.listen(thermostatsProvider, (_, next) {
      if (_refreshPending && (next.asData?.value.isNotEmpty ?? false)) {
        _refreshAll();
      }
    });
    return widget.child;
  }
}
