// 以假資料渲染每個主要畫面（手機與桌面兩種尺寸），任何版面溢位或例外都會
// 讓測試失敗。設定 MATO_SCREENSHOTS_DIR 時會載入真實字型並輸出截圖。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mato/app_theme.dart';
import 'package:mato/models/port_forward.dart';
import 'package:mato/models/server_metrics.dart';
import 'package:mato/models/server_profile.dart';
import 'package:mato/navigation.dart';
import 'package:mato/screens/root_shell.dart';
import 'package:mato/screens/scripts_screen.dart';
import 'package:mato/screens/server_detail_screen.dart';
import 'package:mato/screens/server_form_screen.dart';
import 'package:mato/screens/settings_screen.dart';
import 'package:mato/services/ai_service.dart';
import 'package:mato/services/app_lock.dart';
import 'package:mato/services/backup_service.dart';
import 'package:mato/services/docker_service.dart';
import 'package:mato/services/key_store.dart';
import 'package:mato/services/known_hosts_store.dart';
import 'package:mato/services/monitor_service.dart';
import 'package:mato/services/port_forward_service.dart';
import 'package:mato/services/script_store.dart';
import 'package:mato/services/server_store.dart';
import 'package:mato/services/settings_store.dart';
import 'package:mato/services/ssh_service.dart';
import 'package:mato/services/terminal_hub.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

final _shotsDir = Platform.environment['MATO_SCREENSHOTS_DIR'];
final _shotKey = GlobalKey();

String _metricsSample(int round) {
  final busy = 80 + (round * 37) % 300;
  final rx = 100000 + round * (400000 + (round % 3) * 250000);
  final tx = 50000 + round * 90000;
  final read = 2000 + round * 1500;
  final write = 1000 + round * 2600;
  final coreLines = StringBuffer();
  for (var core = 0; core < 8; core++) {
    final used = 100 + ((core * 53 + round * 17) % 90);
    coreLines
      ..writeln('CPU_A cpu$core 1000 0 500 8000 100 0 0 0 0 0')
      ..writeln(
        'CPU_B cpu$core ${1000 + used} 0 500 ${8000 + 200 - used} 100 0 0 0 0 0',
      );
  }
  return '''
OS=Ubuntu 24.04.1 LTS
OSID=ubuntu
KERNEL=6.8.0-45-generic
ARCH=x86_64
HOST=web-01
UPTIME=987654
BOOT=2026-09-08 10:12:33
LOAD=1.42 1.05 0.88 3/412
CORES=8
CPUMODEL=AMD EPYC 7543P 32-Core Processor
MEM=32768000 12000000 4000000 9000000
SWAP=4194304 3500000
DISK=104857600 61428800
IP=10.0.0.5 172.17.0.1
TEMP=k10temp|58250
FS=/|ext4|104857600|61428800|43428800
FS=/boot|vfat|524288|61440|462848
FS=/srv/data|xfs|2147483648|1717986918|429496730
GPU=0, GPU-abc, NVIDIA RTX A4000, 63, 9216, 16376, 66, 98.4, 140.00
GPUPROC=GPU-abc, 4242, python3 train.py, 8800
T_A=987654.0
CPU_A cpu 8000 0 4000 64000 800 0 0 0 0 0
${coreLines}T_B=987655.0
CPU_B cpu ${8000 + busy * 4} 0 4000 ${64000 + 1600 - busy * 4} 840 0 0 0 0 0
NET_A eth0 1000000 500000
NET_B eth0 ${1000000 + rx} ${500000 + tx}
NET_A lo 10 10
NET_B lo 20 20
DISKIO_A nvme0n1 1000 0 50000 0 2000 0 80000 0 0 1000 0
DISKIO_B nvme0n1 ${1000 + round} 0 ${50000 + read} 0 ${2000 + round * 2} 0 ${80000 + write} 0 0 ${1000 + 200 + round * 10} 0
''';
}

