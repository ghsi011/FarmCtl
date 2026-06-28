import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/settings/view/settings_page.dart';
import '../../features/thermostats/models/history_range.dart';
import '../../features/thermostats/view/alarm_fullscreen_page.dart';
import '../../features/thermostats/view/thermostat_detail_page.dart';
import '../../features/thermostats/view/thermostat_history_fullscreen_page.dart';
import '../../features/thermostats/view/thermostats_page.dart';
import 'router_keys.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: ThermostatsRoute.path,
    errorBuilder: (context, state) => const _RouteNotFoundPage(),
    routes: [
      GoRoute(
        path: AlarmRoute.path,
        name: AlarmRoute.name,
        parentNavigatorKey: rootNavigatorKey,
        pageBuilder: (context, state) {
          final thermostatId = state.pathParameters['id'];
          if (thermostatId == null) {
            return const NoTransitionPage(child: SizedBox.shrink());
          }
          return MaterialPage(
            key: state.pageKey,
            fullscreenDialog: true,
            child: AlarmFullScreenPage(thermostatId: thermostatId),
          );
        },
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return AppScaffold(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: ThermostatsRoute.path,
                name: ThermostatsRoute.name,
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: ThermostatsPage()),
                routes: [
                  GoRoute(
                    path: ThermostatDetailRoute.path,
                    name: ThermostatDetailRoute.name,
                    builder: (context, state) {
                      final thermostatId = state.pathParameters['id'];
                      if (thermostatId == null) {
                        return const SizedBox.shrink();
                      }
                      return ThermostatDetailPage(thermostatId: thermostatId);
                    },
                    routes: [
                      GoRoute(
                        path: ThermostatHistoryFullscreenRoute.path,
                        name: ThermostatHistoryFullscreenRoute.name,
                        parentNavigatorKey: rootNavigatorKey,
                        pageBuilder: (context, state) {
                          final thermostatId = state.pathParameters['id'];
                          if (thermostatId == null) {
                            return const NoTransitionPage(
                              child: SizedBox.shrink(),
                            );
                          }
                          final rangeName = state.uri.queryParameters['range'];
                          final initialRange =
                              thermostatHistoryRangeFromName(rangeName) ??
                              ThermostatHistoryRange.day;
                          return MaterialPage(
                            key: state.pageKey,
                            fullscreenDialog: true,
                            child: ThermostatHistoryFullscreenPage(
                              thermostatId: thermostatId,
                              initialRange: initialRange,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: SettingsRoute.path,
                name: SettingsRoute.name,
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: SettingsPage()),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

class AppScaffold extends StatelessWidget {
  const AppScaffold({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  void _goBranch(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.thermostat),
            label: 'Thermostats',
          ),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
        onDestinationSelected: _goBranch,
      ),
    );
  }
}

class ThermostatsRoute {
  static const name = 'thermostats';
  static const path = '/thermostats';
}

class ThermostatDetailRoute {
  static const name = 'thermostat-detail';
  static const path = 'detail/:id';
}

class ThermostatHistoryFullscreenRoute {
  static const name = 'thermostat-history-fullscreen';
  static const path = 'history';
}

class SettingsRoute {
  static const name = 'settings';
  static const path = '/settings';
}

class AlarmRoute {
  static const name = 'alarm';
  static const path = '/alarm/:id';

  static String pathFor(String thermostatId) => '/alarm/$thermostatId';
}

/// Branded fallback for an unknown or malformed deep link (e.g. a stale
/// notification payload) so the user lands somewhere recoverable.
class _RouteNotFoundPage extends StatelessWidget {
  const _RouteNotFoundPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Page not found')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.help_outline,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                "This screen isn't available",
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'The link may be outdated or the item was removed.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => context.goNamed(ThermostatsRoute.name),
                icon: const Icon(Icons.home_outlined),
                label: const Text('Go to Thermostats'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
