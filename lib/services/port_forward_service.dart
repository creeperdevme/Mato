import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/port_forward.dart';
import '../models/server_profile.dart';
import '../utils/error_messages.dart';
import 'ssh_service.dart';

/// 執行中的轉發。
class ActiveForward {
  ActiveForward(this.rule, this._lease);

  final PortForwardRule rule;
  final SshLease _lease;
  final DateTime startedAt = DateTime.now();
  ServerSocket? _server;
  SSHDynamicForward? _dynamic;
  final Set<Socket> _sockets = {};
  int totalConnections = 0;

  int get openConnections => _sockets.length;
}

/// 連接埠轉發規則（持久化）與執行狀態。
class PortForwardService extends ChangeNotifier {
  static const _key = 'mato.forwards.v1';

  final List<PortForwardRule> _rules = [];
  final Map<String, ActiveForward> _active = {};
  final Map<String, String> _errors = {};
  final Set<String> _starting = {};

  List<PortForwardRule> rulesOf(String serverId) =>
      _rules.where((rule) => rule.serverId == serverId).toList();

  List<PortForwardRule> get rules => List.unmodifiable(_rules);

  ActiveForward? activeOf(String ruleId) => _active[ruleId];
  String? errorOf(String ruleId) => _errors[ruleId];
  bool isStarting(String ruleId) => _starting.contains(ruleId);

  int activeCount(String serverId) =>
      _active.values.where((item) => item.rule.serverId == serverId).length;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_key);
    if (raw == null) return;
    try {
      _rules
        ..clear()
        ..addAll(
          (jsonDecode(raw) as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map(PortForwardRule.fromJson),
        );
    } catch (error) {
      debugPrint('無法讀取轉發規則：$error');
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key,
      jsonEncode(_rules.map((rule) => rule.toJson()).toList()),
    );
  }

  Future<PortForwardRule> saveRule(PortForwardRule rule) async {
    final stored = rule.id.isEmpty
        ? PortForwardRule(
            id: const Uuid().v4(),
            serverId: rule.serverId,
            name: rule.name,
            kind: rule.kind,
            localPort: rule.localPort,
            bindAddress: rule.bindAddress,
            remoteHost: rule.remoteHost,
            remotePort: rule.remotePort,
            autoStart: rule.autoStart,
          )
        : rule;
    final index = _rules.indexWhere((item) => item.id == stored.id);
    if (index < 0) {
      _rules.add(stored);
    } else {
      _rules[index] = stored;
      // 設定改了就停掉舊的，讓使用者重新啟動。
      await stop(stored.id);
    }
    await _save();
    notifyListeners();
    return stored;
  }

  Future<void> deleteRule(String id) async {
    await stop(id);
    _rules.removeWhere((rule) => rule.id == id);
    _errors.remove(id);
    await _save();
    notifyListeners();
  }

  Future<void> start(
    PortForwardRule rule,
    ServerProfile profile,
    SSHService ssh,
  ) async {
    if (_active.containsKey(rule.id) || !_starting.add(rule.id)) return;
    _errors.remove(rule.id);
    notifyListeners();
    SshLease? lease;
    try {
      lease = await ssh.lease(profile);
      final active = ActiveForward(rule, lease);
      if (rule.kind == ForwardKind.dynamic) {
        active._dynamic = await lease.client.forwardDynamic(
          bindHost: rule.bindAddress,
          bindPort: rule.localPort,
        );
      } else {
        final server = await ServerSocket.bind(
          rule.bindAddress,
          rule.localPort,
        );
        active._server = server;
        server.listen((socket) => _accept(active, socket));
      }
      _active[rule.id] = active;
      unawaited(
        lease.done.then((_) {
          if (identical(_active[rule.id], active)) {
            _errors[rule.id] = 'SSH 連線中斷，轉發已停止';
            unawaited(stop(rule.id));
          }
        }),
      );
    } catch (error) {
      lease?.release();
      _errors[rule.id] = error is SocketException
          ? '無法監聽 ${rule.bindAddress}:${rule.localPort}（可能已被占用）'
          : describeSshError(error);
    } finally {
      _starting.remove(rule.id);
      notifyListeners();
    }
  }

  Future<void> _accept(ActiveForward active, Socket socket) async {
    active._sockets.add(socket);
    active.totalConnections++;
    notifyListeners();
    try {
      final channel = await active._lease.client.forwardLocal(
        active.rule.remoteHost,
        active.rule.remotePort,
      );
      final toRemote = socket
          .cast<List<int>>()
          .pipe(channel.sink)
          .catchError((_) {});
      final toLocal = channel.stream
          .cast<List<int>>()
          .pipe(socket)
          .catchError((_) {});
      await Future.wait([toRemote, toLocal]);
      channel.destroy();
    } catch (_) {
      // 遠端拒絕連線（例如目標連接埠沒開）時直接斷開本機這條。
    } finally {
      socket.destroy();
      active._sockets.remove(socket);
      notifyListeners();
    }
  }

  Future<void> stop(String ruleId) async {
    final active = _active.remove(ruleId);
    if (active == null) return;
    await active._server?.close();
    await active._dynamic?.close();
    for (final socket in active._sockets) {
      socket.destroy();
    }
    active._sockets.clear();
    active._lease.release();
    notifyListeners();
  }

  Future<void> stopAllFor(String serverId) async {
    for (final id in _active.keys.toList()) {
      if (_active[id]?.rule.serverId == serverId) await stop(id);
    }
  }

  /// 匯入備份時使用。
  Future<void> upsertRules(Iterable<PortForwardRule> rules) async {
    for (final rule in rules) {
      _rules.removeWhere((item) => item.id == rule.id);
      _rules.add(rule);
    }
    await _save();
    notifyListeners();
  }
}