const _psOutput = '''
    1     0 root          0.0  0.1 11880 12-03:04:05 Ss   /sbin/init splash
  842     1 www-data     12.5  3.2 524288  01:02:03 Sl   nginx: worker process
  910     1 postgres      4.1  6.8 1048576 2-11:00:00 Ss  /usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main
 1201     1 deploy       98.2 12.4 4194304  00:42:10 Rl  python3 train.py --epochs 40 --batch-size 64
 1302     1 deploy        0.3  0.4 65536  03:10:44 S    node /srv/app/server.js
    2     0 root          0.0  0.0     0  12-03:04:05 S    [kthreadd]
''';

class _ScreenSsh extends SSHService {
  int _round = 0;

  /// 已經抓取過幾次監控指標。
  int get fetchCount => _round;

  @override
  Future<ServerMetrics> fetchMetrics(
    ServerProfile profile, {
    bool interactive = false,
  }) async {
    if (profile.id == '2') {
      throw const SocketException('Connection refused (OS Error: errno = 111)');
    }
    return ServerMetrics.tryParse(_metricsSample(++_round))!;
  }

  @override
  Future<String> homeDirectory(ServerProfile profile) async => '/home/deploy';

  @override
  Future<List<RemoteFileEntry>> listDirectory(
    ServerProfile profile,
    String path,
  ) async => [
    for (final name in ['app', 'backups', '.ssh'])
      RemoteFileEntry(
        name: name,
        path: '$path/$name',
        isDirectory: true,
        size: 4096,
        modifiedTime: DateTime(2026, 10, 18, 9, 30),
        mode: 493,
      ),
    RemoteFileEntry(
      name: 'docker-compose.yml',
      path: '$path/docker-compose.yml',
      isDirectory: false,
      size: 2048,
      modifiedTime: DateTime(2026, 10, 19, 14, 2),
      mode: 420,
    ),
    RemoteFileEntry(
      name: 'deploy.sh',
      path: '$path/deploy.sh',
      isDirectory: false,
      size: 812,
      modifiedTime: DateTime(2026, 10, 17, 20, 11),
      mode: 493,
    ),
    RemoteFileEntry(
      name: 'error.log',
      path: '$path/error.log',
      isDirectory: false,
      size: 48211456,
      modifiedTime: DateTime(2026, 10, 19, 22, 40),
      mode: 416,
    ),
    RemoteFileEntry(
      name: 'screenshot.png',
      path: '$path/screenshot.png',
      isDirectory: false,
      size: 389120,
      modifiedTime: DateTime(2026, 10, 1),
      mode: 420,
    ),
  ];

  @override
  Future<RemoteRunResult> run(
    ServerProfile profile,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? stdin,
    bool interactive = false,
    int maxOutputBytes = 8 * 1024 * 1024,
  }) async {
    String out = '';
    if (command.startsWith('ps ')) {
      out = _psOutput;
    } else if (command.contains('docker version')) {
      out = '27.3.1';
    } else if (command.contains(' ps -a')) {
      out = [
        'a1b2c3d4e5f6|~|web|~|nginx:1.27|~|running|~|Up 3 days|~|0.0.0.0:80->80/tcp|~|2026-10-16',
        'b2c3d4e5f6a1|~|db|~|postgres:16|~|running|~|Up 3 days (healthy)|~|5432/tcp|~|2026-10-16',
        'c3d4e5f6a1b2|~|worker|~|ghcr.io/acme/worker:latest|~|exited|~|Exited (1) 2 hours ago|~||~|2026-10-12',
      ].join('\n');
    } else if (command.contains('stats --no-stream')) {
      out = [
        'a1b2c3d4e5f6|~|0.35%|~|24.1MiB / 31.2GiB|~|0.08%|~|1.2GB / 3.4GB|~|0B / 0B',
        'b2c3d4e5f6a1|~|2.10%|~|412MiB / 31.2GiB|~|1.29%|~|88MB / 120MB|~|1.1GB / 3GB',
      ].join('\n');
    }
    return RemoteRunResult(stdout: out, stderr: '', exitCode: 0);
  }

  @override
  Future<SshLease> lease(
    ServerProfile profile, {
    bool interactive = true,
    ConnectProgress? onProgress,
  }) async => throw const SshException('測試環境不連線');
}

