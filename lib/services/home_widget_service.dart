import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/server_metrics.dart';
import '../models/server_profile.dart';
import '../utils/error_messages.dart';
import '../utils/format.dart';
import 'key_store.dart';
import 'known_hosts_store.dart';
import 'monitor_service.dart';
import 'server_store.dart';
import 'settings_store.dart';
import 'ssh_service.dart';

/// 和 Android 原生小工具溝通的通道（android/app/src/main/kotlin/me/creeperdev/
/// mato/widget/）。
const _channelName = 'me.creeperdev.mato/home_widget';

/// 主畫面小工具的種類，對應 Android 端的兩個 AppWidgetProvider。
enum HomeWidgetKind { overview, server }

/// 小工具上的一台伺服器。數字在這裡就格式化好，原生端只負責排版。
@immutable
class WidgetServer {
  const WidgetServer({
    required this.id,
    required this.name,
    this.status = ServerStatus.unknown,
    this.message = '',
    this.checkedAt,
    this.metrics,
  });

  factory WidgetServer.fromJson(Map<String, dynamic> json) {
    final checkedAt = json['checkedAt'];
    final metrics = json['metrics'];
    return WidgetServer(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      status:
          ServerStatus.values.asNameMap()[json['status']] ??
          ServerStatus.unknown,
      message: json['message'] as String? ?? '',
      checkedAt: checkedAt is int
          ? DateTime.fromMillisecondsSinceEpoch(checkedAt)
          : null,
      metrics: metrics is Map<String, dynamic>
          ? WidgetMetrics.fromJson(metrics)
          : null,
    );
  }

  factory WidgetServer.online(
    ServerProfile server,
    ServerMetrics metrics,
    DateTime checkedAt,
  ) => WidgetServer(
    id: server.id,
    name: server.name,
    status: ServerStatus.online,
    checkedAt: checkedAt,
    metrics: WidgetMetrics.from(metrics),
  );

  /// 連不上或取樣失敗：只留狀態與原因，不再顯示上一次的數字（和首頁卡片一致）。
  factory WidgetServer.failed(
    ServerProfile server,
    Object error,
    DateTime checkedAt,
  ) => WidgetServer(
    id: server.id,
    name: server.name,
    status: statusForError(error),
    message: describeSshError(error),
    checkedAt: checkedAt,
  );

  /// 監控服務目前的結果；這次開啟 App 後還沒檢查過時回傳 `null`。
  static WidgetServer? fromMonitor(
    ServerProfile server,
    ServerMonitor monitor,
  ) {
    final checkedAt = monitor.checkedAt;
    if (checkedAt == null) return null;
    final metrics = monitor.metrics;
    if (monitor.status == ServerStatus.online && metrics != null) {
      return WidgetServer.online(server, metrics, checkedAt);
    }
    return WidgetServer(
      id: server.id,
      name: server.name,
      status: monitor.status,
      message: monitor.statusMessage,
      checkedAt: checkedAt,
    );
  }

  final String id;
  final String name;
  final ServerStatus status;

  /// 不是線上時的原因，例如「連線逾時：…」。
  final String message;

  /// 最後一次檢查的時間，不論成功與否；合併新舊資料時以此判斷先後。
  final DateTime? checkedAt;

  /// 只有線上時才有。
  final WidgetMetrics? metrics;

  /// 是否比 [other] 新；沒有檢查時間的一律視為最舊。
  bool isNewerThan(WidgetServer other) {
    final mine = checkedAt;
    final theirs = other.checkedAt;
    if (mine == null) return false;
    return theirs == null || mine.isAfter(theirs);
  }

  WidgetServer _renamed(String value) => value == name
      ? this
      : WidgetServer(
          id: id,
          name: value,
          status: status,
          message: message,
          checkedAt: checkedAt,
          metrics: metrics,
        );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'status': status.name,
    if (message.isNotEmpty) 'message': message,
    if (checkedAt != null) 'checkedAt': checkedAt!.millisecondsSinceEpoch,
    if (metrics != null) 'metrics': metrics!.toJson(),
  };
}

/// 小工具顯示的指標。
@immutable
class WidgetMetrics {
  const WidgetMetrics({
    required this.cpu,
    required this.memory,
    required this.disk,
    this.rx = '',
    this.tx = '',
    this.load = '',
    this.uptime = '',
    this.os = '',
  });

  factory WidgetMetrics.from(ServerMetrics metrics) => WidgetMetrics(
    cpu: metrics.cpuPercent,
    memory: metrics.memPercent,
    disk: metrics.diskPercent,
    rx: formatRate(metrics.netRxRate),
    tx: formatRate(metrics.netTxRate),
    load: metrics.load1.toStringAsFixed(2),
    uptime: metrics.uptimeLabel ?? '',
    os: metrics.osName,
  );

