import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:farmctl/core/permissions/notification_permission.dart';

NotificationPermissionChecker _checker(
  PermissionStatus status, {
  bool isAndroid = true,
}) {
  return NotificationPermissionChecker(
    isAndroid: isAndroid,
    readStatus: () async => status,
    openSettings: () async => true,
  );
}

void main() {
  group('NotificationPermissionChecker.status', () {
    test(
      'reports granted on non-Android platforms without touching the OS',
      () async {
        var reads = 0;
        final checker = NotificationPermissionChecker(
          isAndroid: false,
          readStatus: () async {
            reads += 1;
            return PermissionStatus.permanentlyDenied;
          },
        );

        expect(await checker.status(), AlarmNotificationPermission.granted);
        expect(reads, 0);
      },
    );

    test('maps granted-like OS states to granted', () async {
      for (final status in [
        PermissionStatus.granted,
        PermissionStatus.limited,
        PermissionStatus.provisional,
      ]) {
        expect(
          await _checker(status).status(),
          AlarmNotificationPermission.granted,
          reason: '$status should map to granted',
        );
      }
    });

    test('maps denied-like OS states to denied', () async {
      for (final status in [
        PermissionStatus.denied,
        PermissionStatus.permanentlyDenied,
        PermissionStatus.restricted,
      ]) {
        expect(
          await _checker(status).status(),
          AlarmNotificationPermission.denied,
          reason: '$status should map to denied',
        );
      }
    });

    test('reports unknown when the OS read fails', () async {
      final checker = NotificationPermissionChecker(
        isAndroid: true,
        readStatus: () async => throw Exception('platform channel down'),
      );

      expect(await checker.status(), AlarmNotificationPermission.unknown);
    });
  });

  test('openSettings delegates to the injected launcher', () async {
    var opened = 0;
    final checker = NotificationPermissionChecker(
      isAndroid: true,
      readStatus: () async => PermissionStatus.denied,
      openSettings: () async {
        opened += 1;
        return true;
      },
    );

    expect(await checker.openSettings(), isTrue);
    expect(opened, 1);
  });
}
