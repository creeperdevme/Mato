import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/mato_logo.dart';

/// 啟動動畫，蓋在整個 App 上方。
///
/// 原生啟動畫面（Android 的 LaunchTheme 與 Android 12 起的系統啟動畫面、iOS 的
/// LaunchScreen）在同一個位置畫著同樣大小、未通電的標誌，所以 Flutter 接手時
/// 看不出切換。接著曲線從左到右點亮、狀態燈亮起，[load] 完成後從燈號展開成
/// App 畫面；載入比開場慢時燈號持續閃爍。系統要求減少動態效果時不播放動畫。
class StartupSplash extends StatefulWidget {
  const StartupSplash({super.key, required this.load});

  /// 建立 App。不應丟出例外，失敗時要回傳錯誤畫面，否則會一直停在啟動動畫。
  final Future<Widget> Function() load;

  /// 108 格線在螢幕上的邊長：Android 12 起的系統啟動畫面把沒有底色的圖示畫成
  /// 288dp，其他平台的原生啟動畫面也依這個大小產生。
  static const gridSize = 288.0;

  @override
  State<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends State<StartupSplash>
    with SingleTickerProviderStateMixin {
  /// 每一格最多讓動畫前進這麼久。
  ///
  /// 啟動初期引擎還在建立繪圖表面、外掛初始化占住主執行緒，第一格畫面可能
  /// 晚將近一秒才出現；照實際經過的時間播放，動畫一開始就會跳到結尾。限制
  /// 每格的步進後，卡頓時動畫只是暫停，之後從原處繼續播完。
  static const _maxStep = Duration(milliseconds: 50);

  late final _ticker = createTicker(_tick);
  final _timeline = _Timeline();
  Duration _lastElapsed = Duration.zero;

  final _appKey = GlobalKey();
  Widget? _app;
  bool _reduceMotion = false;
  bool _started = false;
  bool _appStyledStatusBar = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    widget.load().then((app) {
      if (!mounted) return;
      setState(() => _app = app);
      _maybeReveal();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      // 直接停在點亮的標誌，載入完成就換成 App。
      _timeline.seconds = _Timeline.intro;
    } else {
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final step = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    _timeline.advance(step < _maxStep ? step : _maxStep);
    _maybeReveal();
    // 系統套用狀態列樣式有延遲，展開到八成就先交給 App，切換才會剛好落在
    // 展開結束時。
    if (!_appStyledStatusBar && _timeline.reveal >= 0.8) {
      setState(() => _appStyledStatusBar = true);
    }
    if (_timeline.reveal >= 1) _finish();
  }

  void _maybeReveal() {
    if (_app == null || _done || _timeline.revealing) return;
    if (_timeline.seconds < _Timeline.revealAfter) return;
    if (_reduceMotion) {
      _finish();
    } else {
      _timeline.startReveal();
    }
  }

  void _finish() {
    _ticker.stop();
    setState(() => _done = true);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _timeline.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    Widget splash = Semantics(
      label: 'Mato',
      textDirection: TextDirection.ltr,
      child: CustomPaint(painter: _SplashPainter(_timeline)),
    );
    // 啟動畫面期間狀態列維持透明、白色圖示，和原生啟動畫面一致，
    // 不受底下 App 的 AppBar 影響。
    if (!_appStyledStatusBar) {
      splash = AnnotatedRegion(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        child: splash,
      );
    }
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.expand,
      children: [
        // App 一載入就先建在啟動畫面底下，展開時不必再花時間建第一個畫面；
        // GlobalKey 確保移除啟動畫面時不會重建 App。
        if (app != null)
          KeyedSubtree(
            key: _appKey,
            child: IgnorePointer(
              ignoring: !_done,
              child: ExcludeSemantics(excluding: !_done, child: app),
            ),
          ),
        if (!_done) splash,
      ],
    );
  }
}

/// 啟動動畫的時間軸（秒）。
class _Timeline extends ChangeNotifier {
  /// 開場長度：曲線在 0.04–0.46 秒點亮，燈號接著亮起並彈一下，光圈到 1 秒散去。
  static const intro = 1.0;

  /// 燈號亮起後才開始展開。
  static const revealAfter = 0.54;
  static const _revealLength = 0.52;

  /// 開場播完還在載入時，燈號一明一暗並發出光圈的週期。
  static const _idlePeriod = 1.4;

  double _seconds = 0;
  double? _revealStart;

  double get seconds => _seconds;
  set seconds(double value) {
    _seconds = value;
    notifyListeners();
  }

  void advance(Duration step) => seconds += step.inMicroseconds / 1e6;

  bool get revealing => _revealStart != null;
  void startReveal() => _revealStart = _seconds;

  /// 開場的進度，0–1。
  double get opening => (_seconds / intro).clamp(0, 1);

  /// 展開成 App 的進度，0–1。
  double get reveal => switch (_revealStart) {
    final start? => ((_seconds - start) / _revealLength).clamp(0, 1),
    null => 0,
  };

  /// 等待載入時的閃爍週期進度，開場期間為 0。
  double get idle =>
      _seconds <= intro ? 0 : ((_seconds - intro) / _idlePeriod) % 1;
}

class _SplashPainter extends CustomPainter {
  _SplashPainter(this.timeline) : super(repaint: timeline);

  final _Timeline timeline;

  static const _lit = Interval(0.04, 0.46, curve: Curves.easeInOutSine);
  static const _ledOn = Interval(0.42, 0.58, curve: Curves.easeOut);
  static const _ledBump = Interval(0.42, 0.7);
  static const _ping = Interval(0.46, 1);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final side = math.min(StartupSplash.gridSize, size.shortestSide);
    final grid = Rect.fromCenter(
      center: bounds.center,
      width: side,
      height: side,
    );
    final led =
        grid.topLeft +
        MatoMarkGeometry.regular.led * (side / MatoMarkGeometry.grid);

    canvas.save();
    final opening = timeline.reveal;
    if (opening > 0) {
      // 從燈號展開的圓形缺口，露出底下的 App。
      final farthest = [
        bounds.topLeft,
        bounds.topRight,
        bounds.bottomLeft,
        bounds.bottomRight,
      ].map((corner) => (corner - led).distance).reduce(math.max);
      canvas.clipPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(bounds)
          ..addOval(
            Rect.fromCircle(
              center: led,
              radius: farthest * Curves.easeInOutCubic.transform(opening),
            ),
          ),
      );
    }
    canvas.drawRect(bounds, Paint()..color = MatoBrand.splash);

    // 展開的同時標誌淡出。
    final opacity = 1 - Curves.easeOut.transform((opening / 0.6).clamp(0, 1));
    if (opacity > 0) {
      if (opacity < 1) {
        canvas.saveLayer(
          bounds,
          Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
        );
      }
      final t = timeline.opening;
      final idle = timeline.idle;
      final breathe = 0.5 - 0.5 * math.cos(2 * math.pi * idle);
      paintMatoMark(
        canvas,
        grid,
        lit: _lit.transform(t),
        led: _ledOn.transform(t) * (1 - 0.45 * breathe),
        ledScale: 1 + 0.3 * math.sin(math.pi * _ledBump.transform(t)),
        ping: t < 1 ? _ping.transform(t) : idle,
        pingStrength: t < 1 ? 1 : 0.5,
      );
      if (opacity < 1) canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SplashPainter oldDelegate) =>
      oldDelegate.timeline != timeline;
}
