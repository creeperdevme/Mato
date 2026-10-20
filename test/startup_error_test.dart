import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mato/screens/startup_error_screen.dart';

void main() {
  testWidgets('啟動失敗時顯示錯誤，可以重試與複製錯誤訊息', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    var retries = 0;
    var pending = Completer<void>();
    await tester.pumpWidget(
      StartupErrorApp(
        error: StateError('讀不到偏好設定'),
        stackTrace: StackTrace.current,
        onRetry: () {
          retries++;
          return pending.future;
        },
      ),
    );
    expect(find.text('Mato 無法啟動'), findsOneWidget);
    expect(find.text('Bad state: 讀不到偏好設定'), findsOneWidget);

    await tester.tap(find.text('重試'));
    await tester.pump();
    expect(retries, 1);
    // 重試還沒結束前按鈕停用，不會重複觸發。
    await tester.tap(find.text('重試'));
    await tester.pump();
    expect(retries, 1);

    pending.complete();
    await tester.pump();
    pending = Completer<void>();
    await tester.tap(find.text('重試'));
    await tester.pump();
    expect(retries, 2);
    pending.complete();
    await tester.pump();

    await tester.tap(find.text('複製錯誤訊息'));
    await tester.pump();
    expect(copied, contains('Bad state: 讀不到偏好設定'));
    expect(find.text('已複製錯誤訊息'), findsOneWidget);
  });
}
