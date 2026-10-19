import 'package:flutter/material.dart';

import '../models/server_metrics.dart';
import '../models/server_profile.dart';
import 'load_chart.dart';
import 'usage_ring.dart';

/// 伺服器「總覽」頁：摘要卡、資源使用圖表、負載圖與系統資訊。
///
/// 只接收資料、不直接讀取 Provider，方便在測試或預覽中套用假資料。
class ServerOverviewTab extends StatelessWidget {
  const ServerOverviewTab({
    super.key,
    required this.profile,
    required this.status,
    required this.statusMessage,
    required this.metrics,
    required this.fetchedAt,
    required this.error,
    required this.loading,
    required this.onRefresh,
    this.autoRefresh = false,
    this.onToggleAutoRefresh,
  });

  final ServerProfile profile;
  final ServerStatus status;
  final String statusMessage;
  final ServerMetrics? metrics;
  final DateTime? fetchedAt;
  final String? error;
  final bool loading;
  final Future<void> Function() onRefresh;

  /// 是否正在每 N 秒自動更新。
  final bool autoRefresh;
  final VoidCallback? onToggleAutoRefresh;

  @override
  Widget build(BuildContext context) {
    final summary = metrics;

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          _HeroCard(
            profile: profile,
            status: status,
            statusMessage: statusMessage,
            metrics: summary,
          ),
          const SizedBox(height: 20),
          _SectionHeader(
            title: '資源使用',
            caption: fetchedAt == null
                ? null
                : '${autoRefresh ? '即時更新' : '已更新'} ${_formatClock(fetchedAt!)}',
            loading: loading,
            onRefresh: onRefresh,
            actions: [
              if (onToggleAutoRefresh != null)
                SizedBox(
                  width: 36,
                  height: 36,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    tooltip: autoRefresh ? '暫停即時更新' : '開始即時更新',
                    onPressed: onToggleAutoRefresh,
                    icon: Icon(
                      autoRefresh
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 20,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (summary == null && loading)
            const _MetricsSkeleton()
          else if (summary == null)
            _EmptyMetricsCard(error: error, onRefresh: onRefresh)
          else
            _ResourceCard(metrics: summary, loading: loading, error: error),
          if (summary != null) ...[
            const SizedBox(height: 14),
            _LoadCard(metrics: summary),
            const SizedBox(height: 22),
            const _SectionHeader(title: '系統資訊'),
            const SizedBox(height: 10),
            _SystemInfoCard(profile: profile, metrics: summary),
            const SizedBox(height: 18),
            _RawOutputCard(raw: summary.raw),
          ],
        ],
      ),
    );
  }

  static String _formatClock(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

/// 頂部摘要卡：名稱、連線資訊、狀態與關鍵數字。
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.profile,
    required this.status,
    required this.statusMessage,
    required this.metrics,
  });

  final ServerProfile profile;
  final ServerStatus status;
  final String statusMessage;
  final ServerMetrics? metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onHero = scheme.onPrimaryContainer;
    final radius = BorderRadius.circular(24);
    final summary = metrics;

