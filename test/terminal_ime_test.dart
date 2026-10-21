import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// 不真的連線：lease 一進來就丟例外，終端機分頁仍會建好（畫面與輸入可測）。
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

/// 建立終端機畫面。[captured] 會收到終端機要送給遠端的資料：連線失敗的假
/// SSH 還沒接上輸出，這裡自己接，才看得到輸入法送出了什麼。
///
/// 平台用 `variant: TargetPlatformVariant...` 指定（測試內建的
/// `debugDefaultTargetPlatformOverride` 切換機制），不要自己設那個全域變數。
Future<TerminalSession> _pumpTerminal(
  WidgetTester tester, {
  required StringBuffer captured,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsStore(storage: FakeSecureStorage());
  await settings.load();
  final hub = TerminalHub(_NoConnectSsh());
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: ScriptStore()),
        ChangeNotifierProvider.value(value: hub),
      ],
      child: MaterialApp(
        home: Scaffold(body: TerminalScreen(profile: testProfile())),
      ),
    ),
  );
  await _settle(tester);
  await _settle(tester);
  final session = hub.sessionsOf('1').single;
  session.terminal.onOutput = captured.write;
  return session;
}

TerminalView _terminalView(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView));

/// 刪除鍵送出的位元組（xterm 預設是 DEL，有些鍵表是 BS）。
final _deleteChars = anyOf('\x7f', '\x08');

void main() {
  testWidgets('桌面：程式化聚焦後仍開著文字輸入連線（注音等 IME 才進得來）', (tester) async {
    final captured = StringBuffer();
    await _pumpTerminal(tester, captured: captured);

    // 舊問題：xterm 只在使用者點擊取得焦點時才開輸入連線，開新分頁／切分頁
    // 這類程式化聚焦會「看得到、打不了字」。
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    expect(state.hasInputConnection, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('輸入法組字完成後文字會進到終端機', (tester) async {
    final captured = StringBuffer();
    await _pumpTerminal(tester, captured: captured);
    // 手機的刪除偵測會在輸入框裡放兩個空白當哨兵，組字字串接在後面。
    final base = _terminalView(tester).deleteDetection ? '  ' : '';

    // 組字中（注音還在選字）：只預覽，不送給遠端。
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '$base注',
        composing: TextRange(start: base.length, end: base.length + 1),
      ),
    );
    await _settle(tester);
    expect(captured.toString(), isEmpty);

    // 選字完成：文字真的送進終端機。
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '$base注',
        selection: TextSelection.collapsed(offset: base.length + 1),
      ),
    );
    await _settle(tester);
    expect(captured.toString(), '注');
  }, variant: TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.windows}));

  testWidgets('iOS：軟鍵盤的刪除鍵會送出刪除字元', (tester) async {
    final captured = StringBuffer();
    await _pumpTerminal(tester, captured: captured);
    expect(_terminalView(tester).deleteDetection, isTrue);

    // 軟鍵盤的刪除鍵不會發硬體事件，只會回報「文字比初始狀態短」。
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: ' ',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await _settle(tester);
    expect(captured.toString(), _deleteChars);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('桌面：刪除鍵走硬體事件，不開刪除偵測（否則會刪兩次）', (tester) async {
    final captured = StringBuffer();
    await _pumpTerminal(tester, captured: captured);
    expect(_terminalView(tester).deleteDetection, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _settle(tester);
    expect(captured.toString(), _deleteChars);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('特殊鍵列的刪除鍵會送出刪除字元（軟鍵盤收起來時用）', (tester) async {
    final captured = StringBuffer();
    await _pumpTerminal(tester, captured: captured);

    await tester.tap(find.byTooltip('刪除鍵（Backspace）'));
    await _settle(tester);
    expect(captured.toString(), _deleteChars);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
