// 啟動動畫：載入完成才展開、展開前擋住點擊、展開後 App 不會重建。
// 設定 MATO_SCREENSHOTS_DIR 時另外輸出動畫的逐格截圖。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mato/screens/startup_splash.dart';

final _shotsDir = Platform.environment['MATO_SCREENSHOTS_DIR'];

class _Probe extends StatefulWidget {
  const _Probe();

  static int created = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int _taps = 0;

  @override
  void initState() {
    super.initState();
    _Probe.created++;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => setState(() => _taps++),
            child: Text('點了 $_taps 次'),
          ),
        ),
      ),
    );
  }
}

final _splash = find.descendant(
  of: find.byType(StartupSplash),
  matching: find.byWidgetPredicate(
    (widget) => widget is Semantics && widget.properties.label == 'Mato',
  ),
);

void main() {
  setUp(() => _Probe.created = 0);

  testWidgets('燈號亮起後從燈號展開成 App，展開前擋住點擊', (tester) async {
    await tester.pumpWidget(StartupSplash(load: () async => const _Probe()));
    expect(_splash, findsOneWidget);

    // App 一載入就先建在啟動畫面底下。
    await tester.pump();
    expect(find.text('點了 0 次'), findsOneWidget);
    await tester.tap(find.text('點了 0 次'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('點了 0 次'), findsOneWidget);
    expect(_splash, findsOneWidget);

    await tester.pumpAndSettle();
    expect(_splash, findsNothing);
    await tester.tap(find.text('點了 0 次'));
    await tester.pump();
    expect(find.text('點了 1 次'), findsOneWidget);
    expect(_Probe.created, 1);
  });

  testWidgets('載入比開場慢時停在啟動畫面，完成後才展開', (tester) async {
    final app = Completer<Widget>();
    await tester.pumpWidget(StartupSplash(load: () => app.future));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_splash, findsOneWidget);
    expect(find.text('點了 0 次'), findsNothing);

    app.complete(const _Probe());
    await tester.pumpAndSettle();
    expect(_splash, findsNothing);
    expect(find.text('點了 0 次'), findsOneWidget);
    expect(_Probe.created, 1);
  });

  testWidgets('畫面卡住很久時動畫只是暫停，不會直接跳到結尾', (tester) async {
    await tester.pumpWidget(StartupSplash(load: () async => const _Probe()));
    await tester.pump();
    // 模擬啟動初期將近兩秒沒有畫面：照實際時間播放的話早就展開完畢了。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(_splash, findsOneWidget);

    await tester.pumpAndSettle();
    expect(_splash, findsNothing);
  });

  testWidgets('系統要求減少動態效果時，載入完成就直接顯示 App', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(StartupSplash(load: () async => const _Probe()));
    await tester.pump();
    expect(_splash, findsNothing);
    await tester.tap(find.text('點了 0 次'));
    await tester.pump();
    expect(find.text('點了 1 次'), findsOneWidget);
  });

  testWidgets('啟動動畫逐格截圖', (tester) async {
    final dir = _shotsDir;
    if (dir == null) return;
    tester.view.physicalSize = const Size(390, 844) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final app = Completer<Widget>();
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: StartupSplash(load: () => app.future),
      ),
    );
    var elapsed = 0;
    Future<void> shoot(int at) async {
      // 每格最多前進 50ms，用小步推進才會照實際時間播放。
      for (; elapsed < at; elapsed += 10) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(key),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(dir).createSync(recursive: true);
        File(
          '$dir/splash-${at.toString().padLeft(4, '0')}.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    }

    for (final at in [0, 150, 300, 420, 520, 640, 900]) {
      await shoot(at);
    }
    app.complete(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0B6B3A)),
        home: Scaffold(
          appBar: AppBar(title: const Text('伺服器')),
          body: const Center(child: Text('App')),
        ),
      ),
    );
    for (final at in [1000, 1100, 1200, 1300, 1400, 1600]) {
      await shoot(at);
    }
  });
}