Map<String, dynamic> _aiMessage(
  List<Map<String, dynamic>> content,
  String stop,
) => {
  'id': 'msg',
  'type': 'message',
  'role': 'assistant',
  'model': 'claude-opus-5-5',
  'content': content,
  'stop_reason': stop,
};

class _Harness {
  late final SettingsStore settings;
  late final KeyStore keys;
  late final ServerStore servers;
  late final ScriptStore scripts;
  late final PortForwardService forwards;
  late final KnownHostsStore knownHosts;
  late final _ScreenSsh ssh;
  late final MonitorService monitor;
  late final TerminalHub terminals;
  late final AiHub ai;

  Future<void> init() async {
    SharedPreferences.setMockInitialValues({});
    final storage = FakeSecureStorage();
    settings = SettingsStore(storage: storage);
    keys = KeyStore(storage: storage);
    servers = ServerStore(storage: storage, keys: keys);
    scripts = ScriptStore();
    forwards = PortForwardService();
    knownHosts = KnownHostsStore();
    await settings.load();
    await servers.load();
    await keys.load();
    await settings.setAiApiKey('sk-ant-demo');
    await scripts.seedExamples();
    await keys.generateEd25519(name: 'laptop');
    ssh = _ScreenSsh();
    monitor = MonitorService(ssh: ssh, store: servers, settings: settings);
    terminals = TerminalHub(ssh);
    final responses = [
      _aiMessage([
        {'type': 'text', 'text': '我先看看磁碟用量。'},
        {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'run_command',
          'input': {'command': 'df -h / /srv/data', 'reason': '查看磁碟用量'},
        },
      ], 'tool_use'),
      _aiMessage([
        {
          'type': 'text',
          'text':
              '`/srv/data` 已用 **80%**，主要是舊的備份。可以清掉 30 天前的備份：\n'
              '```bash\nfind /srv/data/backups -mtime +30 -delete\n```',
        },
      ], 'end_turn'),
    ];
    ai = AiHub(
      ssh: ssh,
      settings: settings,
      resolve: servers.resolve,
      latestMetrics: (id) => monitor.monitorOf(id).metrics,
      persist: false,
      clientFactory: () => MockClient(
        (request) async => http.Response.bytes(
          utf8.encode(jsonEncode(responses.removeAt(0))),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    for (final (name, host, group) in [
      ('web-01', '10.0.0.5', '正式環境'),
      ('db-primary', '10.0.0.6', '正式環境'),
      ('家用 NAS', 'nas.local', '家用'),
    ]) {
      await servers.addServer(
        ServerProfile(
          id: '',
          name: name,
          host: host,
          username: 'deploy',
          group: group,
          macAddress: group == '家用' ? 'AA:BB:CC:DD:EE:FF' : '',
          createdAt: DateTime(2026),
        ),
        secrets: const ServerSecrets(password: 'secret'),
      );
    }
  }

  Widget wrap(Widget child, {ThemeMode mode = ThemeMode.light}) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: keys),
        ChangeNotifierProvider.value(value: servers),
        ChangeNotifierProvider.value(value: scripts),
        ChangeNotifierProvider.value(value: forwards),
        ChangeNotifierProvider.value(value: knownHosts),
        ChangeNotifierProvider.value(value: monitor),
        ChangeNotifierProvider(create: (_) => AppLockService(settings)),
        Provider<SSHService>.value(value: ssh),
        Provider(create: (_) => DockerService(ssh)),
        ChangeNotifierProvider.value(value: terminals),
        Provider.value(value: ai),
        Provider(
          create: (_) => BackupService(
            servers: servers,
            keys: keys,
            scripts: scripts,
            settings: settings,
            forwards: forwards,
          ),
        ),
      ],
      child: RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorObservers: [routeObserver],
          theme: buildTheme(settings.accentColor, Brightness.light),
          darkTheme: buildTheme(settings.accentColor, Brightness.dark),
          themeMode: mode,
          locale: const Locale('zh', 'TW'),
          supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: child,
        ),
      ),
    );
  }
}

