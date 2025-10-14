import 'package:flutter/services.dart';

class SoundPicker {
  SoundPicker({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.example.farmctl/sound_picker');

  final MethodChannel _channel;

  Future<Uri?> pickSound({Uri? initialUri}) async {
    final arguments = <String, String>{
      if (initialUri != null) 'initialUri': initialUri.toString(),
    };

    final dynamic result = await _channel.invokeMethod<dynamic>(
      'pickSound',
      arguments,
    );

    if (result == null) {
      return null;
    }

    if (result is String) {
      return Uri.parse(result);
    }

    if (result is Map) {
      final dynamic uriValue = result['uri'];
      if (uriValue is String && uriValue.isNotEmpty) {
        return Uri.parse(uriValue);
      }
    }

    throw PlatformException(
      code: 'invalid-result',
      message: 'Sound picker returned an unexpected result: $result',
    );
  }

  Future<void> releasePersistedUri(Uri uri) async {
    await _channel.invokeMethod<void>(
      'releasePersistablePermission',
      <String, String>{'uri': uri.toString()},
    );
  }
}
