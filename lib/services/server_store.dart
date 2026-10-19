import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/server_profile.dart';
import 'key_store.dart';
import 'secure_storage.dart';

/// 新增或更新伺服器時一併寫入的機密資料；`null` 代表不變更。
class ServerSecrets {
  const ServerSecrets({this.password, this.proxyPassword});

  final String? password;
  final String? proxyPassword;
}

class ServerStore extends ChangeNotifier {
  ServerStore({FlutterSecureStorage? storage, this._keys})
    : _secureStorage = storage ?? secureStorage;

  static const _serversKey = 'mato.servers.v1';

  final List<ServerProfile> _servers = [];
  final FlutterSecureStorage _secureStorage;
  final KeyStore? _keys;
  bool _loaded = false;

  bool get loaded => _loaded;
  List<ServerProfile> get servers => List.unmodifiable(_servers);

  /// 所有非空的分組名稱（依字母排序）。
  List<String> get groups {
    final result = _servers
        .map((server) => server.group.trim())
        .where((group) => group.isNotEmpty)
        .toSet()
        .toList();
    result.sort();
    return result;
  }

  ServerProfile? byId(String id) =>
      _servers.where((server) => server.id == id).firstOrNull;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_serversKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _servers
          ..clear()
          ..addAll(
            list.whereType<Map<String, dynamic>>().map(ServerProfile.fromJson),
          );
      } catch (error) {
        debugPrint('無法讀取伺服器清單：$error');
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _serversKey,
      jsonEncode(_servers.map((server) => server.toJson()).toList()),
    );
  }

  Future<ServerProfile> addServer(
    ServerProfile profile, {
    ServerSecrets secrets = const ServerSecrets(),
  }) async {
    final stored = profile.copyWith(
      id: profile.id.isEmpty ? const Uuid().v4() : profile.id,
      createdAt: DateTime.now(),
    );
    await _writeSecrets(stored.id, secrets);
    _servers.add(_stripSecrets(stored));
    await _save();
    notifyListeners();
    return stored;
  }

  Future<void> updateServer(
    ServerProfile profile, {
    ServerSecrets secrets = const ServerSecrets(),
  }) async {
    final index = _servers.indexWhere((item) => item.id == profile.id);
    if (index < 0) return;
    await _writeSecrets(profile.id, secrets);
    _servers[index] = _stripSecrets(profile);
    await _save();
    notifyListeners();
  }

  /// 匯入備份時使用：保留原本的 id，已存在就覆蓋。
  Future<void> upsert(
    ServerProfile profile, {
    ServerSecrets secrets = const ServerSecrets(),
  }) async {
    final index = _servers.indexWhere((item) => item.id == profile.id);
    await _writeSecrets(profile.id, secrets);
    if (index < 0) {
      _servers.add(_stripSecrets(profile));
    } else {
      _servers[index] = _stripSecrets(profile);
    }
    await _save();
    notifyListeners();
  }

  Future<ServerProfile?> duplicate(String id) async {
    final source = byId(id);
    if (source == null) return null;
    return addServer(
      source.copyWith(id: '', name: '${source.name} 副本'),
      secrets: ServerSecrets(
        password: await getPassword(id),
        proxyPassword: await _secureStorage.read(key: _proxyKey(id)),
      ),
    );
  }

  Future<void> deleteServer(String id) async {
    _servers.removeWhere((server) => server.id == id);
    // 指向這台當跳板機的伺服器一併解除。
    for (var i = 0; i < _servers.length; i++) {
      if (_servers[i].jumpServerId == id) {
        _servers[i] = _servers[i].copyWith(clearJumpServer: true);
      }
    }
    await _secureStorage.delete(key: _passwordKey(id));
    await _secureStorage.delete(key: _proxyKey(id));
    await _save();
    notifyListeners();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _servers.length) return;
    final item = _servers.removeAt(oldIndex);
    _servers.insert(newIndex.clamp(0, _servers.length), item);
    await _save();
    notifyListeners();
  }

  Future<String?> getPassword(String id) {
    return _secureStorage.read(key: _passwordKey(id));
  }

  Future<String?> getProxyPassword(String id) {
    return _secureStorage.read(key: _proxyKey(id));
  }

  /// 取得可直接連線的設定：補上密碼、私鑰與跳板機（遞迴）。
  Future<ServerProfile> resolve(String id, {Set<String>? visiting}) async {
    final profile = byId(id);
    if (profile == null) throw StateError('找不到伺服器');
    final chain = visiting ?? <String>{};
    if (!chain.add(id)) throw StateError('跳板機設定形成迴圈');

    var privateKey = '';
    var passphrase = '';
    if (profile.authMethod == AuthMethod.privateKey && profile.keyId != null) {
      final secret = await _keys?.secretOf(profile.keyId!);
      privateKey = secret?.pem ?? '';
      passphrase = secret?.passphrase ?? '';
    }

    ServerProfile? jump;
    final jumpId = profile.jumpServerId;
    if (jumpId != null && byId(jumpId) != null) {
      jump = await resolve(jumpId, visiting: chain);
    }

    return profile.copyWith(
      password: await getPassword(id) ?? '',
      privateKey: privateKey,
      passphrase: passphrase,
      proxyPassword: profile.proxy == null
          ? ''
          : await getProxyPassword(id) ?? '',
      jump: jump,
    );
  }

  Future<void> _writeSecrets(String id, ServerSecrets secrets) async {
    if (secrets.password != null) {
      if (secrets.password!.isEmpty) {
        await _secureStorage.delete(key: _passwordKey(id));
      } else {
        await _secureStorage.write(
          key: _passwordKey(id),
          value: secrets.password,
        );
      }
    }
    if (secrets.proxyPassword != null) {
      await _secureStorage.write(
        key: _proxyKey(id),
        value: secrets.proxyPassword,
      );
    }
  }

  /// 清單只保留非機密欄位，避免機密留在記憶體中的長期物件裡。
  ServerProfile _stripSecrets(ServerProfile profile) =>
      ServerProfile.fromJson(profile.toJson());

  String _passwordKey(String id) => 'mato.password.$id';
  String _proxyKey(String id) => 'mato.proxyPassword.$id';
}