  factory WidgetMetrics.fromJson(Map<String, dynamic> json) => WidgetMetrics(
    cpu: (json['cpu'] as num?)?.toDouble() ?? 0,
    memory: (json['memory'] as num?)?.toDouble() ?? 0,
    disk: (json['disk'] as num?)?.toDouble() ?? 0,
    rx: json['rx'] as String? ?? '',
    tx: json['tx'] as String? ?? '',
    load: json['load'] as String? ?? '',
    uptime: json['uptime'] as String? ?? '',
    os: json['os'] as String? ?? '',
  );

  /// 使用率（0–100）。
  final double cpu;
  final double memory;
  final double disk;

  /// 例：`1.2 MB/s`。
  final String rx;
  final String tx;

  /// 一分鐘平均負載，例：`0.42`。
  final String load;

  /// 例：`12 天 4 小時`。
  final String uptime;

  /// 例：`Ubuntu 24.04.1 LTS`。
  final String os;

  Map<String, dynamic> toJson() => {
    'cpu': _percent(cpu),
    'memory': _percent(memory),
    'disk': _percent(disk),
    'rx': rx,
    'tx': tx,
    'load': load,
    if (uptime.isNotEmpty) 'uptime': uptime,
    if (os.isNotEmpty) 'os': os,
  };

  /// 取到小數一位；jsonEncode 遇到 NaN 會丟出例外。
  static double _percent(double value) =>
      value.isFinite ? (value.clamp(0, 100) * 10).roundToDouble() / 10 : 0;
}

/// 寫給 Android 小工具的完整資料，依伺服器清單的順序排列。
@immutable
class WidgetSnapshot {
  const WidgetSnapshot({this.servers = const [], this.refreshMinutes = 30});

  /// 原生端存的 JSON；沒有資料或格式不對時回傳空的。
  factory WidgetSnapshot.decode(String? raw) {
    if (raw == null || raw.isEmpty) return const WidgetSnapshot();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return WidgetSnapshot(
        servers: [
          for (final item in json['servers'] as List<dynamic>? ?? const [])
            if (item is Map<String, dynamic>) WidgetServer.fromJson(item),
        ],
        refreshMinutes: json['refreshMinutes'] as int? ?? 30,
      );
    } catch (error) {
      debugPrint('無法讀取小工具資料：$error');
      return const WidgetSnapshot();
    }
  }

  final List<WidgetServer> servers;

  /// 背景更新的間隔（見 [SettingsStore.widgetRefreshMinutes]），原生端依此排程。
  final int refreshMinutes;

  WidgetServer? byId(String id) =>
      servers.where((server) => server.id == id).firstOrNull;

  String encode() => jsonEncode({
    'refreshMinutes': refreshMinutes,
    'servers': [for (final server in servers) server.toJson()],
  });

  /// 依目前的伺服器清單重建：順序與名稱以清單為準，已刪除的伺服器移除；
  /// 同一台有新舊兩份資料時，留下比較晚檢查的那份。
  WidgetSnapshot merge(
    List<ServerProfile> list, {
    Iterable<WidgetServer> fresh = const [],
    int? refreshMinutes,
  }) {
    final known = {for (final server in servers) server.id: server};
    for (final server in fresh) {
      final old = known[server.id];
      if (old == null || server.isNewerThan(old)) known[server.id] = server;
    }
    return WidgetSnapshot(
      servers: [
        for (final server in list)
          known[server.id]?._renamed(server.name) ??
              WidgetServer(id: server.id, name: server.name),
      ],
      refreshMinutes: refreshMinutes ?? this.refreshMinutes,
    );
  }
}

/// 小工具點擊帶來的網址：`mato://server/<id>` 打開那台伺服器，其他的只是
/// 開啟 App。
@visibleForTesting
String? serverIdFromLaunch(String? raw) {
  final uri = raw == null ? null : Uri.tryParse(raw);
  if (uri == null || uri.scheme != 'mato' || uri.host != 'server') return null;
  final segments = uri.pathSegments;
  return segments.isEmpty || segments.first.isEmpty ? null : segments.first;
}

