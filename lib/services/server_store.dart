import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/server_profile.dart';

class ServerStore extends ChangeNotifier {
  static const _serversKey = 'mato.servers.v1';

  final List<ServerProfile> _servers = [];
  final Map<String, ServerStatus> _statuses = {};
  final Map<String, String> _statusMessages = {};
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  List<ServerProfile> get servers => List.unmodifiable(_servers);
  ServerStatus statusOf(String id) => _statuses[id] ?? ServerStatus.unknown;
  String statusMessageOf(String id) => _statusMessages[id] ?? '';

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_serversKey);
    if (raw != null) {
      final list = jsonDecode(raw) as List<dynamic>;
      _servers
        ..clear()
        ..addAll(list.map((item) => ServerProfile.fromJson(item)));
      notifyListeners();
    }
  }

  Future<void> _save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _serversKey,
      jsonEncode(_servers.map((server) => server.toJson()).toList()),
    );
  }

  Future<void> addServer(ServerProfile profile) async {
    final storedProfile = ServerProfile(
      id: const Uuid().v4(),
      name: profile.name,
      host: profile.host,
      port: profile.port,
      username: profile.username,
      createdAt: DateTime.now(),
    );
    await _secureStorage.write(
      key: _passwordKey(storedProfile.id),
      value: profile.password,
    );
    _servers.add(storedProfile);
    await _save();
    notifyListeners();
  }

  Future<void> updateServer(ServerProfile profile, {String? password}) async {
    final index = _servers.indexWhere((item) => item.id == profile.id);
    if (index < 0) return;
    _servers[index] = profile;
    if (password != null && password.isNotEmpty) {
      await _secureStorage.write(
        key: _passwordKey(profile.id),
        value: password,
      );
    }
    await _save();
    notifyListeners();
  }

  Future<void> deleteServer(String id) async {
    _servers.removeWhere((server) => server.id == id);
    await _secureStorage.delete(key: _passwordKey(id));
    _statuses.remove(id);
    _statusMessages.remove(id);
    await _save();
    notifyListeners();
  }

  Future<String?> getPassword(String id) async {
    return _secureStorage.read(key: _passwordKey(id));
  }

  Future<void> refreshStatus(String id, Future<bool> Function() check) async {
    _statuses[id] = ServerStatus.checking;
    _statusMessages[id] = '連線測試中';
    notifyListeners();
    try {
      final online = await check();
      _statuses[id] = online ? ServerStatus.online : ServerStatus.offline;
      _statusMessages[id] = online ? 'SSH 連線正常' : 'SSH 回應異常';
    } catch (error) {
      final message = error.toString();
      _statuses[id] = message.contains('auth') || message.contains('password')
          ? ServerStatus.authFailed
          : ServerStatus.error;
      _statusMessages[id] = message;
    }
    notifyListeners();
  }

  String _passwordKey(String id) => 'mato.password.$id';
}
