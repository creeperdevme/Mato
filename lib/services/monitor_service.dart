import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../models/server_metrics.dart';
import '../models/server_profile.dart';
import '../utils/error_messages.dart';
import 'server_store.dart';
import 'settings_store.dart';
import 'ssh_service.dart';

/// 一次取樣的時間序列資料點。
class MetricsSample {
  const MetricsSample({
    required this.time,
    required this.cpu,
    required this.memory,
    required this.netRx,
    required this.netTx,
    required this.diskRead,
    required this.diskWrite,
    this.interfaces = const {},
  });

  final DateTime time;
  final double cpu;
  final double memory;
  final double netRx;
  final double netTx;
  final double diskRead;
  final double diskWrite;

  /// 介面名稱 → (下載, 上傳) bytes/s。
  final Map<String, (double, double)> interfaces;
}

/// 單台伺服器的最新狀態與歷史。
class ServerMonitor extends ChangeNotifier {
  ServerMonitor(this.serverId);

  static const maxSamples = 120;

  final String serverId;
  ServerMetrics? metrics;
  DateTime? updatedAt;
  String? error;
  ServerStatus status = ServerStatus.unknown;
  String statusMessage = '';
  bool loading = false;
  final List<MetricsSample> history = [];

  void _record(ServerMetrics value) {
    metrics = value;
    updatedAt = DateTime.now();
    error = null;
    status = ServerStatus.online;
    statusMessage = 'SSH 連線正常';
    history.add(
      MetricsSample(
        time: updatedAt!,
        cpu: value.cpuPercent,
        memory: value.memPercent,
        netRx: value.netRxRate,
        netTx: value.netTxRate,
        diskRead: value.diskReadRate,
        diskWrite: value.diskWriteRate,
        interfaces: {
          for (final item in value.netInterfaces)
            item.name: (item.rxRate, item.txRate),
        },
      ),
    );
    if (history.length > maxSamples) {
      history.removeRange(0, history.length - maxSamples);
    }
  }

  void _fail(Object value) {
    error = describeSshError(value);
    statusMessage = error!;
    if (isAuthError(value)) {
      status = ServerStatus.authFailed;
    } else {
      final lower = value.toString().toLowerCase();
      final unreachable = [
        'timed out',
        'timeout',
        'refused',
        'unreachable',
        'no route',
        'host lookup',
        'errno',
      ].any(lower.contains);
      status = unreachable ? ServerStatus.offline : ServerStatus.error;
    }
  }

  void _notify() => notifyListeners();
}

/// 定期抓取伺服器指標。各畫面以 [watch]／[unwatch] 表達「我正在看這台」，
/// 沒人看的伺服器不輪詢；App 進入背景時全部暫停。
class MonitorService extends ChangeNotifier with WidgetsBindingObserver {
  MonitorService({
    required this._ssh,
    required this._store,
    required this._settings,
  }) {
    WidgetsBinding.instance.addObserver(this);
  }

  final SSHService _ssh;
  final ServerStore _store;
  final SettingsStore _settings;
  final Map<String, ServerMonitor> _monitors = {};
  final Map<String, Map<Object, Duration?>> _watchers = {};
  final Map<String, Timer> _timers = {};
  final Set<String> _inFlight = {};
  bool _paused = false;

  ServerMonitor monitorOf(String serverId) =>
      _monitors.putIfAbsent(serverId, () => ServerMonitor(serverId));

  ServerStatus statusOf(String serverId) =>
      _monitors[serverId]?.status ?? ServerStatus.unknown;

  /// 開始（或持續）監看；[interval] 為 null 時用設定中的間隔。
  ///
  /// [interactive] 時第一次更新允許詢問使用者（2FA 驗證碼、主機金鑰變更），
  /// 適合使用者主動打開伺服器頁面的情況。
  void watch(
    String serverId,
    Object owner, {
    Duration? interval,
    bool interactive = false,
  }) {
    final owners = _watchers.putIfAbsent(serverId, () => {});
    final isNew = owners.isEmpty;
    owners[owner] = interval;
    if (isNew) {
      unawaited(_tick(serverId, interactive: interactive));
    } else if (interactive && statusOf(serverId) != ServerStatus.online) {
      unawaited(refresh(serverId, interactive: true));
    }
  }

  void unwatch(String serverId, Object owner) {
    final owners = _watchers[serverId];
    if (owners == null) return;
    owners.remove(owner);
    if (owners.isEmpty) {
      _watchers.remove(serverId);
      _timers.remove(serverId)?.cancel();
    }
  }

  /// 立即更新一次；[interactive] 時若需要 2FA 或確認主機金鑰會詢問使用者。
  Future<void> refresh(String serverId, {bool interactive = false}) async {
    if (_inFlight.contains(serverId)) return;
    final monitor = monitorOf(serverId);
    _inFlight.add(serverId);
    monitor.loading = true;
    if (monitor.status == ServerStatus.unknown) {
      monitor.status = ServerStatus.checking;
      monitor.statusMessage = '連線中';
    }
    monitor._notify();
    try {
      final profile = await _store.resolve(serverId);
      final metrics = await _ssh.fetchMetrics(
        profile,
        interactive: interactive,
      );
      monitor._record(metrics);
    } catch (error) {
      monitor._fail(error);
    } finally {
      _inFlight.remove(serverId);
      monitor.loading = false;
      monitor._notify();
      notifyListeners();
    }
  }

  Future<void> _tick(String serverId, {bool interactive = false}) async {
    _timers.remove(serverId)?.cancel();
    if (_paused || !_watchers.containsKey(serverId)) return;
    if (_store.byId(serverId) == null) return;
    await refresh(serverId, interactive: interactive);
    if (_paused || !_watchers.containsKey(serverId)) return;
    final monitor = monitorOf(serverId);
    // 連不上的主機放慢重試，避免一直卡在逾時。
    final failing =
        monitor.status == ServerStatus.offline ||
        monitor.status == ServerStatus.authFailed;
    final delay = failing
        ? Duration(seconds: math.max(30, _intervalFor(serverId).inSeconds))
        : _intervalFor(serverId);
    _timers[serverId] = Timer(delay, () => _tick(serverId));
  }

  Duration _intervalFor(String serverId) {
    final fallback = Duration(seconds: _settings.monitorInterval);
    final owners = _watchers[serverId];
    if (owners == null || owners.isEmpty) return fallback;
    return owners.values
        .map((value) => value ?? fallback)
        .reduce((a, b) => a < b ? a : b);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final background =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    if (background && !_paused) {
      _paused = true;
      for (final timer in _timers.values) {
        timer.cancel();
      }
      _timers.clear();
    } else if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      for (final serverId in _watchers.keys.toList()) {
        unawaited(_tick(serverId));
      }
    }
  }

  /// 伺服器被刪除時清掉狀態。
  void forget(String serverId) {
    _timers.remove(serverId)?.cancel();
    _watchers.remove(serverId);
    _monitors.remove(serverId)?.dispose();
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final timer in _timers.values) {
      timer.cancel();
    }
    super.dispose();
  }
}
