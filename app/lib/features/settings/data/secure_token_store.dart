import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the GitHub personal access token outside the app's plaintext SQLite
/// database, in platform-backed secure storage (Android Keystore / iOS
/// Keychain).
///
/// Abstracted behind an interface so it can be faked in tests without touching
/// platform channels.
abstract class SecureTokenStore {
  Future<String?> readToken();
  Future<void> writeToken(String? token);
}

class FlutterSecureTokenStore implements SecureTokenStore {
  FlutterSecureTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const String _tokenKey = 'github_token';

  @override
  Future<String?> readToken() async {
    final value = await _storage.read(key: _tokenKey);
    return (value == null || value.isEmpty) ? null : value;
  }

  @override
  Future<void> writeToken(String? token) async {
    if (token == null || token.isEmpty) {
      await _storage.delete(key: _tokenKey);
    } else {
      await _storage.write(key: _tokenKey, value: token);
    }
  }
}
