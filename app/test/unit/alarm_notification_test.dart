import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/core/background/thermostat_monitor.dart';
import 'package:farmctl/features/settings/models/alert_config.dart';

AlertConfig _config({String? soundUri, bool vibrate = true}) {
  return AlertConfig(
    pollInterval: const Duration(minutes: 5),
    soundUri: soundUri,
    vibrate: vibrate,
    volumeBoost: false,
    pauseAllUntil: null,
    githubToken: null,
  );
}

void main() {
  group('alarmChannelIdFor', () {
    test('keeps the legacy id for the default sound with vibration on', () {
      // Existing installs created their channels with vibration enabled;
      // vibrate == true must map to the pre-existing channel id.
      expect(
        alarmChannelIdFor(soundUri: null, vibrate: true),
        'farmctl_alarm_default',
      );
      expect(
        alarmChannelIdFor(soundUri: '', vibrate: true),
        'farmctl_alarm_default',
      );
    });

    test('differs when only the vibrate setting differs', () {
      // Channel settings are immutable on Android 8+; the vibrate flag must
      // be part of the channel identity for the toggle to take effect.
      expect(
        alarmChannelIdFor(soundUri: null, vibrate: false),
        isNot(alarmChannelIdFor(soundUri: null, vibrate: true)),
      );
      const sound = 'content://media/audio/media/42';
      expect(
        alarmChannelIdFor(soundUri: sound, vibrate: false),
        isNot(alarmChannelIdFor(soundUri: sound, vibrate: true)),
      );
    });

    test('differs across sounds for the same vibrate setting', () {
      expect(
        alarmChannelIdFor(soundUri: 'content://media/1', vibrate: true),
        isNot(alarmChannelIdFor(soundUri: 'content://media/2', vibrate: true)),
      );
      expect(
        alarmChannelIdFor(soundUri: 'content://media/1', vibrate: true),
        isNot(alarmChannelIdFor(soundUri: null, vibrate: true)),
      );
    });
  });

  group('buildAlarmChannel', () {
    test('enables vibration only when configured', () {
      final vibrating = buildAlarmChannel(soundUri: null, vibrate: true);
      final silent = buildAlarmChannel(soundUri: null, vibrate: false);

      expect(vibrating.enableVibration, isTrue);
      expect(silent.enableVibration, isFalse);
      expect(vibrating.id, isNot(silent.id));
    });

    test('channel id matches alarmChannelIdFor', () {
      const sound = 'content://media/audio/media/7';
      final channel = buildAlarmChannel(soundUri: sound, vibrate: false);
      expect(channel.id, alarmChannelIdFor(soundUri: sound, vibrate: false));
    });
  });

  group('buildAlarmAndroidDetails', () {
    test('includes FLAG_INSISTENT so the alarm loops until acknowledged', () {
      final details = buildAlarmAndroidDetails(
        config: _config(),
        autoCancel: false,
        ongoing: true,
        actions: const [],
      );

      expect(details.additionalFlags, isNotNull);
      expect(details.additionalFlags, contains(insistentNotificationFlag));
    });

    test('vibration follows the config', () {
      final vibrating = buildAlarmAndroidDetails(
        config: _config(vibrate: true),
        autoCancel: false,
        ongoing: true,
        actions: const [],
      );
      final silent = buildAlarmAndroidDetails(
        config: _config(vibrate: false),
        autoCancel: false,
        ongoing: true,
        actions: const [],
      );

      expect(vibrating.enableVibration, isTrue);
      expect(silent.enableVibration, isFalse);
    });

    test('targets the channel that matches sound and vibrate', () {
      const sound = 'content://media/audio/media/9';
      final details = buildAlarmAndroidDetails(
        config: _config(soundUri: sound, vibrate: false),
        autoCancel: true,
        ongoing: false,
        actions: const [],
      );

      expect(
        details.channelId,
        alarmChannelIdFor(soundUri: sound, vibrate: false),
      );
      expect(details.autoCancel, isTrue);
      expect(details.ongoing, isFalse);
    });
  });
}
