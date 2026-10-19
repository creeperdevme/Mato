import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 環形使用率儀表，中央顯示百分比，下方顯示標籤與數值。
///
/// 使用 [CustomPainter] 手繪，不需額外圖表套件；可隨資料變化做數字捲動
/// 動畫。使用率過高時會自動轉為警示色。
class UsageRing extends StatelessWidget {
  const UsageRing({
    super.key,
    required this.label,
    required this.percent,
    this.icon,
    this.valueLabel,
    this.color,
    this.size = 96,
  });

  final String label;

  /// 0–100。
  final double percent;
  final IconData? icon;
  final String? valueLabel;

  /// 未進入警示區間時使用的主色。
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tone = _toneColor(scheme);
    final target = percent.clamp(0.0, 100.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: target),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          builder: (context, value, _) {
            return SizedBox(
              width: size,
              height: size,
              child: CustomPaint(
                painter: _RingPainter(
                  percent: value,
                  color: tone,
                  trackColor: scheme.onSurface.withValues(alpha: 0.09),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${value.round()}',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                                height: 1,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            TextSpan(
                              text: '%',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: tone),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        if (valueLabel != null) ...[
          const SizedBox(height: 2),
          Text(
            valueLabel!,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Color _toneColor(ColorScheme scheme) {
    if (percent >= 90) return const Color(0xFFE53935);
    if (percent >= 75) return const Color(0xFFF57C00);
    return color ?? scheme.primary;
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.percent,
    required this.color,
    required this.trackColor,
  });

  final double percent;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = math.max(6.0, size.shortestSide * 0.088);
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final bounds = Rect.fromCircle(center: center, radius: radius);

    // 內圈淡淡的填色，讓環看起來有厚度。
    canvas.drawCircle(
      center,
      radius - stroke * 0.15,
      Paint()..color = color.withValues(alpha: 0.05),
    );

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    canvas.drawArc(bounds, 0, math.pi * 2, false, track);

    final sweep = math.pi * 2 * (percent / 100).clamp(0.0, 1.0);
    if (sweep <= 0) return;

    // 外圈柔光。
    canvas.drawArc(
      bounds,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 1.6
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.16)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 0.8),
    );

    final gradient = SweepGradient(
      colors: [color.withValues(alpha: 0.55), color],
      transform: const GradientRotation(-math.pi / 2),
    ).createShader(bounds);

    canvas.drawArc(
      bounds,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..shader = gradient,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) {
    return oldDelegate.percent != percent ||
        oldDelegate.color != color ||
        oldDelegate.trackColor != trackColor;
  }
}