/// Android 主畫面小工具的資料來源。
///
/// App 開著時把監控結果同步給原生小工具。小工具只有回到桌面才看得到，所以
/// 平常最多每 [syncInterval] 寫一次，App 進入背景時再立刻寫一次；App 沒開
/// 時，原生端依設定的間隔啟動 [homeWidgetRefreshMain] 在背景更新。
class HomeWidgetService with WidgetsBindingObserver {
  HomeWidgetService({
    required this._monitor,
    required this._servers,
    required this._settings,
    bool? supported,
    @visibleForTesting this._channel = const MethodChannel(_channelName),
  }) : supported = supported ?? (!kIsWeb && Platform.isAndroid);

  static const syncInterval = Duration(seconds: 30);

  /// 伺服器清單或設定改變後稍等一下再寫，讓連續的變更合併成一次。
  static const _debounce = Duration(milliseconds: 500);

  final MonitorService _monitor;
  final ServerStore _servers;
  final SettingsStore _settings;
  final MethodChannel _channel;

  /// 目前只有 Android 有主畫面小工具。
  final bool supported;

  final _opens = StreamController<String>.broadcast();
  String? _pendingOpen;
  Timer? _timer;
  DateTime? _lastSync;
  int? _syncedRefreshMinutes;
  bool _started = false;
  bool _background = false;

  /// App 已經開著時，使用者在小工具上點了某台伺服器。
  Stream<String> get openRequests => _opens.stream;

  /// App 畫面出現前就收到的點擊（從小工具冷啟動），只會回傳一次。
  String? takePendingOpen() {
    final id = _pendingOpen;
    _pendingOpen = null;
    return id;
  }

  Future<void> start() async {
    if (!supported || _started) return;
    _started = true;
    _channel.setMethodCallHandler(_handleCall);
    WidgetsBinding.instance.addObserver(this);
    _monitor.addListener(_onMonitor);
    _servers.addListener(_onChanged);
    _settings.addListener(_onSettings);
    // 伺服器名稱、清單或設定可能在 App 關閉期間改過（例如還原備份）。
    _schedule(soon: true);
    await _takeLaunch();
  }

  void dispose() {
    _timer?.cancel();
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      _monitor.removeListener(_onMonitor);
      _servers.removeListener(_onChanged);
      _settings.removeListener(_onSettings);
      _channel.setMethodCallHandler(null);
    }
    unawaited(_opens.close());
  }

  /// 請桌面加入小工具；[serverId] 是單台伺服器小工具要顯示的那台。桌面不支援
  /// 從 App 加入時回傳 false。
  Future<bool> requestPin(HomeWidgetKind kind, {String? serverId}) async {
    if (!supported) return false;
    try {
      final accepted = await _channel.invokeMethod<bool>('pin', {
        'kind': kind.name,
        'serverId': ?serverId,
      });
      return accepted ?? false;
    } catch (error) {
      debugPrint('無法加入小工具：$error');
      return false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden) {
      // 回到桌面就看得到小工具，趁現在寫入最新的資料。
      _background = true;
      unawaited(_sync());
    } else if (state == AppLifecycleState.resumed) {
      _background = false;
    }
  }

  // 離開 App 時還在進行的那次更新，完成後馬上寫入，不必等節流。
  void _onMonitor() => _schedule(soon: _background);

  void _onChanged() => _schedule(soon: true);

  void _onSettings() {
    if (_settings.widgetRefreshMinutes != _syncedRefreshMinutes) {
      _schedule(soon: true);
    }
  }

  /// 監控結果最多每 [syncInterval] 寫一次；[soon] 用於清單或設定改變，
  /// 稍等 [_debounce] 就寫。
  void _schedule({bool soon = false}) {
    final timer = _timer;
    if (timer != null && timer.isActive) {
      if (!soon) return;
      timer.cancel();
    }
    var wait = _debounce;
    final last = _lastSync;
    if (!soon && last != null) {
      final remaining = syncInterval - DateTime.now().difference(last);
      if (remaining > wait) wait = remaining;
    }
    _timer = Timer(wait, () => unawaited(_sync()));
  }

  Future<void> _sync() async {
    _timer?.cancel();
    _lastSync = DateTime.now();
    final refreshMinutes = _settings.widgetRefreshMinutes;
    try {
      // 背景更新可能在 App 開著時寫入了更新的資料，每次都以原生端存的為準再合併。
      final stored = WidgetSnapshot.decode(
        await _channel.invokeMethod<String>('load'),
      );
      final servers = _servers.servers;
      final fresh = <WidgetServer>[];
      for (final server in servers) {
        final state = WidgetServer.fromMonitor(
          server,
          _monitor.monitorOf(server.id),
        );
        if (state != null) fresh.add(state);
      }
      final snapshot = stored.merge(
        servers,
        fresh: fresh,
        refreshMinutes: refreshMinutes,
      );
      await _channel.invokeMethod<void>('save', snapshot.encode());
      _syncedRefreshMinutes = refreshMinutes;
    } catch (error) {
      debugPrint('無法更新主畫面小工具：$error');
    }
  }

  Future<Object?> _handleCall(MethodCall call) async {
    if (call.method == 'launchPending') await _takeLaunch();
    return null;
  }

  Future<void> _takeLaunch() async {
    try {
      final id = serverIdFromLaunch(
        await _channel.invokeMethod<String>('takeLaunch'),
      );
      if (id == null) return;
      if (_opens.hasListener) {
        _opens.add(id);
      } else {
        _pendingOpen = id;
      }
    } catch (error) {
      debugPrint('無法讀取小工具的點擊：$error');
    }
  }
}

