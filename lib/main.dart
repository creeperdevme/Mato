import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'app_theme.dart';
import 'navigation.dart';
import 'screens/lock_screen.dart';
import 'screens/root_shell.dart';
import 'screens/startup_error_screen.dart';
import 'screens/startup_splash.dart';
import 'services/ai_service.dart';
import 'services/app_lock.dart';
import 'services/backup_service.dart';
import 'services/docker_service.dart';
import 'services/key_store.dart';
import 'services/known_hosts_store.dart';
import 'services/monitor_service.dart';
import 'services/port_forward_service.dart';
import 'services/script_store.dart';
import 'services/server_store.dart';
import 'services/settings_store.dart';
import 'services/ssh_service.dart';
import 'services/terminal_hub.dart';
import 'widgets/ssh_prompts.dart';

/// 讀取本機資料最多等這麼久；外掛卡住時改顯示錯誤畫面，不會一直停在啟動畫面。
const _loadTimeout = Duration(seconds: 30);

void main() {
  // 先播放啟動動畫，本機資料在播放的同時讀取。
  runApp(const StartupSplash(load: _load));
}

/// 載入本機資料並建立 App。任何一步失敗（例如儲存外掛只在 release 版丟出例外）
/// 都改顯示可重試的錯誤畫面，否則畫面會永遠停在啟動動畫。
Future<Widget> _load() async {
  try {
    return await _createApp();
  } catch (error, stackTrace) {
    debugPrint('Mato 啟動失敗：$error\n$stackTrace');
    return StartupErrorApp(
      error: error,
      stackTrace: stackTrace,
      onRetry: _retry,
    );
  }
}

/// 錯誤畫面的重試：重新載入後直接換掉整個畫面，不再播放啟動動畫。
Future<void> _retry() async => runApp(await _load());

Future<MatoApp> _createApp() async {
  final settings = SettingsStore();
  final keys = KeyStore();
  final servers = ServerStore(keys: keys);
  final scripts = ScriptStore();
  final forwards = PortForwardService();
  final knownHosts = KnownHostsStore();
  await Future.wait([
    settings.load(),
    keys.load(),
    servers.load(),
    scripts.load(),
    forwards.load(),
    knownHosts.load(),
  ], eagerError: true).timeout(_loadTimeout);
  if (!settings.seededScripts) {
    if (scripts.scripts.isEmpty) await scripts.seedExamples();
    settings.seededScripts = true;
  }

  final ssh = SSHService(knownHosts: knownHosts)
    ..hostKeyPrompt = (challenge) async {
      final context = navigatorKey.currentContext;
      if (context == null) return false;
      return showHostKeyDialog(context, challenge);
    }
    ..interactivePrompt = (challenge) async {
      final context = navigatorKey.currentContext;
      if (context == null) return null;
      return showInteractiveAuthDialog(context, challenge);
    };
  final monitor = MonitorService(ssh: ssh, store: servers, settings: settings);
  final lock = AppLockService(settings)..lockOnLaunch();

  return MatoApp(
    settings: settings,
    keys: keys,
    servers: servers,
    scripts: scripts,
    forwards: forwards,
    knownHosts: knownHosts,
    ssh: ssh,
    monitor: monitor,
    lock: lock,
  );
}

class MatoApp extends StatelessWidget {
  const MatoApp({
    super.key,
    required this.settings,
    required this.keys,
    required this.servers,
    required this.scripts,
    required this.forwards,
    required this.knownHosts,
    required this.ssh,
    required this.monitor,
    required this.lock,
  });

  final SettingsStore settings;
  final KeyStore keys;
  final ServerStore servers;
  final ScriptStore scripts;
  final PortForwardService forwards;
  final KnownHostsStore knownHosts;
  final SSHService ssh;
  final MonitorService monitor;
  final AppLockService lock;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: keys),
        ChangeNotifierProvider.value(value: servers),
        ChangeNotifierProvider.value(value: scripts),
        ChangeNotifierProvider.value(value: forwards),
        ChangeNotifierProvider.value(value: knownHosts),
        ChangeNotifierProvider.value(value: monitor),
        ChangeNotifierProvider.value(value: lock),
        Provider.value(value: ssh),
        Provider(create: (_) => DockerService(ssh)),
        ChangeNotifierProvider(create: (_) => TerminalHub(ssh)),
        Provider(
          create: (_) => AiHub(
            ssh: ssh,
            settings: settings,
            resolve: servers.resolve,
            latestMetrics: (id) => monitor.monitorOf(id).metrics,
          ),
        ),
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
      child: Consumer<SettingsStore>(
        builder: (context, settings, _) => MaterialApp(
          title: 'Mato',
          navigatorKey: navigatorKey,
          navigatorObservers: [routeObserver],
          debugShowCheckedModeBanner: false,
          theme: buildTheme(settings.accentColor, Brightness.light),
          darkTheme: buildTheme(settings.accentColor, Brightness.dark),
          themeMode: settings.themeMode,
          locale: const Locale('zh', 'TW'),
          supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) =>
              AppLockGate(child: child ?? const SizedBox.shrink()),
          home: const RootShell(),
        ),
      ),
    );
  }
}
