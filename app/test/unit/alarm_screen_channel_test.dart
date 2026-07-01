import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/services/alarm_screen_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.farmctl/alarm_screen');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('clearLockScreenFlags invokes the platform method', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
          calls.add(methodCall);
          return null;
        });

    await AlarmScreenChannel().clearLockScreenFlags();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'clearAlarmLockScreenFlags');
  });

  test(
    'clearLockScreenFlags is a no-op when the channel is not implemented',
    () async {
      // No handler registered: invokeMethod throws MissingPluginException,
      // which must be swallowed (tests, desktop platforms).
      await expectLater(AlarmScreenChannel().clearLockScreenFlags(), completes);
    },
  );

  test('clearLockScreenFlags swallows platform errors', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
          throw PlatformException(code: 'boom');
        });

    await expectLater(AlarmScreenChannel().clearLockScreenFlags(), completes);
  });
}
