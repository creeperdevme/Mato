import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Mato 的品牌色。
///
/// 各平台的 App 圖示與原生啟動畫面由 `test/app_icons_test.dart` 依這裡的數值與
/// [MatoMarkGeometry] 產生，修改後要依該檔開頭的說明重新產生，否則原生啟動
/// 畫面和 Flutter 的啟動動畫會對不上。
abstract final class MatoBrand {
  /// 圖示底色漸層，左上到右下。
  static const tileStart = Color(0xFF14874D);
  static const tileEnd = Color(0xFF06452A);

  /// 啟動畫面底色。
  static const splash = Color(0xFF0B6B3A);

  static const trace = Color(0xFFFFFFFF);
  static const led = Color(0xFFFFB938);

  /// 原生啟動畫面上「未通電」的標誌只剩淡淡的輪廓，Flutter 接手後再依序點亮。
  static const unlitTraceAlpha = 0.3;
  static const unlitLedAlpha = 0.32;
}

/// 標誌的幾何：一條監控曲線拼成 M，結尾是一顆狀態燈。
///
/// 座標在 Android 自適應圖示的 108×108 格線上。圖示可見的是中央 72 單位，
/// 任何遮罩形狀都保證看得到的安全區是直徑 66 的圓；標誌的外框置中於
/// (54, 54)，四角離中心 [_fit]，在安全區內還留有餘裕。
class MatoMarkGeometry {
  MatoMarkGeometry._(this.points, this.stroke, this.led, this.ledRadius);

  factory MatoMarkGeometry._build({
    required double lead,
    required double tail,
    required double stroke,
    required double ledRadius,
    required double ledGap,
  }) {
    // M 高 30、寬 34，外側兩筆各橫跨 8，中間的谷底落在 64% 高度；
    // 左右再接上長度 lead、tail 的水平引線。
    const height = 30.0, width = 34.0, leg = 8.0, valley = 0.64;
    final raw = [const Offset(0, height)];
    var x = lead;
    if (lead > 0) raw.add(Offset(x, height));
    raw.addAll([
      Offset(x + leg, 0),
      Offset(x + width / 2, height * valley),
      Offset(x + width - leg, 0),
      Offset(x + width, height),
    ]);
    x += width + tail;
    if (tail > 0) raw.add(Offset(x, height));
    final led = Offset(x + stroke / 2 + ledGap + ledRadius, height);

    // 圓頭筆畫會超出端點半個筆寬。
    final bounds = Rect.fromLTRB(
      -stroke / 2,
      -stroke / 2,
      led.dx + ledRadius,
      height + math.max(stroke / 2, ledRadius),
    );
    final scale = _fit / (Offset(bounds.width, bounds.height).distance / 2);
    Offset place(Offset p) =>
        (p - bounds.center) * scale + const Offset(grid / 2, grid / 2);
    return MatoMarkGeometry._(
      [for (final point in raw) place(point)],
      stroke * scale,
      place(led),
      ledRadius * scale,
    );
  }

  /// 一般尺寸。
  static final regular = MatoMarkGeometry._build(
    lead: 7,
    tail: 6,
    stroke: 9,
    ledRadius: 5.8,
    ledGap: 3.4,
  );

  /// 24px 以下：省略引線、加粗筆畫，避免糊成一團。
  static final compact = MatoMarkGeometry._build(
    lead: 0,
    tail: 0,
    stroke: 11,
    ledRadius: 7,
    ledGap: 4,
  );

  /// 依圖示邊長選擇版本。
  static MatoMarkGeometry forSize(double size) => size <= 24 ? compact : regular;

  static const grid = 108.0;
  static const _fit = 28.5;

  /// 曲線的轉折點，依繪製順序。
  final List<Offset> points;
  final double stroke;
  final Offset led;
  final double ledRadius;

  Path get path {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final point in points.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    return path;
  }
}

