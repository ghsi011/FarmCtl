import 'package:flutter/services.dart';

class SoundSelection {
  const SoundSelection({this.uri, required this.useDefault});

  final Uri? uri;
  final bool useDefault;
}

class SoundPicker {
  SoundPicker({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.example.farmctl/sound_picker');

  final MethodChannel _channel;

  Future<SoundSelection?> pickSound({Uri? initialUri}) async {
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
      return SoundSelection(uri: Uri.parse(result), useDefault: false);
    }

    if (result is Map) {
      final dynamic useDefaultValue = result['useDefault'];
      if (useDefaultValue is bool && useDefaultValue) {
        final dynamic uriValue = result['uri'];
        if (uriValue is String && uriValue.isNotEmpty) {
          return SoundSelection(uri: Uri.parse(uriValue), useDefault: true);
        }
        return const SoundSelection(uri: null, useDefault: true);
      }

      final dynamic uriValue = result['uri'];
      if (uriValue is String && uriValue.isNotEmpty) {
        return SoundSelection(uri: Uri.parse(uriValue), useDefault: false);
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
