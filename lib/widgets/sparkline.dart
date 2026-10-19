import 'dart:math' as math;

import 'package:flutter/material.dart';

class SparkSeries {
  const SparkSeries({
    required this.values,
    required this.color,
    this.fill = true,
  });

  final List<double> values;
  final Color color;
  final bool fill;
}

/// 輕量的時間序列折線圖：最新的點貼齊右側，資料不足時左側留白，
/// 讓曲線隨取樣自然往左捲動。
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.series,
    this.capacity = 60,
    this.height = 72,
    this.maxValue,
    this.minMax = 1,
    this.gridLines = 3,
  });

  final List<SparkSeries> series;

  /// 橫軸可容納的點數。
  final int capacity;
  final double height;

  /// 固定的縱軸上限（例如百分比用 100）；null 時依資料自動調整。
  final double? maxValue;

  /// 自動調整時縱軸至少要有的上限，避免閒置時雜訊被放大成大波浪。
  final double minMax;
  final int gridLines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(
          series: series,
          capacity: capacity,
          maxValue: maxValue,
          minMax: minMax,
          gridLines: gridLines,
          gridColor: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.series,
    required this.capacity,
    required this.maxValue,
    required this.minMax,
    required this.gridLines,
    required this.gridColor,
  });

  final List<SparkSeries> series;
  final int capacity;
  final double? maxValue;
  final double minMax;
  final int gridLines;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= gridLines; i++) {
      final y = size.height * i / gridLines;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final peak =
        maxValue ??
        math.max(
          minMax,
          series
                  .expand((item) => item.values)
                  .fold<double>(
                    0,
                    (value, element) => math.max(value, element),
                  ) *
              1.15,
        );
    if (peak <= 0) return;
    final step = size.width / math.max(1, capacity - 1);

    for (final item in series) {
      final values = item.values.length > capacity
          ? item.values.sublist(item.values.length - capacity)
          : item.values;
      if (values.length < 2) continue;
      final offset = capacity - values.length;
      final points = [
        for (var i = 0; i < values.length; i++)
          Offset(
            (offset + i) * step,
            size.height - (values[i].clamp(0, peak) / peak) * size.height,
          ),
      ];

      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (var i = 1; i < points.length; i++) {
        final previous = points[i - 1];
        final current = points[i];
        final midX = (previous.dx + current.dx) / 2;
        path.cubicTo(
          midX,
          previous.dy,
          midX,
          current.dy,
          current.dx,
          current.dy,
        );
      }

      if (item.fill) {
        final area = Path.from(path)
          ..lineTo(points.last.dx, size.height)
          ..lineTo(points.first.dx, size.height)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                item.color.withValues(alpha: 0.28),
                item.color.withValues(alpha: 0.02),
              ],
            ).createShader(Offset.zero & size),
        );
      }

      canvas.drawPath(
        path,
        Paint()
          ..color = item.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(points.last, 3, Paint()..color = item.color);
    }
  }

  @override
  bool shouldRepaint(_SparklinePainter oldDelegate) => true;
}

/// 圖例：色點＋標籤＋數值。
class LegendItem extends StatelessWidget {
  const LegendItem({
    super.key,
    required this.color,
    required this.label,
    required this.value,
  });

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