/// 在 [grid]（對應整個 108 格線的矩形）裡畫出標誌。
///
/// [lit] 是曲線從起點算起已點亮的比例，其餘畫成未通電的輪廓；[led] 是燈號
/// 亮度，[ledScale] 放大燈號，[ping] 是燈號向外擴散的光圈進度（0 表示沒有），
/// 光圈的濃淡乘上 [pingStrength]。
void paintMatoMark(
  Canvas canvas,
  Rect grid, {
  MatoMarkGeometry? geometry,
  double lit = 1,
  double led = 1,
  double ledScale = 1,
  double ping = 0,
  double pingStrength = 1,
}) {
  final g = geometry ?? MatoMarkGeometry.regular;
  canvas
    ..save()
    ..translate(grid.left, grid.top)
    ..scale(grid.width / MatoMarkGeometry.grid);

  final path = g.path;
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = g.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  if (lit < 1) {
    canvas.drawPath(
      path,
      stroke
        ..color = MatoBrand.trace.withValues(alpha: MatoBrand.unlitTraceAlpha),
    );
  }
  if (lit > 0) {
    final metric = path.computeMetrics().single;
    final end = metric.length * lit.clamp(0.0, 1.0);
    canvas.drawPath(
      metric.extractPath(0, end),
      stroke..color = MatoBrand.trace,
    );
    if (lit < 1) {
      // 點亮中的前端帶一圈柔光，像訊號沿著曲線跑過去。
      final head = metric.getTangentForOffset(end)!.position;
      _glow(canvas, head, g.stroke * 1.4, MatoBrand.trace, 0.75);
    }
  }

  final ledRadius = g.ledRadius * ledScale;
  if (ping > 0 && ping < 1) {
    final fade = 1 - ping;
    canvas.drawCircle(
      g.led,
      g.ledRadius * (1 + 3.2 * Curves.easeOutCubic.transform(ping)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = g.stroke * 0.4 * fade
        ..color = MatoBrand.led.withValues(alpha: 0.6 * fade * pingStrength),
    );
  }
  if (led > 0) _glow(canvas, g.led, ledRadius * 2.3, MatoBrand.led, 0.5 * led);
  canvas
    ..drawCircle(
      g.led,
      ledRadius,
      Paint()
        ..color = MatoBrand.led.withValues(
          alpha: ui.lerpDouble(MatoBrand.unlitLedAlpha, 1, led)!,
        ),
    )
    ..restore();
}

void _glow(Canvas canvas, Offset center, double radius, Color color, double alpha) {
  canvas.drawCircle(
    center,
    radius,
    Paint()
      ..shader = ui.Gradient.radial(center, radius, [
        color.withValues(alpha: alpha),
        color.withValues(alpha: 0),
      ]),
  );
}

/// 完整的 App 圖示：漸層底色加上點亮的標誌，畫滿 [rect]。
///
/// [cornerRadius] 是連續曲率圓角佔邊長的比例，0 表示直角（交給系統裁切，例如 iOS）。
void paintMatoIcon(
  Canvas canvas,
  Rect rect, {
  double cornerRadius = 0,
  MatoMarkGeometry? geometry,
}) {
  canvas.save();
  if (cornerRadius > 0) {
    canvas.clipRSuperellipse(
      RSuperellipse.fromRectAndRadius(
        rect,
        Radius.circular(rect.width * cornerRadius),
      ),
    );
  }
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, const [
        MatoBrand.tileStart,
        MatoBrand.tileEnd,
      ]),
  );
  // 圖示對應格線中央可見的 72 單位，所以整個格線是圖示的 1.5 倍大。
  paintMatoMark(
    canvas,
    Rect.fromCenter(
      center: rect.center,
      width: rect.width * 1.5,
      height: rect.height * 1.5,
    ),
    geometry: geometry ?? MatoMarkGeometry.forSize(rect.width),
  );
  canvas.restore();
}

/// App 內使用的品牌標誌，與 App 圖示相同。
class MatoLogo extends StatelessWidget {
  const MatoLogo({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Mato',
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: const _MatoLogoPainter(),
      ),
    );
  }
}

class _MatoLogoPainter extends CustomPainter {
  const _MatoLogoPainter();

  @override
  void paint(Canvas canvas, Size size) =>
      paintMatoIcon(canvas, Offset.zero & size, cornerRadius: 0.3);

  @override
  bool shouldRepaint(_MatoLogoPainter oldDelegate) => false;
}
