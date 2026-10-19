import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/server_profile.dart';
import 'package:mato/screens/file_manager_screen.dart';
import 'package:mato/services/settings_store.dart';
import 'package:mato/services/ssh_service.dart';
import 'package:mato/services/terminal_hub.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'support/fakes.dart';

/// 假的 SSH 層：只記錄被要求載入哪些目錄，不真的連線。
class _FakeSshService extends SSHService {
  final List<String> loadedPaths = [];

  @override
  Future<String> homeDirectory(ServerProfile profile) async => '/home/deploy';

  @override
  Future<RemoteRunResult> run(
    ServerProfile profile,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? stdin,
    bool interactive = false,
    int maxOutputBytes = 8 * 1024 * 1024,
  }) async {
    return const RemoteRunResult(stdout: '', stderr: '', exitCode: 0);
  }

  @override
  Future<List<RemoteFileEntry>> listDirectory(
    ServerProfile profile,
    String path,
  ) async {
    loadedPaths.add(path);
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    return [
      RemoteFileEntry(
        name: 'etc',
        path: normalized == '/' ? '/etc' : '$normalized/etc',
        isDirectory: true,
        size: null,
        modifiedTime: null,
        mode: 493,
      ),
      RemoteFileEntry(
        name: '.hidden',
        path: normalized == '/' ? '/.hidden' : '$normalized/.hidden',
        isDirectory: false,
        size: 12,
        modifiedTime: DateTime(2026, 10, 1),
        mode: 420,
      ),
    ];
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<_FakeSshService> _pumpFileManager(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final ssh = _FakeSshService();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<SSHService>.value(value: ssh),
        ChangeNotifierProvider(
          create: (_) => SettingsStore(storage: FakeSecureStorage()),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(body: FileManagerScreen(profile: testProfile())),
      ),
    ),
  );
  await _settle(tester);
  return ssh;
}

void main() {
  group('檔案管理導覽', () {
    testWidgets('從家目錄開始，可以經由選單回到根目錄', (tester) async {
      final ssh = await _pumpFileManager(tester);

      expect(ssh.loadedPaths, ['/home/deploy']);
      expect(find.text('deploy'), findsOneWidget);
      // 隱藏檔預設不顯示。
      expect(find.text('.hidden'), findsNothing);

      await tester.tap(find.byTooltip('更多'));
      await _settle(tester);
      await tester.tap(find.text('根目錄 (/)'));
      await _settle(tester);

      expect(ssh.loadedPaths.last, '/');
    });

    testWidgets('可以逐層往上到根目錄，且根目錄時上層按鈕停用', (tester) async {
      final ssh = await _pumpFileManager(tester);

      await tester.tap(find.text('etc'));
      await _settle(tester);
      expect(ssh.loadedPaths.last, '/home/deploy/etc');

      await tester.tap(find.byTooltip('上層目錄'));
      await _settle(tester);
      expect(ssh.loadedPaths.last, '/home/deploy');

      await tester.tap(find.byTooltip('上層目錄'));
      await _settle(tester);
      expect(ssh.loadedPaths.last, '/home');

      await tester.tap(find.byTooltip('上層目錄'));
      await _settle(tester);
      expect(ssh.loadedPaths.last, '/');

      final upButton = tester.widget<IconButton>(
        find
            .ancestor(
              of: find.byTooltip('上層目錄'),
              matching: find.byType(IconButton),
            )
            .first,
      );
      expect(upButton.onPressed, isNull);
    });

    testWidgets('麵包屑可以直接跳到上層資料夾', (tester) async {
      final ssh = await _pumpFileManager(tester);
      await tester.tap(find.text('home'));
      await _settle(tester);
      expect(ssh.loadedPaths.last, '/home');
    });
  });

  group('終端機輸入', () {
    testWidgets('硬體鍵盤事件會轉成終端機輸入（桌面輸入法失效的替代路徑）', (tester) async {
      final terminal = Terminal();
      final output = StringBuffer();
      terminal.onOutput = output.write;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              autofocus: true,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(output.toString(), contains('a'));
      expect(output.toString(), contains('\r'));
    });

    test('特殊鍵列黏住的 Ctrl／Alt 只套用到下一個輸入', () {
      final session = TerminalSession(
        serverId: '1',
        title: 'Shell 1',
        mode: SessionMode.shell,
      );
      addTearDown(session.dispose);

      expect(session.applyModifiers('c'), 'c');

      session.toggleCtrl();
      expect(session.applyModifiers('c'), '\x03');
      expect(session.ctrlLatched, isFalse);
      expect(session.applyModifiers('c'), 'c');

      session.toggleCtrl();
      expect(session.applyModifiers('['), '\x1b');

      session.toggleAlt();
      expect(session.applyModifiers('b'), '\x1bb');

      session
        ..toggleCtrl()
        ..toggleAlt();
      expect(session.applyModifiers('x'), '\x1b\x18');

      // 多字元輸入（例如貼上）不做 Ctrl 轉換，但仍會放開修飾鍵。
      session.toggleCtrl();
      expect(session.applyModifiers('ls'), 'ls');
      expect(session.ctrlLatched, isFalse);
    });
  });
}
