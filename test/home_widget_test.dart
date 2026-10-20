import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/server_metrics.dart';
import 'package:mato/models/server_profile.dart';
import 'package:mato/services/home_widget_service.dart';
import 'package:mato/services/monitor_service.dart';
import 'package:mato/services/server_store.dart';
import 'package:mato/services/settings_store.dart';
import 'package:mato/services/ssh_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

final _metrics = ServerMetrics(
  osName: 'Ubuntu 24.04.1 LTS',
  osId: 'ubuntu',
  kernel: '6.8.0-45-generic',
  hostname: 'web-01',
  uptime: const Duration(days: 11, hours: 10),
  bootTime: '2026-10-09 08:00:00',
  load1: 1.42,
  load5: 1.05,
  load15: 0.88,
  cores: 8,
  cpuPercent: 42.44,
  memTotalBytes: 32 << 30,
  memAvailableBytes: 12 << 30,
  swapTotalBytes: 0,
  swapFreeBytes: 0,
  diskTotalBytes: 100 << 30,
  diskUsedBytes: 78 << 30,
  raw: '',
);

/// 記錄抓了哪些伺服器；[failures] 裡的伺服器丟出對應的例外。
class _Ssh extends SSHService {
  final fetched = <String>[];
  final failures = <String, Object>{};
  Duration delay = Duration.zero;

  @override
  Future<ServerMetrics> fetchMetrics(
    ServerProfile profile, {
    bool interactive = false,
  }) async {
    fetched.add(profile.id);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final failure = failures[profile.id];
    if (failure != null) throw failure;
    return _metrics;
  }
}

/// 模擬 Android 端的通道，記下每次寫入的資料。
class _NativeWidgets {
  _NativeWidgets(this._tester) {
    _tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'load':
          return stored;
        case 'save':
          stored = call.arguments as String;
          saves.add(stored!);
        case 'takeLaunch':
          final value = launch;
          launch = null;
          return value;
        case 'pin':
          pins.add(Map<String, Object?>.from(call.arguments as Map));
          return true;
      }
      return null;
    });
  }

  static const channel = MethodChannel('test/home_widget');

  final WidgetTester _tester;
  String? stored;
  String? launch;
  final saves = <String>[];
  final pins = <Map<String, Object?>>[];

  WidgetSnapshot get last => WidgetSnapshot.decode(saves.last);

  /// 模擬使用者在 App 開著時點了小工具。
  Future<void> tap(String uri) async {
    launch = uri;
    await _tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('launchPending'),
      ),
      (_) {},
    );
  }
}

