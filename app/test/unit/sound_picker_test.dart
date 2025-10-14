import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/settings/services/sound_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'com.example.farmctl/sound_picker';
  const channel = MethodChannel(channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('pickSound returns parsed URI from map result', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
          expect(methodCall.method, 'pickSound');
          expect(
            methodCall.arguments,
            isA<Map>().having(
              (args) => args['initialUri'],
              'initialUri',
              'content://previous',
            ),
          );
          return <String, String>{'uri': 'content://picked'};
        });

    final picker = SoundPicker();
    final uri = await picker.pickSound(
      initialUri: Uri.parse('content://previous'),
    );

    expect(uri, Uri.parse('content://picked'));
  });

  test('pickSound returns null when channel responds with null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async => null);

    final picker = SoundPicker();
    final uri = await picker.pickSound();

    expect(uri, isNull);
  });

  test('releasePersistedUri forwards to platform channel', () async {
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (methodCall) async {
          if (methodCall.method == 'releasePersistablePermission') {
            invoked = true;
            expect(methodCall.arguments, <String, String>{
              'uri': 'content://sound',
            });
          }
          return null;
        });

    final picker = SoundPicker();
    await picker.releasePersistedUri(Uri.parse('content://sound'));

    expect(invoked, isTrue);
  });
}