    return Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primaryContainer,
            Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.14),
              scheme.primaryContainer,
            ),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.16),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            Positioned(
              top: -54,
              right: -34,
              child: _GlowCircle(
                size: 160,
                color: scheme.primary.withValues(alpha: 0.22),
              ),
            ),
            Positioned(
              bottom: -70,
              left: -46,
              child: _GlowCircle(
                size: 150,
                color: scheme.tertiary.withValues(alpha: 0.16),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: onHero.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: onHero.withValues(alpha: 0.14),
                          ),
                        ),
                        child: Icon(
                          Icons.dns_rounded,
                          color: onHero,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              profile.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: onHero,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${profile.username}@${profile.host}:${profile.port}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: onHero.withValues(alpha: 0.78),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      _StatusPill(status: status, message: statusMessage),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Divider(color: onHero.withValues(alpha: 0.14), height: 1),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (summary == null)
                        _HeroChip(
                          icon: Icons.schedule,
                          label: '尚未讀取指標',
                          color: onHero,
                        )
                      else ...[
                        if (summary.uptimeLabel != null)
                          _HeroChip(
                            icon: Icons.schedule,
                            label: '已運行 ${summary.uptimeLabel}',
                            color: onHero,
                          ),
                        _HeroChip(
                          icon: Icons.memory,
                          label: '${summary.cores} 核心',
                          color: onHero,
                        ),
                        if (summary.memTotalBytes > 0)
                          _HeroChip(
                            icon: Icons.developer_board,
                            label:
                                '記憶體 ${ServerMetrics.formatBytes(summary.memTotalBytes)}',
                            color: onHero,
                          ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlowCircle extends StatelessWidget {
  const _GlowCircle({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color.withValues(alpha: 0.85)),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status, required this.message});

  final ServerStatus status;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = _color(theme);
    final dark = theme.brightness == Brightness.dark;
    final background = dark
        ? Color.alphaBlend(Colors.black.withValues(alpha: 0.35), scheme.surface)
        : scheme.surface;

    return Tooltip(
      message: message.isEmpty ? _label : message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: background.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusDot(color: color, animate: status == ServerStatus.online),
            const SizedBox(width: 6),
            Text(
              _label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _label {
    switch (status) {
      case ServerStatus.online:
        return '線上';
      case ServerStatus.checking:
        return '檢查中';
      case ServerStatus.offline:
        return '離線';
      case ServerStatus.authFailed:
        return '驗證失敗';
      case ServerStatus.error:
        return '錯誤';
      case ServerStatus.unknown:
        return '未檢查';
    }
  }

  Color _color(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    switch (status) {
      case ServerStatus.online:
        return dark ? const Color(0xFF7EE2A8) : const Color(0xFF146C2E);
      case ServerStatus.checking:
        return dark ? const Color(0xFF9EC6FF) : const Color(0xFF11468F);
      case ServerStatus.authFailed:
        return dark ? const Color(0xFFFFC470) : const Color(0xFF8A4B00);
      case ServerStatus.offline:
      case ServerStatus.error:
        return dark ? const Color(0xFFFF9E9E) : const Color(0xFFB3261E);
      case ServerStatus.unknown:
        return theme.colorScheme.onSurfaceVariant;
    }
  }
}

class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.color, this.animate = false});

  final Color color;
  final bool animate;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.animate) _start();
  }

  @override
  void didUpdateWidget(_StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && _controller == null) {
      _start();
    } else if (!widget.animate && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  void _start() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    final controller = _controller;
    if (controller == null) return dot;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(
        CurvedAnimation(parent: controller, curve: Curves.easeInOut),
      ),
      child: dot,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.caption,
    this.loading = false,
    this.onRefresh,
    this.actions = const [],
  });

  final String title;
  final String? caption;
  final bool loading;
  final Future<void> Function()? onRefresh;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final refresh = onRefresh;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 標題與說明放在同一個 Expanded 內，避免它們和右側按鈕爭奪
        // 剩餘空間（Spacer 與 Flexible 同時 flex:1 會把按鈕擠到中間）。
        Expanded(
          child: Row(
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (caption != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    caption!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        ...actions,
        if (refresh != null)
          SizedBox(
            width: 36,
            height: 36,
            child: IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: '重新整理',
              onPressed: loading ? null : () => refresh(),
              icon: loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 20),
            ),
          ),
      ],
    );
  }
}

/// 三個環形儀表：CPU、記憶體、磁碟。
class _ResourceCard extends StatelessWidget {
  const _ResourceCard({
    required this.metrics,
    required this.loading,
    required this.error,
  });

  final ServerMetrics metrics;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (loading) ...[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 14),
          ],
          if (error != null) ...[
            _InlineWarning(message: error!),
            const SizedBox(height: 14),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final ringSize = ((constraints.maxWidth - 36) / 3).clamp(
                62.0,
                108.0,
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: UsageRing(
                      label: 'CPU',
                      icon: Icons.memory,
                      percent: metrics.cpuPercent,
                      valueLabel: '${metrics.cores} 核心',
                      color: scheme.primary,
                      size: ringSize,
                    ),
                  ),
                  Expanded(
                    child: UsageRing(
                      label: '記憶體',
                      icon: Icons.developer_board_outlined,
                      percent: metrics.memPercent,
                      valueLabel:
                          '${ServerMetrics.formatBytes(metrics.memUsedBytes)} / '
                          '${ServerMetrics.formatBytes(metrics.memTotalBytes)}',
                      color: const Color(0xFF3B82F6),
                      size: ringSize,
                    ),
                  ),
                  Expanded(
                    child: UsageRing(
                      label: '磁碟',
                      icon: Icons.storage_rounded,
                      percent: metrics.diskPercent,
                      valueLabel:
                          '${ServerMetrics.formatBytes(metrics.diskUsedBytes)} / '
                          '${ServerMetrics.formatBytes(metrics.diskTotalBytes)}',
                      color: const Color(0xFFA855F7),
                      size: ringSize,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _LoadCard extends StatelessWidget {
  const _LoadCard({required this.metrics});

  final ServerMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return _SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '平均負載',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '核心容量 ${(metrics.loadPerCore * 100).toStringAsFixed(1)}%',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          LoadChart(
            load1: metrics.load1,
            load5: metrics.load5,
            load15: metrics.load15,
            cores: metrics.cores,
          ),
        ],
      ),
    );
  }
}

