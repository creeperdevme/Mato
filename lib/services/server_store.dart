import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
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

  /// 伺服器自訂圖示的儲存區（應用程式支援目錄下的 server_icons）。
  /// 建立失敗（例如測試環境沒有 path_provider）時為 null，自訂圖示停用。
  Directory? _iconsDir;

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
    // 圖示儲存區若已經備妥（啟動時與 load 並行建立），補做一次孤兒檔清理。
    await _deleteOrphanIconsIfLoaded();
  }

  // 自訂圖示儲存區 -------------------------------------------------------------

  /// 建立自訂圖示儲存區；由啟動流程（`main`）呼叫。
  ///
  /// 刻意不放進 [load]：`getApplicationSupportDirectory` 是平台通道呼叫，
  /// 在 widget 測試的 fake async 環境中不會完成，會讓 `load()` 永遠等下去。
  Future<void> initIconStorage() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/server_icons');
      await dir.create(recursive: true);
      _iconsDir = dir;
      await _deleteOrphanIconsIfLoaded();
    } catch (error) {
      // 測試環境或特殊平台拿不到支援目錄：自訂圖示停用，其他功能照常。
      debugPrint('無法建立圖示儲存區：$error');
      _iconsDir = null;
    }
  }

  /// 清掉沒被引用的圖示檔，但只在伺服器清單載入完成後才動手。
  ///
  /// [load] 還沒跑完時 `_servers` 是空的，這時候清會把使用者所有自訂圖示
  /// 都當成孤兒刪掉（啟動時 `load` 與 [initIconStorage] 是並行執行的）。
  Future<void> _deleteOrphanIconsIfLoaded() async {
    if (!_loaded) return;
    await _deleteOrphanIcons();
  }

  /// [name]（[ServerProfile.iconName]）對應的完整路徑；沒有時回傳 null。
  String? iconPathOf(String name) => switch ((_iconsDir, name)) {
    (Directory dir, String n) when n.isNotEmpty => '${dir.path}/$n',
    _ => null,
  };

  /// 把使用者挑的圖片寫進儲存區，回傳可存進 [ServerProfile.iconName] 的檔名；
  /// [previous] 是原本的檔名，換圖時會順手刪掉舊檔。
  Future<String> writeIcon(
    Uint8List bytes, {
    String extension = '',
    String previous = '',
  }) async {
    final dir = _iconsDir;
    if (dir == null) throw StateError('圖示儲存區無法使用');
    final safeExt = _safeExtension(extension);
    final name = const Uuid().v4() + safeExt;
    await File('${dir.path}/$name').writeAsBytes(bytes, flush: true);
    await _deleteIconFile(previous);
    return name;
  }

  /// 刪掉某個自訂圖示（例如使用者在表單裡按「移除」）。
  Future<void> clearIcon(String name) => _deleteIconFile(name);

  Future<Uint8List?> _readIcon(String name) async {
    final dir = _iconsDir;
    if (dir == null || name.isEmpty) return null;
    try {
      return await File('${dir.path}/$name').readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteIconFile(String name) async {
    final dir = _iconsDir;
    if (dir == null || name.isEmpty) return;
    try {
      final file = File('${dir.path}/$name');
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('無法刪除自訂圖示 $name：$error');
    }
  }

  /// 清掉沒有任何伺服器引用的圖片檔（換圖未儲存、刪除伺服器等遺留的）。
  Future<void> _deleteOrphanIcons() async {
    final dir = _iconsDir;
    if (dir == null) return;
    try {
      final referenced = _servers
          .map((server) => server.iconName)
          .where((name) => name.isNotEmpty)
          .toSet();
      await for (final entity in dir.list()) {
        if (entity is File && !referenced.contains(entity.uri.pathSegments.last)) {
          await entity.delete();
        }
      }
    } catch (error) {
      debugPrint('清理圖示儲存區失敗：$error');
    }
  }

  /// 副檔名只留英數字，其他（路徑、特殊字元）一律換成 .img，避免寫到別的位置。
  String _safeExtension(String extension) {
    final raw = extension.trim().toLowerCase();
    if (raw.isEmpty) return '';
    final allowed = raw == '.jpg' ||
        raw == '.jpeg' ||
        raw == '.png' ||
        raw == '.gif' ||
        raw == '.webp' ||
        raw == '.bmp' ||
        raw == '.heic';
    if (allowed) return raw;
    final bare = raw.startsWith('.') ? raw.substring(1) : raw;
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(bare) ? '.$bare' : '.img';
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
    final previousIcon = _servers[index].iconName;
    _servers[index] = _stripSecrets(profile);
    await _save();
    // 換圖或移除圖示後，清掉已經沒有伺服器引用的舊檔。
    if (previousIcon.isNotEmpty && previousIcon != profile.iconName) {
      if (!_servers.any((server) => server.iconName == previousIcon)) {
        await _deleteIconFile(previousIcon);
      }
    }
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
    // 複製一份自訂圖示，刪掉其中一台時才不會把共用的圖檔刪掉。
    var iconName = source.iconName;
    if (iconName.isNotEmpty) {
      final bytes = await _readIcon(iconName);
      iconName = bytes == null ? '' : await writeIcon(bytes);
    }
    return addServer(
      source.copyWith(id: '', name: '${source.name} 副本', iconName: iconName),
      secrets: ServerSecrets(
        password: await getPassword(id),
        proxyPassword: await _secureStorage.read(key: _proxyKey(id)),
      ),
    );
  }

  Future<void> deleteServer(String id) async {
    final icon = byId(id)?.iconName ?? '';
    _servers.removeWhere((server) => server.id == id);
    // 指向這台當跳板機的伺服器一併解除。
    for (var i = 0; i < _servers.length; i++) {
      if (_servers[i].jumpServerId == id) {
        _servers[i] = _servers[i].copyWith(clearJumpServer: true);
      }
    }
    await _secureStorage.delete(key: _passwordKey(id));
    await _secureStorage.delete(key: _proxyKey(id));
    // 自訂圖示沒有其他伺服器共用時一併刪除。
    if (icon.isNotEmpty && !_servers.any((server) => server.iconName == icon)) {
      await _deleteIconFile(icon);
    }
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
