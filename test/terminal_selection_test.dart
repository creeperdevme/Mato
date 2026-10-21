import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/server_profile.dart';
import 'package:mato/screens/terminal_screen.dart';
import 'package:mato/services/script_store.dart';
import 'package:mato/services/settings_store.dart';
import 'package:mato/services/ssh_service.dart';
import 'package:mato/services/terminal_hub.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import 'support/fakes.dart';

/// 不真的連線：lease 一進來就丟例外，終端機分頁仍會建好（畫面與選取可測）。
class _NoConnectSsh extends SSHService {
  @override
  Future<SshLease> lease(
    ServerProfile profile, {
    bool interactive = true,
    ConnectProgress? onProgress,
  }) async => throw const SshException('測試環境不連線');
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<TerminalHub> _pumpTerminal(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsStore(storage: FakeSecureStorage());
  await settings.load();
  final scripts = ScriptStore();
  final hub = TerminalHub(_NoConnectSsh());
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: scripts),
        ChangeNotifierProvider.value(value: hub),
      ],
      child: MaterialApp(
        home: Scaffold(body: TerminalScreen(profile: testProfile())),
      ),
    ),
  );
  await _settle(tester);
  await _settle(tester);
  return hub;
}

void main() {
  testWidgets('開啟終端機後程式化聚焦也會開文字輸入連線（IME 可用）', (tester) async {
    final hub = await _pumpTerminal(tester);

    final session = hub.sessionsOf('1').single;
    expect(session, isNotNull);
    // 舊問題：xterm 只在使用者點擊取得焦點時才開輸入連線，程式化聚焦會
    // 「看得到、打不了字」。現在手動補開，注音等 IME 才接得上。
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(state.hasInputConnection, isTrue);
  });

  testWidgets('選取模式：拖曳選字、點一下清除、長按選單字', (tester) async {
    final hub = await _pumpTerminal(tester);
    final session = hub.sessionsOf('1').single;
    // 連線失敗的假 SSH 也會先寫一行「正在連線到 …」進終端機（第 0 行）。
    expect(session.terminal.buffer.getText(), contains('正在連線到'));

    // 開啟選取模式。
    await tester.tap(find.byTooltip('選取模式（拖曳或長按選取文字）'));
    await _settle(tester);
    expect(find.text('選取模式：拖曳或長按選取文字，點一下清除'), findsOneWidget);

    // 拖曳經過第一行：xterm 內建手勢的拖曳選字只支援滑鼠，觸控拖曳原本
    // 會被捲動搶走；選取模式下由外層手勢驅動，手指也能選。
    final topLeft = tester.getTopLeft(find.byType(TerminalView));
    final y = topLeft.dy + 14;
    await tester.dragFrom(Offset(topLeft.dx + 12, y), const Offset(600, 0));
    await _settle(tester);
    expect(session.selectedText, contains('連線到'));

    // 點一下清除選取。
    await tester.tapAt(Offset(topLeft.dx + 100, y));
    await _settle(tester);
    expect(session.selectedText, isNull);

    // 長按選單字（xterm 原本對中文字（寬字元）會選出空字串，這裡驗證有修好）。
    await tester.longPressAt(Offset(topLeft.dx + 15, y));
    await _settle(tester);
    expect(session.selectedText, isNotNull);
    expect(session.selectedText, contains('正'));

    // 離開選取模式後提示列消失。
    await tester.tap(find.byTooltip('離開選取模式'));
    await _settle(tester);
    expect(find.text('選取模式：拖曳或長按選取文字，點一下清除'), findsNothing);
  });
}