Future<ServerStore> _servers(
  List<String> names, {
  String password = 'pw',
}) async {
  final store = ServerStore(storage: FakeSecureStorage());
  await store.load();
  for (final name in names) {
    await store.addServer(
      ServerProfile(
        id: '',
        name: name,
        host: '$name.local',
        username: 'deploy',
        createdAt: DateTime(2026),
      ),
      secrets: ServerSecrets(password: password),
    );
  }
  return store;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('WidgetSnapshot', () {
    test('寫入再讀回，數值取到小數一位', () {
      final snapshot = WidgetSnapshot(
        refreshMinutes: 15,
        servers: [
          WidgetServer(
            id: 'a',
            name: 'web-01',
            status: ServerStatus.online,
            checkedAt: DateTime(2026, 10, 20, 14, 32),
            metrics: WidgetMetrics.from(_metrics),
          ),
          WidgetServer(
            id: 'b',
            name: 'nas',
            status: ServerStatus.offline,
            message: '連線逾時',
            checkedAt: DateTime(2026, 10, 20, 14, 30),
          ),
        ],
      );
      final restored = WidgetSnapshot.decode(snapshot.encode());
      expect(restored.refreshMinutes, 15);
      final web = restored.byId('a')!;
      expect(web.status, ServerStatus.online);
      expect(web.checkedAt, DateTime(2026, 10, 20, 14, 32));
      expect(web.metrics!.cpu, 42.4);
      expect(web.metrics!.memory, 62.5);
      expect(web.metrics!.disk, 78);
      expect(web.metrics!.load, '1.42');
      expect(web.metrics!.uptime, '11 天 10 小時');
      expect(web.metrics!.os, 'Ubuntu 24.04.1 LTS');
      final nas = restored.byId('b')!;
      expect(nas.status, ServerStatus.offline);
      expect(nas.message, '連線逾時');
      expect(nas.metrics, isNull);
    });

    test('NaN 不會讓 JSON 編碼失敗，損毀的資料讀成空的', () {
      const snapshot = WidgetSnapshot(
        servers: [
          WidgetServer(
            id: 'a',
            name: 'a',
            status: ServerStatus.online,
            metrics: WidgetMetrics(cpu: double.nan, memory: 120, disk: -3),
          ),
        ],
      );
      final metrics = WidgetSnapshot.decode(snapshot.encode())
          .servers
          .single
          .metrics!;
      expect([metrics.cpu, metrics.memory, metrics.disk], [0, 100, 0]);
      expect(WidgetSnapshot.decode('{oops').servers, isEmpty);
      expect(WidgetSnapshot.decode(null).refreshMinutes, 30);
    });

    test('合併時順序與名稱以伺服器清單為準，同一台留下較晚檢查的', () async {
      final store = await _servers(['web-01', 'db', 'nas']);
      final [web, db, nas] = store.servers;
      final previous = WidgetSnapshot(
        servers: [
          WidgetServer(id: 'deleted', name: '已刪除', checkedAt: DateTime(2026)),
          WidgetServer(
            id: nas.id,
            name: '舊名稱',
            status: ServerStatus.offline,
            checkedAt: DateTime(2026, 10, 20, 10),
          ),
          WidgetServer(
            id: web.id,
            name: web.name,
            status: ServerStatus.online,
            checkedAt: DateTime(2026, 10, 20, 12),
            metrics: WidgetMetrics.from(_metrics),
          ),
        ],
      );
      final merged = previous.merge(
        store.servers,
        fresh: [
          // 比原本的舊：保留原本的。
          WidgetServer(
            id: web.id,
            name: web.name,
            status: ServerStatus.offline,
            checkedAt: DateTime(2026, 10, 20, 11),
          ),
          // 比原本的新：換成新的。
          WidgetServer(
            id: nas.id,
            name: nas.name,
            status: ServerStatus.online,
            checkedAt: DateTime(2026, 10, 20, 13),
            metrics: WidgetMetrics.from(_metrics),
          ),
        ],
      );
      expect(
        [for (final server in merged.servers) server.id],
        [web.id, db.id, nas.id],
      );
      expect(merged.byId(web.id)!.status, ServerStatus.online);
      expect(merged.byId(db.id)!.status, ServerStatus.unknown);
      expect(merged.byId(db.id)!.name, 'db');
      expect(merged.byId(nas.id)!.status, ServerStatus.online);
      expect(merged.byId(nas.id)!.name, 'nas');
    });

    test('只接受打開伺服器的小工具網址', () {
      expect(serverIdFromLaunch('mato://server/abc-123'), 'abc-123');
      expect(serverIdFromLaunch('mato://open'), isNull);
      expect(serverIdFromLaunch('mato://server/'), isNull);
      expect(serverIdFromLaunch('https://server/abc'), isNull);
      expect(serverIdFromLaunch(null), isNull);
    });
  });

  group('背景更新', () {
    test('只抓小工具上看得到的伺服器', () async {
      final store = await _servers(['a', 'b', 'c', 'd']);
      final [a, b, c, d] = store.servers;
      final ssh = _Ssh();
      final snapshot = await refreshWidgetSnapshot(
        previous: const WidgetSnapshot(),
        servers: store,
        ssh: ssh,
        serverIds: [d.id],
        overviewRows: 2,
      );
      expect(ssh.fetched, unorderedEquals([a.id, b.id, d.id]));
      expect(snapshot.byId(a.id)!.status, ServerStatus.online);
      expect(snapshot.byId(c.id)!.status, ServerStatus.unknown);
      expect(snapshot.byId(d.id)!.metrics!.cpu, closeTo(42.4, 0.05));
    });

    test('定時更新略過剛檢查過與驗證失敗的伺服器，手動更新則全部重抓', () async {
      final store = await _servers(['fresh', 'stale', 'locked']);
      final [fresh, stale, locked] = store.servers;
      final now = DateTime.now();
      final previous = WidgetSnapshot(
        refreshMinutes: 30,
        servers: [
          WidgetServer(
            id: fresh.id,
            name: fresh.name,
            status: ServerStatus.online,
            checkedAt: now.subtract(const Duration(minutes: 5)),
          ),
          WidgetServer(
            id: stale.id,
            name: stale.name,
            status: ServerStatus.online,
            checkedAt: now.subtract(const Duration(minutes: 20)),
          ),
          WidgetServer(
            id: locked.id,
            name: locked.name,
            status: ServerStatus.authFailed,
            checkedAt: now.subtract(const Duration(hours: 3)),
          ),
        ],
      );
      final scheduled = _Ssh();
      await refreshWidgetSnapshot(
        previous: previous,
        servers: store,
        ssh: scheduled,
        overviewRows: 3,
      );
      expect(scheduled.fetched, [stale.id]);

      final manual = _Ssh();
      await refreshWidgetSnapshot(
        previous: previous,
        servers: store,
        ssh: manual,
        overviewRows: 3,
        manual: true,
      );
      expect(manual.fetched, unorderedEquals([fresh.id, stale.id, locked.id]));
    });

    test('連不上、逾時與沒存密碼的伺服器顯示原因', () async {
      final store = await _servers(['down', 'slow']);
      final noPassword = await store.addServer(
        ServerProfile(
          id: '',
          name: 'ask',
          host: 'ask.local',
          username: 'deploy',
          createdAt: DateTime(2026),
        ),
      );
      final [down, slow, _] = store.servers;
      final ssh = _Ssh()
        ..failures[down.id] = const SshException('Connection refused')
        ..delay = const Duration(milliseconds: 200);
      final snapshot = await refreshWidgetSnapshot(
        previous: const WidgetSnapshot(),
        servers: store,
        ssh: ssh,
        overviewRows: 3,
        timeout: const Duration(milliseconds: 50),
      );
      expect(snapshot.byId(down.id)!.status, ServerStatus.offline);
      expect(snapshot.byId(slow.id)!.status, ServerStatus.offline);
      expect(snapshot.byId(slow.id)!.message, startsWith('連線逾時'));
      expect(snapshot.byId(noPassword.id)!.status, ServerStatus.authFailed);
      expect(ssh.fetched, isNot(contains(noPassword.id)));
      expect(snapshot.byId(down.id)!.checkedAt, isNotNull);
    });
  });

  group('App 開著時', () {
    late SettingsStore settings;
    late ServerStore servers;
    late _Ssh ssh;
    late MonitorService monitor;

    Future<HomeWidgetService> start(_NativeWidgets native) async {
      settings = SettingsStore(storage: FakeSecureStorage());
      await settings.load();
      servers = await _servers(['web-01', 'nas']);
      ssh = _Ssh();
      monitor = MonitorService(ssh: ssh, store: servers, settings: settings);
      final service = HomeWidgetService(
        monitor: monitor,
        servers: servers,
        settings: settings,
        supported: true,
        channel: _NativeWidgets.channel,
      );
      addTearDown(() {
        service.dispose();
        monitor.dispose();
      });
      await service.start();
      return service;
    }

    testWidgets('監控結果最多每 30 秒寫一次，離開 App 時立刻寫入', (tester) async {
      final native = _NativeWidgets(tester);
      final service = await start(native);
      final web = servers.servers.first;

      await tester.pump(const Duration(seconds: 1));
      expect(native.saves, hasLength(1));
      expect(native.last.servers.map((server) => server.name), [
        'web-01',
        'nas',
      ]);
      expect(native.last.byId(web.id)!.status, ServerStatus.unknown);

      await monitor.refresh(web.id);
      await tester.pump(const Duration(seconds: 1));
      expect(native.saves, hasLength(1));
      await tester.pump(const Duration(seconds: 30));
      expect(native.saves, hasLength(2));
      expect(native.last.byId(web.id)!.status, ServerStatus.online);
      expect(native.last.byId(web.id)!.metrics!.cpu, 42.4);

      await monitor.refresh(web.id);
      await tester.pump(const Duration(seconds: 1));
      expect(native.saves, hasLength(2));
      service.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump();
      expect(native.saves, hasLength(3));
      // 已經在桌面上：之後完成的更新馬上寫入。
      await monitor.refresh(web.id);
      await tester.pump(const Duration(seconds: 1));
      expect(native.saves, hasLength(4));
      // 回到 App 後恢復節流。
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await monitor.refresh(web.id);
      await tester.pump(const Duration(seconds: 1));
      expect(native.saves, hasLength(4));
      await tester.pump(const Duration(seconds: 30));
      expect(native.saves, hasLength(5));
    });

    testWidgets('背景寫入的較新資料不會被 App 裡較舊的結果蓋掉', (tester) async {
      final native = _NativeWidgets(tester);
      await start(native);
      final [web, nas] = servers.servers;
      await monitor.refresh(web.id);
      // 背景更新在 App 開著時寫入了更新的結果。
      native.stored = WidgetSnapshot(
        servers: [
          WidgetServer(
            id: web.id,
            name: web.name,
            status: ServerStatus.offline,
            checkedAt: DateTime.now().add(const Duration(minutes: 1)),
          ),
          WidgetServer(
            id: nas.id,
            name: nas.name,
            status: ServerStatus.online,
            checkedAt: DateTime.now(),
            metrics: WidgetMetrics.from(_metrics),
          ),
        ],
      ).encode();

      await servers.updateServer(web.copyWith(name: 'web-renamed'));
      await tester.pump(const Duration(seconds: 1));
      final last = native.last;
      expect(last.byId(web.id)!.name, 'web-renamed');
      expect(last.byId(web.id)!.status, ServerStatus.offline);
      expect(last.byId(nas.id)!.status, ServerStatus.online);
    });

    testWidgets('改了背景更新間隔就馬上告訴原生端', (tester) async {
      final native = _NativeWidgets(tester);
      await start(native);
      await tester.pump(const Duration(seconds: 1));
      expect(native.last.refreshMinutes, 30);

      settings.widgetRefreshMinutes = 60;
      await tester.pump(const Duration(seconds: 1));
      expect(native.saves, hasLength(2));
      expect(native.last.refreshMinutes, 60);
      // 其他設定不影響小工具。
      settings.showTemperature = false;
      await tester.pump(const Duration(seconds: 1));
      expect(native.saves, hasLength(2));
    });

    testWidgets('從小工具點進來時打開那台伺服器', (tester) async {
      final native = _NativeWidgets(tester)..launch = 'mato://server/cold';
      final service = await start(native);
      // 冷啟動：App 畫面出現前收到，由 RootShell 取用。
      expect(service.takePendingOpen(), 'cold');
      expect(service.takePendingOpen(), isNull);

      final opened = <String>[];
      final subscription = service.openRequests.listen(opened.add);
      addTearDown(subscription.cancel);
      await native.tap('mato://server/warm');
      await native.tap('mato://open');
      await tester.pump(const Duration(seconds: 1));
      expect(opened, ['warm']);
    });

    testWidgets('從 App 加入小工具', (tester) async {
      final native = _NativeWidgets(tester);
      final service = await start(native);
      expect(await service.requestPin(HomeWidgetKind.overview), isTrue);
      expect(
        await service.requestPin(HomeWidgetKind.server, serverId: 'abc'),
        isTrue,
      );
      expect(native.pins, [
        {'kind': 'overview'},
        {'kind': 'server', 'serverId': 'abc'},
      ]);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  test('不支援的平台不會呼叫原生端', () async {
    final settings = SettingsStore(storage: FakeSecureStorage());
    final servers = await _servers(['a']);
    TestWidgetsFlutterBinding.ensureInitialized();
    final monitor = MonitorService(
      ssh: _Ssh(),
      store: servers,
      settings: settings,
    );
    final service = HomeWidgetService(
      monitor: monitor,
      servers: servers,
      settings: settings,
      supported: false,
      channel: const MethodChannel('test/unsupported'),
    );
    await service.start();
    expect(await service.requestPin(HomeWidgetKind.overview), isFalse);
    service.dispose();
    monitor.dispose();
  });

  // 原生端用 FlutterEngine 依名稱找這個進入點，改名要一起改 WidgetRefresher.kt。
  test('背景進入點存在', () {
    expect(homeWidgetRefreshMain, isA<Future<void> Function()>());
  });
}
