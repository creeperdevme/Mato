import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;
import 'package:pointycastle/digests/sha256.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/ssh_key.dart';
import '../utils/shell.dart';
import 'secure_storage.dart';

class KeySecret {
  const KeySecret({required this.pem, this.passphrase = ''});

  final String pem;
  final String passphrase;
}

/// SSH 金鑰庫：中繼資料放一般設定，私鑰與密語放安全儲存區。
class KeyStore extends ChangeNotifier {
  KeyStore({FlutterSecureStorage? storage})
    : _secureStorage = storage ?? secureStorage;

  static const _metaKey = 'mato.keys.v1';

  final FlutterSecureStorage _secureStorage;
  final List<SshKeyEntry> _keys = [];

  List<SshKeyEntry> get keys => List.unmodifiable(_keys);

  SshKeyEntry? byId(String? id) =>
      id == null ? null : _keys.where((key) => key.id == id).firstOrNull;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_metaKey);
    if (raw != null) {
      try {
        _keys
          ..clear()
          ..addAll(
            (jsonDecode(raw) as List<dynamic>)
                .whereType<Map<String, dynamic>>()
                .map(SshKeyEntry.fromJson),
          );
      } catch (error) {
        debugPrint('無法讀取金鑰清單：$error');
      }
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _metaKey,
      jsonEncode(_keys.map((key) => key.toJson()).toList()),
    );
  }

  /// 匯入 PEM 私鑰（OpenSSH、PKCS#1 RSA、SEC1 EC）。解析失敗會丟出例外。
  Future<SshKeyEntry> importKey({
    required String name,
    required String pem,
    String passphrase = '',
    String? id,
  }) async {
    final normalized = pem.trim().replaceAll('\r\n', '\n');
    final encrypted = SSHKeyPair.isEncryptedPem(normalized);
    if (encrypted && passphrase.isEmpty) {
      throw const FormatException('這把私鑰已加密，請輸入密語');
    }
    final pairs = SSHKeyPair.fromPem(
      normalized,
      passphrase.isEmpty ? null : passphrase,
    );
    if (pairs.isEmpty) throw const FormatException('找不到可用的私鑰');
    final entry = describe(
      pairs.first,
      id: id ?? const Uuid().v4(),
      name: name,
      encrypted: encrypted,
    );
    await _secureStorage.write(
      key: _secretKey(entry.id),
      value: jsonEncode({'pem': '$normalized\n', 'passphrase': passphrase}),
    );
    _keys.removeWhere((key) => key.id == entry.id);
    _keys.add(entry);
    await _save();
    notifyListeners();
    return entry;
  }

  /// 在裝置上產生新的 Ed25519 金鑰。
  Future<SshKeyEntry> generateEd25519({
    required String name,
    String passphrase = '',
    String comment = 'mato',
  }) async {
    final signingKey = ed25519.SigningKey.generate();
    final pair = OpenSSHEd25519KeyPair(
      Uint8List.fromList(signingKey.verifyKey.asTypedList),
      Uint8List.fromList(signingKey.asTypedList),
      comment,
    );
    final pem = pair.toPem(passphrase: passphrase.isEmpty ? null : passphrase);
    return importKey(name: name, pem: pem, passphrase: passphrase);
  }

  Future<void> rename(String id, String name) async {
    final index = _keys.indexWhere((key) => key.id == id);
    if (index < 0) return;
    _keys[index] = _keys[index].copyWith(name: name);
    await _save();
    notifyListeners();
  }

  Future<void> delete(String id) async {
    _keys.removeWhere((key) => key.id == id);
    await _secureStorage.delete(key: _secretKey(id));
    await _save();
    notifyListeners();
  }

  Future<KeySecret?> secretOf(String id) async {
    final raw = await _secureStorage.read(key: _secretKey(id));
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return KeySecret(
        pem: map['pem'] as String? ?? '',
        passphrase: map['passphrase'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  static SshKeyEntry describe(
    SSHKeyPair pair, {
    required String id,
    required String name,
    required bool encrypted,
  }) {
    final blob = pair.toPublicKey().encode();
    final type = SSHHostKey.getType(blob);
    final digest = SHA256Digest().process(blob);
    final comment = name.trim().replaceAll(RegExp(r'\s+'), '-');
    return SshKeyEntry(
      id: id,
      name: name,
      type: type,
      publicKey: '$type ${base64.encode(blob)} $comment'.trim(),
      fingerprint: 'SHA256:${base64.encode(digest).replaceAll('=', '')}',
      encrypted: encrypted,
      createdAt: DateTime.now(),
    );
  }

  /// 把公鑰加進遠端 `~/.ssh/authorized_keys` 的指令（同 `ssh-copy-id`）。
  static String authorizeCommand(String publicKey) {
    final key = shellQuote(publicKey.trim());
    return 'umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && '
        '(grep -qxF $key ~/.ssh/authorized_keys || echo $key >> ~/.ssh/authorized_keys) '
        '&& chmod 600 ~/.ssh/authorized_keys && echo MATO_KEY_OK';
  }

  String _secretKey(String id) => 'mato.key.$id';
}