Future<void> _loadFonts() async {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
  final material = '$flutterRoot/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final file = File(path);
      if (file.existsSync()) {
        loader.addFont(
          Future.value(ByteData.sublistView(file.readAsBytesSync())),
        );
      }
    }
    await loader.load();
  }

  await load('Roboto', [
    '$material/roboto-regular.ttf',
    '$material/roboto-medium.ttf',
    '$material/roboto-bold.ttf',
  ]);
  await load('MaterialIcons', ['$material/materialicons-regular.otf']);
  await load('Microsoft JhengHei UI', [
    'C:/Windows/Fonts/msjh.ttc',
    'C:/Windows/Fonts/msjhbd.ttc',
  ]);
  await load('Cascadia Mono', ['C:/Windows/Fonts/CascadiaMono.ttf']);
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = _shotsDir;
  if (dir == null) return;
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_shotKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _sizes = {'phone': Size(390, 844), 'desktop': Size(1366, 900)};

void main() {
  setUpAll(() async {
    if (_shotsDir != null) await _loadFonts();
  });

  testWidgets('切到其他分頁時首頁停止輪詢，切回來再恢復', (tester) async {
    final harness = _Harness();
    await tester.runAsync(harness.init);
    await tester.pumpWidget(harness.wrap(const RootShell()));
    await _settle(tester);
    expect(harness.ssh.fetchCount, greaterThan(0));

    await tester.tap(find.text('設定').last);
    await _settle(tester);
    final paused = harness.ssh.fetchCount;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 5));
    }
    expect(harness.ssh.fetchCount, paused);

    await tester.tap(find.text('伺服器').last);
    await _settle(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(harness.ssh.fetchCount, greaterThan(paused));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  for (final save in [false, true]) {
    testWidgets('從卡片選單編輯伺服器後${save ? '儲存' : '返回'}，首頁恢復輪詢', (tester) async {
      final harness = _Harness();
      await tester.runAsync(harness.init);
      await tester.pumpWidget(harness.wrap(const RootShell()));
      await _settle(tester);

      await tester.tap(find.byTooltip('更多').first);
      await _settle(tester);
      await tester.tap(find.text('編輯'));
      await _settle(tester);
      expect(find.byType(ServerFormScreen), findsOneWidget);
      final paused = harness.ssh.fetchCount;
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      expect(harness.ssh.fetchCount, paused);

      if (save) {
        await tester.ensureVisible(find.text('儲存變更'));
        await tester.pump();
        await tester.tap(find.text('儲存變更'));
      } else {
        await tester.tap(find.byTooltip('返回'));
      }
      await _settle(tester);
      expect(find.byType(ServerFormScreen), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(harness.ssh.fetchCount, greaterThan(paused));

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  for (final entry in _sizes.entries) {
    final label = entry.key;
    final size = entry.value;

    Future<_Harness> setup(WidgetTester tester) async {
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      // flutter_test 預設把陰影畫成實心黑框，截圖時改回真實陰影
      // （測試結束前會在 tearDownApp 還原）。
      if (_shotsDir != null) debugDisableShadows = false;
      final harness = _Harness();
      await tester.runAsync(harness.init);
      harness.settings.extraKeysOverride = label == 'phone';
      // 先累積幾筆監控歷史，讓曲線有內容。
      final first = harness.servers.servers.first.id;
      for (var i = 0; i < 24; i++) {
        await harness.monitor.refresh(first);
      }
      await harness.monitor.refresh(harness.servers.servers[1].id);
      return harness;
    }

    Future<void> tearDownApp(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      debugDisableShadows = true;
    }

    testWidgets('$label：首頁、設定、腳本', (tester) async {
      final harness = await setup(tester);
      await tester.pumpWidget(harness.wrap(const RootShell()));
      await _settle(tester);
      await _shot(tester, '$label-01-home');

      await tester.tap(find.text('腳本').last);
      await _settle(tester);
      await _shot(tester, '$label-02-scripts');

      await tester.tap(find.text('設定').last);
      await _settle(tester);
      await _shot(tester, '$label-03-settings');
      await tearDownApp(tester);
    });

    testWidgets('$label：首頁深色模式', (tester) async {
      final harness = await setup(tester);
      await tester.pumpWidget(
        harness.wrap(const RootShell(), mode: ThemeMode.dark),
      );
      await _settle(tester);
      await _shot(tester, '$label-04-home-dark');
      await tearDownApp(tester);
    });

    testWidgets('$label：總覽深色模式', (tester) async {
      final harness = await setup(tester);
      await tester.pumpWidget(
        harness.wrap(
          ServerDetailScreen(serverId: harness.servers.servers.first.id),
          mode: ThemeMode.dark,
        ),
      );
      await _settle(tester);
      await _shot(tester, '$label-06-overview-dark');
      await tearDownApp(tester);
    });

    testWidgets('$label：伺服器表單', (tester) async {
      final harness = await setup(tester);
      await tester.pumpWidget(
        harness.wrap(ServerFormScreen(server: harness.servers.servers.first)),
      );
      await _settle(tester);
      await _shot(tester, '$label-05-form');
      await tearDownApp(tester);
    });

    for (final section in DetailSection.values) {
      testWidgets('$label：伺服器詳情 · ${section.label}', (tester) async {
        final harness = await setup(tester);
        final server = harness.servers.servers.first;
        if (section == DetailSection.forwards) {
          await tester.runAsync(
            () => harness.forwards.saveRule(
              PortForwardRule(
                id: '',
                serverId: server.id,
                name: 'PostgreSQL',
                kind: ForwardKind.local,
                localPort: 15432,
                remotePort: 5432,
                autoStart: true,
              ),
            ),
          );
        }
        await tester.pumpWidget(
          harness.wrap(
            ServerDetailScreen(serverId: server.id, initialSection: section),
          ),
        );
        await _settle(tester);

        if (section == DetailSection.terminal) {
          final session = harness.terminals.sessionsOf(server.id).single;
          session.terminal.write(
            '\x1b[32mdeploy@web-01\x1b[0m:\x1b[34m~/app\x1b[0m\$ docker compose ps\r\n'
            'NAME      IMAGE          STATUS\r\n'
            'web       nginx:1.27     Up 3 days\r\n'
            'db        postgres:16    Up 3 days (healthy)\r\n'
            '\x1b[32mdeploy@web-01\x1b[0m:\x1b[34m~/app\x1b[0m\$ 中文顯示測試 ✓\r\n',
          );
          session.state = TerminalSessionState.connected;
          session
            ..toggleCtrl()
            ..toggleCtrl();
          await _settle(tester);
        }
        if (section == DetailSection.ai) {
          await tester.enterText(
            find.byType(TextField).last,
            '/srv/data 快滿了，幫我看看',
          );
          await tester.tap(find.byTooltip('送出'));
          await _settle(tester);
          await tester.tap(find.text('允許執行'));
          await _settle(tester);
        }
        await _shot(tester, '$label-1${section.index}-${section.name}');
        await tearDownApp(tester);
      });
    }

    testWidgets('$label：腳本執行結果', (tester) async {
      final harness = await setup(tester);
      final run = harness.scripts.startRun(
        name: '系統概況',
        content: 'uname -a\nuptime',
        sudo: false,
        targets: harness.servers.servers,
        resolve: harness.servers.resolve,
        ssh: harness.ssh,
      );
      await tester.pumpWidget(
        harness.wrap(ScriptRunDetailScreen(runId: run.id)),
      );
      await _settle(tester);
      await _shot(tester, '$label-20-script-run');
      await tearDownApp(tester);
    });

    testWidgets('$label：AI 設定', (tester) async {
      final harness = await setup(tester);
      await tester.pumpWidget(harness.wrap(const AiSettingsScreen()));
      await _settle(tester);
      await _shot(tester, '$label-21-ai-settings');
      await tearDownApp(tester);
    });
  }
}
