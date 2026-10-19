import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 以長條圖呈現 1／5／15 分鐘平均負載。
///
/// 比例會依目前數值自動調整（*1.25 留白），避免閒置主機的長條細到看不見；
/// 只有在「核心數」落在比例範圍內時才畫出滿載線，並於圖例標示核心數。
class LoadChart extends StatelessWidget {
  const LoadChart({
    super.key,
    required this.load1,
    required this.load5,
    required this.load15,
    required this.cores,
  });

  final double load1;
  final double load5;
  final double load15;
  final int cores;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final peak = math.max(load1, math.max(load5, load15));
    final maxValue = peak <= 0 ? 1.0 : math.max(peak * 1.25, 0.5);
    final showCoreLine = cores > 0 && cores <= maxValue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _LoadRow(
          label: '1 分鐘',
          value: load1,
          maxValue: maxValue,
          cores: cores,
          baseColor: scheme.primary,
        ),
        const SizedBox(height: 10),
        _LoadRow(
          label: '5 分鐘',
          value: load5,
          maxValue: maxValue,
          cores: cores,
          baseColor: scheme.primary,
        ),
        const SizedBox(height: 10),
        _LoadRow(
          label: '15 分鐘',
          value: load15,
          maxValue: maxValue,
          cores: cores,
          baseColor: scheme.primary,
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 14,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LegendDot(color: scheme.primary),
                const SizedBox(width: 6),
                Text('低於 60% 核心負載', style: theme.textTheme.labelSmall),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  showCoreLine ? Icons.vertical_align_center : Icons.memory,
                  size: 13,
                  color: scheme.outline,
                ),
                const SizedBox(width: 4),
                Text(
                  showCoreLine ? '滿載線 $cores' : '核心 $cores',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _LoadRow extends StatelessWidget {
  const _LoadRow({
    required this.label,
    required this.value,
    required this.maxValue,
    required this.cores,
    required this.baseColor,
  });

  final String label;
  final double value;
  final double maxValue;
  final int cores;
  final Color baseColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fraction = (value / maxValue).clamp(0.0, 1.0);
    final tone = _toneColor(scheme);

    return Row(
      children: [
        SizedBox(
          width: 54,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SizedBox(
            height: 26,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final overload = maxValue <= 0
                    ? 0.0
                    : (cores / maxValue).clamp(0.0, 1.0);
                return Stack(
                  alignment: Alignment.centerLeft,
                  children: [
                    Container(
                      height: 14,
                      decoration: BoxDecoration(
                        color: scheme.onSurface.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: fraction),
                      duration: const Duration(milliseconds: 800),
                      curve: Curves.easeOutCubic,
                      builder: (context, animated, _) {
                        return FractionallySizedBox(
                          widthFactor: animated <= 0 ? 0.0001 : animated,
                          child: Container(
                            height: 14,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  tone.withValues(alpha: 0.72),
                                  tone,
                                ],
                              ),
                              borderRadius: BorderRadius.circular(7),
                            ),
                          ),
                        );
                      },
                    ),
                    // 核心數滿載線（僅在範圍內時顯示）。
                    if (cores > 0 && cores <= maxValue)
                      Positioned(
                        left: (width * overload).clamp(0.0, width - 2),
                        child: Container(
                          width: 2,
                          height: 22,
                          decoration: BoxDecoration(
                            color: scheme.outline.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            value.toStringAsFixed(2),
            textAlign: TextAlign.right,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  Color _toneColor(ColorScheme scheme) {
    if (cores <= 0) return baseColor;
    final ratio = value / cores;
    if (ratio >= 0.9) return const Color(0xFFE53935);
    if (ratio >= 0.6) return const Color(0xFFF9A825);
    return baseColor;
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.8),
        shape: BoxShape.circle,
      ),
    );
  }
}
