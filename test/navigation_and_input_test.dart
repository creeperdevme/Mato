import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/server_profile.dart';
import 'package:mato/screens/file_manager_screen.dart';
import 'package:mato/services/ssh_service.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

/// 假的 SSH 層：只記錄被要求載入哪些目錄，不真的連線。
class _FakeSshService extends SSHService {
  final List<String> loadedPaths = [];

  @override
  Future<RemoteRunResult> run(ServerProfile profile, String command) async {
    if (command.contains('HOME')) {
      return const RemoteRunResult(
        stdout: '/home/deploy',
        stderr: '',
        exitCode: 0,
      );
    }
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
      ),
    ];
  }
}

ServerProfile _profile() => ServerProfile(
  id: '1',
  name: 'test',
  host: '127.0.0.1',
  port: 22,
  username: 'root',
  createdAt: DateTime(2026, 10, 1),
);

/// 讀出目前路徑列上的文字。
String _currentPathText(WidgetTester tester) {
  final widget = tester.widget<SelectableText>(find.byType(SelectableText));
  return widget.data ?? '';
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('檔案管理導覽', () {
    testWidgets('可以從家目錄回到根目錄', (tester) async {
      final ssh = _FakeSshService();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Provider<SSHService>.value(
              value: ssh,
              child: FileManagerScreen(profile: _profile()),
            ),
          ),
        ),
      );
      await _settle(tester);

      // 起始位置是家目錄
      expect(_currentPathText(tester), '/home/deploy');
      expect(ssh.loadedPaths, contains('/home/deploy'));

      // 按下「回到根目錄 (/)」
      await tester.tap(find.byTooltip('根目錄 (/)'));
      await _settle(tester);

      expect(_currentPathText(tester), '/');
      expect(ssh.loadedPaths, contains('/'));
    });

    testWidgets('可以逐層往上到根目錄，且根目錄時上層按鈕停用', (tester) async {
      final ssh = _FakeSshService();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Provider<SSHService>.value(
              value: ssh,
              child: FileManagerScreen(profile: _profile()),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(_currentPathText(tester), '/home/deploy');

      await tester.tap(find.text('etc'));
      await _settle(tester);
      expect(_currentPathText(tester), '/home/deploy/etc');

      await tester.tap(find.byTooltip('上層目錄'));
      await _settle(tester);
      expect(_currentPathText(tester), '/home/deploy');

      await tester.tap(find.byTooltip('上層目錄'));
      await _settle(tester);
      expect(_currentPathText(tester), '/home');

      await tester.tap(find.byTooltip('上層目錄'));
      await _settle(tester);
      expect(_currentPathText(tester), '/');

      // 已經在根目錄，上層按鈕應停用
      final upButton = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('上層目錄'),
          matching: find.byType(IconButton),
        ).first,
      );
      expect(upButton.onPressed, isNull);
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
  });
}