/// 原生端在背景啟動的進入點（見 WidgetRefresher.kt）：替主畫面上的小工具
/// 抓取指標並寫回，完成後通知原生端關閉這個 Flutter 引擎。
@pragma('vm:entry-point')
Future<void> homeWidgetRefreshMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  const channel = MethodChannel(_channelName);
  try {
    final request =
        await channel.invokeMapMethod<String, Object?>('refreshRequest') ??
        const {};
    final keys = KeyStore();
    final servers = ServerStore(keys: keys);
    final knownHosts = KnownHostsStore();
    await Future.wait([keys.load(), servers.load(), knownHosts.load()]);
    // 背景沒有畫面，需要詢問使用者（2FA、主機金鑰改變）的伺服器一律視為失敗。
    final ssh = SSHService(knownHosts: knownHosts);
    try {
      final snapshot = await refreshWidgetSnapshot(
        previous: WidgetSnapshot.decode(
          await channel.invokeMethod<String>('load'),
        ),
        servers: servers,
        ssh: ssh,
        serverIds: (request['serverIds'] as List<Object?>? ?? const [])
            .whereType<String>(),
        overviewRows: request['overviewRows'] as int? ?? 0,
        manual: request['manual'] as bool? ?? false,
      );
      await channel.invokeMethod<void>('save', snapshot.encode());
    } finally {
      ssh.disconnectAll();
    }
  } catch (error, stackTrace) {
    debugPrint('小工具背景更新失敗：$error\n$stackTrace');
  } finally {
    try {
      await channel.invokeMethod<void>('refreshDone');
    } catch (_) {
      // 原生端已經因逾時關閉引擎。
    }
  }
}

/// 抓取小工具上那些伺服器的最新指標，和 [previous] 合併成新的資料。
///
/// 要更新的是單台伺服器小工具顯示的 [serverIds]，加上伺服器總覽看得到的前
/// [overviewRows] 台。定時更新（[manual] 為 false）時略過剛檢查過與上次驗證
/// 失敗的伺服器：前者不必重抓；後者在背景無法詢問使用者，重試只會一直失敗。
@visibleForTesting
Future<WidgetSnapshot> refreshWidgetSnapshot({
  required WidgetSnapshot previous,
  required ServerStore servers,
  required SSHService ssh,
  Iterable<String> serverIds = const [],
  int overviewRows = 0,
  bool manual = false,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final list = servers.servers;
  final wanted = {
    ...serverIds,
    for (final server in list.take(overviewRows)) server.id,
  };
  final now = DateTime.now();
  final fresh = Duration(minutes: previous.refreshMinutes) ~/ 2;
  bool due(WidgetServer? last) {
    if (manual || last == null) return true;
    if (last.status == ServerStatus.authFailed) return false;
    final checkedAt = last.checkedAt;
    return checkedAt == null || now.difference(checkedAt) >= fresh;
  }

  final results = await Future.wait([
    for (final server in list)
      if (wanted.contains(server.id) && due(previous.byId(server.id)))
        _checkServer(server, servers, ssh, timeout),
  ]);
  return previous.merge(list, fresh: results);
}

Future<WidgetServer> _checkServer(
  ServerProfile server,
  ServerStore store,
  SSHService ssh,
  Duration timeout,
) async {
  final checkedAt = DateTime.now();
  try {
    final profile = await store.resolve(server.id);
    if (profile.authMethod == AuthMethod.password && profile.password.isEmpty) {
      return WidgetServer(
        id: server.id,
        name: server.name,
        status: ServerStatus.authFailed,
        message: '沒有儲存密碼，請在 App 中連線。',
        checkedAt: checkedAt,
      );
    }
    final metrics = await ssh.fetchMetrics(profile).timeout(timeout);
    return WidgetServer.online(server, metrics, checkedAt);
  } catch (error) {
    return WidgetServer.failed(server, error, checkedAt);
  }
}
