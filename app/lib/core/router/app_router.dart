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

  static String pathFor(String thermostatId) => 'detail/$thermostatId';
}

class ThermostatHistoryFullscreenRoute {
  static const name = 'thermostat-history-fullscreen';
  static const path = 'history';

  static String pathFor(String thermostatId) =>
      '${ThermostatDetailRoute.pathFor(thermostatId)}/$path';
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
