import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mato/models/server_profile.dart';

/// 記憶體版的安全儲存區（測試環境沒有平台實作）。
class FakeSecureStorage extends FlutterSecureStorage {
  FakeSecureStorage();

  final Map<String, String> values = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

ServerProfile testProfile({
  String id = '1',
  String username = 'deploy',
  String password = 'secret',
}) => ServerProfile(
  id: id,
  name: 'web-01',
  host: '10.0.0.5',
  port: 22,
  username: username,
  password: password,
  createdAt: DateTime(2026, 10, 1),
);
