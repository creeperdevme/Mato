import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/script.dart';
import '../models/server_profile.dart';
import '../utils/error_messages.dart';
import 'ssh_service.dart';

/// 腳本庫與批次執行紀錄。
class ScriptStore extends ChangeNotifier {
  static const _scriptsKey = 'mato.scripts.v1';
  static const _runsKey = 'mato.scriptRuns.v1';
  static const _maxRuns = 40;
  static const _maxOutputChars = 200000;
  static const _maxStoredOutputChars = 40000;

  final List<Script> _scripts = [];
  final List<ScriptRun> _runs = [];

  List<Script> get scripts => List.unmodifiable(_scripts);

  /// 新的在前。
  List<ScriptRun> get runs => List.unmodifiable(_runs);

  Script? byId(String id) =>
      _scripts.where((script) => script.id == id).firstOrNull;
  ScriptRun? runById(String id) =>
      _runs.where((run) => run.id == id).firstOrNull;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    try {
      final rawScripts = preferences.getString(_scriptsKey);
      if (rawScripts != null) {
        _scripts
          ..clear()
          ..addAll(
            (jsonDecode(rawScripts) as List<dynamic>)
                .whereType<Map<String, dynamic>>()
                .map(Script.fromJson),
          );
      }
      final rawRuns = preferences.getString(_runsKey);
      if (rawRuns != null) {
        _runs
          ..clear()
          ..addAll(
            (jsonDecode(rawRuns) as List<dynamic>)
                .whereType<Map<String, dynamic>>()
                .map(ScriptRun.fromJson),
          );
      }
    } catch (error) {
      debugPrint('無法讀取腳本：$error');
    }
    notifyListeners();
  }

  Future<void> _saveScripts() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _scriptsKey,
      jsonEncode(_scripts.map((script) => script.toJson()).toList()),
    );
  }

  Future<void> _saveRuns() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = _runs.where((run) => run.finished).map((run) {
      final json = run.toJson();
      // 輸出只保留尾端，避免偏好設定檔過大。
      for (final result in json['results'] as List<dynamic>) {
        final map = result as Map<String, dynamic>;
        final output = map['output'] as String;
        if (output.length > _maxStoredOutputChars) {
          map['output'] =
              '…\n${output.substring(output.length - _maxStoredOutputChars)}';
        }
      }
      return json;
    }).toList();
    await preferences.setString(_runsKey, jsonEncode(encoded));
  }

  Future<Script> save(Script script) async {
    final index = _scripts.indexWhere((item) => item.id == script.id);
    final stored = script.id.isEmpty
        ? Script(
            id: const Uuid().v4(),
            name: script.name,
            content: script.content,
            description: script.description,
            useSudo: script.useSudo,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          )
        : script.copyWith(updatedAt: DateTime.now());
    if (index < 0) {
      _scripts.add(stored);
    } else {
      _scripts[index] = stored;
    }
    await _saveScripts();
    notifyListeners();
    return stored;
  }

  Future<void> delete(String id) async {
    _scripts.removeWhere((script) => script.id == id);
    await _saveScripts();
    notifyListeners();
  }

  Future<void> deleteRun(String id) async {
    _runs.removeWhere((run) => run.id == id);
    await _saveRuns();
    notifyListeners();
  }

  Future<void> clearRuns() async {
    _runs.removeWhere((run) => run.finished);
    await _saveRuns();
    notifyListeners();
  }

  Future<void> seedExamples() async {
    final now = DateTime.now();
    Script example(String name, String content, {bool sudo = false}) => Script(
      id: const Uuid().v4(),
      name: name,
      content: content,
      useSudo: sudo,
      createdAt: now,
      updatedAt: now,
    );
    _scripts.addAll([
      example('系統概況', 'uname -a\nuptime\nfree -h\ndf -h /'),
      example(
        '更新套件（APT）',
        'export DEBIAN_FRONTEND=noninteractive\n'
            'apt-get update && apt-get -y upgrade',
        sudo: true,
      ),
      example('檢查失敗的服務', 'systemctl --failed --no-pager'),
      example('家目錄用量前 10 名', 'du -xhd1 ~ 2>/dev/null | sort -rh | head -n 10'),
      example('清理 Docker', 'docker system prune -f', sudo: true),
    ]);
    await _saveScripts();
    notifyListeners();
  }

  /// 在多台伺服器上同時執行（最多 [concurrency] 台並行），立即回傳紀錄，
  /// 結果會陸續更新。
  ScriptRun startRun({
    required String name,
    required String content,
    required bool sudo,
    required List<ServerProfile> targets,
    required Future<ServerProfile> Function(String id) resolve,
    required SSHService ssh,
    int concurrency = 4,
  }) {
    final run = ScriptRun(
      id: const Uuid().v4(),
      scriptName: name,
      content: content,
      sudo: sudo,
      startedAt: DateTime.now(),
      results: [
        for (final target in targets)
          ScriptRunResult(serverId: target.id, serverName: target.name),
      ],
    );
    _runs.insert(0, run);
    if (_runs.length > _maxRuns) _runs.removeRange(_maxRuns, _runs.length);
    notifyListeners();

    final queue = List.of(run.results);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final result = queue.removeAt(0);
        await _runOne(run, result, resolve, ssh);
      }
    }

    unawaited(
      Future.wait([
        for (var i = 0; i < concurrency.clamp(1, targets.length); i++) worker(),
      ]).whenComplete(() async {
        run.finishedAt = DateTime.now();
        notifyListeners();
        await _saveRuns();
      }),
    );
    return run;
  }

  Future<void> _runOne(
    ScriptRun run,
    ScriptRunResult result,
    Future<ServerProfile> Function(String id) resolve,
    SSHService ssh,
  ) async {
    final stopwatch = Stopwatch()..start();
    result.state = ScriptResultState.running;
    notifyListeners();
    try {
      final profile = await resolve(result.serverId);
      final process = await ssh.startScript(
        profile,
        run.content,
        sudo: run.sudo,
      );
      final buffer = StringBuffer();
      var lastNotify = DateTime.now();
      await for (final chunk in process.output) {
        if (buffer.length < _maxOutputChars) buffer.write(chunk);
        result.output = buffer.toString();
        final now = DateTime.now();
        if (now.difference(lastNotify) > const Duration(milliseconds: 250)) {
          lastNotify = now;
          notifyListeners();
        }
      }
      result.output = buffer.toString();
      result.exitCode = await process.exitCode;
      result.state = result.exitCode == 0
          ? ScriptResultState.success
          : ScriptResultState.failed;
      if (result.exitCode == null) result.error = '連線中斷，未取得結束代碼';
    } catch (error) {
      result.state = ScriptResultState.failed;
      result.error = describeSshError(error);
    } finally {
      result.duration = stopwatch.elapsed;
      notifyListeners();
    }
  }
}