class _SystemInfoCard extends StatelessWidget {
  const _SystemInfoCard({required this.profile, required this.metrics});

  final ServerProfile profile;
  final ServerMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <Widget>[
      _MetricRow(
        icon: Icons.laptop_mac,
        label: '作業系統',
        value: metrics.osName.isEmpty ? '未知' : metrics.osName,
      ),
      _MetricRow(
        icon: Icons.terminal,
        label: '核心版本',
        value: metrics.kernel.isEmpty ? '未知' : metrics.kernel,
      ),
      _MetricRow(
        icon: Icons.dns_outlined,
        label: '主機名稱',
        value: metrics.hostname.isEmpty ? profile.host : metrics.hostname,
      ),
      _MetricRow(
        icon: Icons.power_settings_new,
        label: '開機時間',
        value: metrics.bootTime ?? '未知',
      ),
      _MetricRow(
        icon: Icons.developer_board,
        label: '記憶體',
        value:
            '${ServerMetrics.formatBytes(metrics.memUsedBytes)} / '
            '${ServerMetrics.formatBytes(metrics.memTotalBytes)}',
      ),
      _MetricRow(
        icon: Icons.swap_horiz,
        label: '交換空間',
        value: metrics.hasSwap
            ? '${ServerMetrics.formatBytes(metrics.swapUsedBytes)} / '
                  '${ServerMetrics.formatBytes(metrics.swapTotalBytes)}'
            : '未啟用',
      ),
      _MetricRow(
        icon: Icons.sd_storage,
        label: '磁碟 (/)',
        value:
            '${ServerMetrics.formatBytes(metrics.diskUsedBytes)} / '
            '${ServerMetrics.formatBytes(metrics.diskTotalBytes)}',
      ),
    ];

    return _SurfaceCard(
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            if (index > 0)
              Divider(
                height: 1,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: rows[index],
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class _RawOutputCard extends StatelessWidget {
  const _RawOutputCard({required this.raw});

  final String raw;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return _SurfaceCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text(
            '原始輸出',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            '遠端指令的完整結果，方便除錯',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                raw,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyMetricsCard extends StatelessWidget {
  const _EmptyMetricsCard({required this.error, required this.onRefresh});

  final String? error;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = error != null;

    return _SurfaceCard(
      child: Column(
        children: [
          Icon(
            failed ? Icons.cloud_off_rounded : Icons.insights_rounded,
            size: 40,
            color: failed ? scheme.error : scheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            failed ? '無法讀取系統資訊' : '還沒有系統指標',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            failed ? error! : '按下方按鈕或下拉重新整理，即可取得 CPU、記憶體與磁碟使用率。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => onRefresh(),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(failed ? '重試' : '立即讀取'),
          ),
        ],
      ),
    );
  }
}

class _InlineWarning extends StatelessWidget {
  const _InlineWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricsSkeleton extends StatelessWidget {
  const _MetricsSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.onSurface.withValues(alpha: 0.08);

    return _SurfaceCard(
      child: Column(
        children: [
          _Pulse(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var i = 0; i < 3; i++)
                  Column(
                    children: [
                      Container(
                        width: 82,
                        height: 82,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: base,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        width: 48,
                        height: 10,
                        decoration: BoxDecoration(
                          color: base,
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            '正在讀取系統指標…',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.4, end: 0.9).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
}

/// 統一樣式的卡片外框（圓角＋淡邊框，避免 M3 預設陰影在深色模式下過重）。
class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      padding: padding ?? const EdgeInsets.all(16),
      child: child,
    );
  }
}
