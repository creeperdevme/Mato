import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../models/port_forward.dart';
import '../models/script.dart';
import '../models/server_profile.dart';
import 'key_store.dart';
import 'port_forward_service.dart';
import 'script_store.dart';
import 'server_store.dart';
import 'settings_store.dart';

class BackupSummary {
  const BackupSummary({
    required this.servers,
    required this.keys,
    required this.scripts,
    required this.forwards,
  });

  final int servers;
  final int keys;
  final int scripts;
  final int forwards;

  @override
  String toString() => '$servers 台伺服器、$keys 把金鑰、$scripts 個腳本、$forwards 條轉發規則';
}

class BackupPasswordException implements Exception {
  const BackupPasswordException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 匯出／匯入所有設定（取代 NeoServer 的 iCloud 同步）。
///
/// 含密碼與私鑰時一律以 PBKDF2-SHA256 + AES-256-GCM 加密，機密不會以明文
/// 寫進檔案。
class BackupService {
  BackupService({
    required this.servers,
    required this.keys,
    required this.scripts,
    required this.settings,
    required this.forwards,
  });

  final ServerStore servers;
  final KeyStore keys;
  final ScriptStore scripts;
  final SettingsStore settings;
  final PortForwardService forwards;

  static const _format = 'mato-backup';
  static const _iterations = 120000;

  static bool isEncrypted(String content) {
    try {
      final json = jsonDecode(content) as Map<String, dynamic>;
      return json['encrypted'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<String> export({bool includeSecrets = false, String? password}) async {
    if (includeSecrets && (password == null || password.isEmpty)) {
      throw const BackupPasswordException('包含機密資料時必須設定備份密碼');
    }
    final data = <String, dynamic>{
      'servers': [
        for (final server in servers.servers)
          {
            ...server.toJson(),
            if (includeSecrets) ...{
              'secretPassword': await servers.getPassword(server.id) ?? '',
              'secretProxyPassword':
                  await servers.getProxyPassword(server.id) ?? '',
            },
          },
      ],
      'keys': [
        if (includeSecrets)
          for (final key in keys.keys)
            {
              ...key.toJson(),
              'pem': (await keys.secretOf(key.id))?.pem ?? '',
              'passphrase': (await keys.secretOf(key.id))?.passphrase ?? '',
            },
      ],
      'scripts': [for (final script in scripts.scripts) script.toJson()],
      'forwards': [for (final rule in forwards.rules) rule.toJson()],
      'settings': settings.exportValues(),
    };

    final envelope = <String, dynamic>{
      'format': _format,
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'encrypted': includeSecrets,
    };
    if (!includeSecrets) {
      envelope['data'] = data;
    } else {
      envelope.addAll(await _encrypt(jsonEncode(data), password!));
    }
    return const JsonEncoder.withIndent('  ').convert(envelope);
  }

  Future<BackupSummary> import(String content, {String? password}) async {
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('不是有效的 Mato 備份檔');
    }
    if (envelope['format'] != _format) {
      throw const FormatException('不是有效的 Mato 備份檔');
    }

    final Map<String, dynamic> data;
    if (envelope['encrypted'] == true) {
      if (password == null || password.isEmpty) {
        throw const BackupPasswordException('這份備份已加密，請輸入備份密碼');
      }
      data = jsonDecode(
        await _decrypt(envelope, password),
      ) as Map<String, dynamic>;
    } else {
      data = envelope['data'] as Map<String, dynamic>? ?? const {};
    }

    var keyCount = 0;
    for (final item in (data['keys'] as List<dynamic>? ?? const [])) {
      final map = item as Map<String, dynamic>;
      final pem = map['pem'] as String? ?? '';
      if (pem.isEmpty) continue;
      await keys.importKey(
        id: map['id'] as String?,
        name: map['name'] as String? ?? '匯入的金鑰',
        pem: pem,
        passphrase: map['passphrase'] as String? ?? '',
      );
      keyCount++;
    }

    var serverCount = 0;
    for (final item in (data['servers'] as List<dynamic>? ?? const [])) {
      final map = item as Map<String, dynamic>;
      final profile = ServerProfile.fromJson(map);
      await servers.upsert(
        profile,
        secrets: ServerSecrets(
          password: map['secretPassword'] as String?,
          proxyPassword: map['secretProxyPassword'] as String?,
        ),
      );
      serverCount++;
    }

    var scriptCount = 0;
    for (final item in (data['scripts'] as List<dynamic>? ?? const [])) {
      await scripts.save(Script.fromJson(item as Map<String, dynamic>));
      scriptCount++;
    }

    final rules = (data['forwards'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PortForwardRule.fromJson)
        .toList();
    await forwards.upsertRules(rules);

    final settingValues = data['settings'];
    if (settingValues is Map<String, dynamic>) {
      await settings.importValues(settingValues);
    }

    return BackupSummary(
      servers: serverCount,
      keys: keyCount,
      scripts: scriptCount,
      forwards: rules.length,
    );
  }

  static Future<Map<String, dynamic>> _encrypt(
    String plaintext,
    String password,
  ) async {
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List.generate(16, (_) => random.nextInt(256)),
    );
    final nonce = Uint8List.fromList(
      List.generate(12, (_) => random.nextInt(256)),
    );
    final key = await Isolate.run(
      () => _deriveKey(password, salt, _iterations),
    );
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    final ciphertext = cipher.process(
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    return {
      'kdf': 'pbkdf2-sha256',
      'iterations': _iterations,
      'cipher': 'aes-256-gcm',
      'salt': base64.encode(salt),
      'nonce': base64.encode(nonce),
      'ciphertext': base64.encode(ciphertext),
    };
  }

  static Future<String> _decrypt(
    Map<String, dynamic> envelope,
    String password,
  ) async {
    final salt = base64.decode(envelope['salt'] as String);
    final nonce = base64.decode(envelope['nonce'] as String);
    final ciphertext = base64.decode(envelope['ciphertext'] as String);
    final iterations = envelope['iterations'] as int? ?? _iterations;
    final key = await Isolate.run(
      () => _deriveKey(password, Uint8List.fromList(salt), iterations),
    );
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
        );
      return utf8.decode(cipher.process(ciphertext));
    } on InvalidCipherTextException {
      throw const BackupPasswordException('備份密碼錯誤');
    }
  }

  static Uint8List _deriveKey(String password, Uint8List salt, int iterations) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, 32));
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }
}
