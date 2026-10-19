import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 全 App 共用的安全儲存區。
///
/// macOS 改用傳統 Keychain：Data Protection Keychain 需要 Keychain Sharing
/// 權限與簽章，未簽章的 nightly 版本會寫不進去。
const FlutterSecureStorage secureStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);
