import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_metrics.dart';
import '../models/server_profile.dart';
import '../services/monitor_service.dart';
import '../services/server_store.dart';
import '../services/settings_store.dart';
import '../utils/format.dart';
import 'common.dart';
import 'load_chart.dart';
import 'server_system_icon.dart';
import 'sparkline.dart';
import 'usage_ring.dart';

const _cpuColor = MetricColors.cpu;
const _memColor = MetricColors.memory;
const _diskColor = MetricColors.disk;
const _rxColor = MetricColors.rx;
const _txColor = MetricColors.tx;
const _gpuColor = MetricColors.gpu;

/// 伺服器「總覽」頁：摘要卡、資源使用、CPU／記憶體／網路／磁碟／GPU 的即時
/// 數據與歷史曲線、負載與系統資訊。
class ServerOverviewTab extends StatelessWidget {
  const ServerOverviewTab({super.key, required this.profile});

  final ServerProfile profile;

  @override
  Widget build(BuildContext context) {
    final monitorService = context.read<MonitorService>();
    final monitor = monitorService.monitorOf(profile.id);
    final showTemperature = context.select<SettingsStore, bool>(
      (settings) => settings.showTemperature,
    );

    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final metrics = monitor.metrics;
        return RefreshIndicator(
          onRefresh: () =>
              monitorService.refresh(profile.id, interactive: true),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final twoColumns = constraints.maxWidth >= 980;
              final cards = metrics == null
                  ? const <Widget>[]
                  : <Widget>[
                      _CpuCard(
                        metrics: metrics,
                        history: monitor.history,
                        showTemperature: showTemperature,
                      ),
                      _MemoryCard(metrics: metrics, history: monitor.history),
                      _NetworkCard(metrics: metrics, history: monitor.history),
                      _DiskCard(metrics: metrics, history: monitor.history),
                      if (metrics.gpus.isNotEmpty)
                        _GpuCard(
                          metrics: metrics,
                          showTemperature: showTemperature,
                        ),
                      _LoadCard(metrics: metrics),
                    ];

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                children: [
                  _HeroCard(
                    profile: profile,
                    monitor: monitor,
                    showTemperature: showTemperature,
                  ),
                  const SizedBox(height: 20),
                  SectionHeader(
                    title: '資源使用',
                    caption: monitor.updatedAt == null
                        ? null
                        : '即時更新 · ${formatClock(monitor.updatedAt!)}',
                    trailing: [
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: '立即更新',
                          onPressed: monitor.loading
                              ? null
                              : () => monitorService.refresh(
                                  profile.id,
                                  interactive: true,
                                ),
                          icon: monitor.loading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded, size: 20),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (metrics == null &&
                      (monitor.loading || monitor.error == null))
                    const _MetricsSkeleton()
                  else if (metrics == null)
                    _EmptyMetricsCard(
                      error: monitor.error,
                      onRefresh: () =>
                          monitorService.refresh(profile.id, interactive: true),
                    )
                  else ...[
                    _ResourceCard(metrics: metrics, error: monitor.error),
                    const SizedBox(height: 14),
                    if (twoColumns)
                      _TwoColumnGrid(children: cards)
                    else
                      for (final card in cards) ...[
                        card,
                        const SizedBox(height: 14),
                      ],
                    const SizedBox(height: 8),
                    const SectionHeader(title: '系統資訊'),
                    const SizedBox(height: 10),
                    _SystemInfoCard(profile: profile, metrics: metrics),
                    const SizedBox(height: 18),
                    _RawOutputCard(raw: metrics.raw),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _TwoColumnGrid extends StatelessWidget {
  const _TwoColumnGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final left = <Widget>[];
    final right = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      (i.isEven ? left : right)
        ..add(children[i])
        ..add(const SizedBox(height: 14));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Column(children: left)),
        const SizedBox(width: 14),
        Expanded(child: Column(children: right)),
      ],
    );
  }
}

/// 頂部摘要卡：名稱、連線資訊、狀態與關鍵數字。
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.profile,
    required this.monitor,
    required this.showTemperature,
  });

  final ServerProfile profile;
  final ServerMonitor monitor;
  final bool showTemperature;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onHero = scheme.onPrimaryContainer;
    final radius = BorderRadius.circular(24);
    final summary = monitor.metrics;
    final temperature = summary?.cpuTemperature;

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
                        child: _badgeContent(context, onHero),
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
                              summary == null || summary.osName.isEmpty
                                  ? profile.address
                                  : '${profile.address} · ${summary.osName}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: onHero.withValues(alpha: 0.78),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surface.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: StatusPill(
                          status: monitor.status,
                          message: monitor.statusMessage,
                        ),
                      ),
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
                          label: monitor.loading ? '正在讀取指標…' : '尚未讀取指標',
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
                            label: '記憶體 ${formatBytes(summary.memTotalBytes)}',
                            color: onHero,
                          ),
                        if (showTemperature && temperature != null)
                          _HeroChip(
                            icon: Icons.thermostat_rounded,
                            label: '${temperature.toStringAsFixed(1)} °C',
                            color: onHero,
                          ),
                        if (summary.ipAddresses.isNotEmpty)
                          _HeroChip(
                            icon: Icons.lan_outlined,
                            label: summary.ipAddresses.first,
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

  /// 摘要卡左上角的圖示塊：有自訂圖片就顯示圖片，否則顯示系統圖示。
  Widget _badgeContent(BuildContext context, Color onHero) {
    final custom = context
        .read<ServerStore>()
        .iconPathOf(profile.iconName);
    if (custom != null) {
      return ServerCustomImage(
        path: custom,
        borderRadius: BorderRadius.circular(13),
      );
    }
    return ServerSystemIcon(
      osId: monitor.metrics?.osId ?? '',
      osName: monitor.metrics?.osName ?? '',
      color: onHero,
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
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
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
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// 三到四個環形儀表：CPU、記憶體、磁碟（與 GPU）。
class _ResourceCard extends StatelessWidget {
  const _ResourceCard({required this.metrics, required this.error});

  final ServerMetrics metrics;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final gpu = metrics.gpus.isEmpty ? null : metrics.gpus.first;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null) ...[
            _InlineWarning(message: error!),
            const SizedBox(height: 14),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final rings = <Widget Function(double size)>[
                (size) => UsageRing(
                  label: 'CPU',
                  icon: Icons.memory,
                  percent: metrics.cpuPercent,
                  valueLabel: '${metrics.cores} 核心',
                  color: _cpuColor,
                  size: size,
                ),
                (size) => UsageRing(
                  label: '記憶體',
                  icon: Icons.developer_board_outlined,
                  percent: metrics.memPercent,
                  valueLabel: formatBytesPair(
                    metrics.memUsedBytes,
                    metrics.memTotalBytes,
                  ),
                  color: _memColor,
                  size: size,
                ),
                (size) => UsageRing(
                  label: '磁碟',
                  icon: Icons.storage_rounded,
                  percent: metrics.diskPercent,
                  valueLabel: formatBytesPair(
                    metrics.diskUsedBytes,
                    metrics.diskTotalBytes,
                  ),
                  color: _diskColor,
                  size: size,
                ),
                if (gpu != null)
                  (size) => UsageRing(
                    label: 'GPU',
                    icon: Icons.videogame_asset_outlined,
                    percent: gpu.utilPercent,
                    valueLabel: formatBytesPair(
                      gpu.memUsedMiB * 1024 * 1024,
                      gpu.memTotalMiB * 1024 * 1024,
                    ),
                    color: _gpuColor,
                    size: size,
                  ),
              ];
              // 手機上四個環擠在一列會讓數值換行，改成 2×2。
              final perRow = rings.length == 4 && constraints.maxWidth < 520
                  ? 2
                  : rings.length;
              const gap = 12.0;
              final cellWidth =
                  ((constraints.maxWidth - gap * (perRow - 1)) / perRow)
                      .floorToDouble();
              final ringSize = (cellWidth - 20).clamp(62.0, 108.0);
              return Wrap(
                spacing: gap,
                runSpacing: 18,
                children: [
                  for (final ring in rings)
                    SizedBox(width: cellWidth, child: ring(ringSize)),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle({
    required this.icon,
    required this.title,
    this.caption,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? caption;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (caption != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              caption!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ] else
          const Spacer(),
        ?trailing,
      ],
    );
  }
}

/// 一列橫向比例條：標籤、條、數值。
class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.percent,
    required this.color,
    this.value,
    this.labelWidth = 64,
  });

  final String label;
  final double percent;
  final Color color;
  final String? value;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tone = usageColor(percent, color);
    return Row(
      children: [
        SizedBox(
          width: labelWidth,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: (percent / 100).clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 10,
                color: tone,
                backgroundColor: scheme.onSurface.withValues(alpha: 0.07),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: value == null ? 44 : 118,
          child: Text(
            value ?? formatPercent(percent),
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _CpuCard extends StatelessWidget {
  const _CpuCard({
    required this.metrics,
    required this.history,
    required this.showTemperature,
  });

  final ServerMetrics metrics;
  final List<MetricsSample> history;
  final bool showTemperature;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final temperature = metrics.cpuTemperature;
    final cores = metrics.perCore;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.memory_rounded,
            title: 'CPU',
            caption: metrics.cpuModel.isEmpty ? null : metrics.cpuModel,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              LegendItem(
                color: _cpuColor,
                label: '使用率',
                value: formatPercent(metrics.cpuPercent),
              ),
              LegendItem(
                color: const Color(0xFFF97316),
                label: 'I/O 等待',
                value: formatPercent(metrics.iowaitPercent),
              ),
              if (showTemperature && temperature != null)
                LegendItem(
                  color: temperature >= 80
                      ? const Color(0xFFE53935)
                      : const Color(0xFF64748B),
                  label: '溫度',
                  value: '${temperature.toStringAsFixed(1)} °C',
                ),
            ],
          ),
          const SizedBox(height: 12),
          Sparkline(
            maxValue: 100,
            capacity: ServerMonitor.maxSamples,
            series: [
              SparkSeries(
                values: [for (final sample in history) sample.cpu],
                color: _cpuColor,
              ),
            ],
          ),
          if (cores.length > 1) ...[
            const SizedBox(height: 14),
            Text(
              '各核心',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            _CoreGrid(cores: cores),
          ],
        ],
      ),
    );
  }
}

/// 每個核心一格的小長條，核心很多時自動換行。
class _CoreGrid extends StatelessWidget {
  const _CoreGrid({required this.cores});

  final List<CpuCoreUsage> cores;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 74).floor().clamp(2, 16);
        final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final core in cores)
              Tooltip(
                message: '${core.name}：${formatPercent(core.percent)}',
                child: SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            core.name.replaceFirst('cpu', '#'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${core.percent.round()}%',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (core.percent / 100).clamp(0.0, 1.0),
                          minHeight: 6,
                          color: usageColor(core.percent, _cpuColor),
                          backgroundColor: scheme.onSurface.withValues(
                            alpha: 0.07,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.metrics, required this.history});

  final ServerMetrics metrics;
  final List<MetricsSample> history;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = metrics.memTotalBytes;
    // 「已用」不含快取；快取可以隨時釋放，所以分開顯示。
    final used = metrics.memUsedBytes;
    final cache = metrics.memCacheBytes.clamp(
      0,
      (total - used).clamp(0, total),
    );
    final free = (total - used - cache).clamp(0, total);
    int share(int value) => total <= 0 ? 0 : (value / total * 1000).round();

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.developer_board_rounded,
            title: '記憶體',
            caption: '${formatBytes(used)} / ${formatBytes(total)}',
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 14,
              child: Row(
                children: [
                  if (share(used) > 0)
                    Expanded(
                      flex: share(used),
                      child: Container(
                        color: usageColor(metrics.memPercent, _memColor),
                      ),
                    ),
                  if (share(cache) > 0)
                    Expanded(
                      flex: share(cache),
                      child: Container(
                        color: _memColor.withValues(alpha: 0.35),
                      ),
                    ),
                  Expanded(
                    flex: share(free).clamp(1, 1000),
                    child: Container(
                      color: scheme.onSurface.withValues(alpha: 0.07),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              LegendItem(
                color: _memColor,
                label: '已用',
                value: formatBytes(used),
              ),
              LegendItem(
                color: _memColor.withValues(alpha: 0.35),
                label: '快取',
                value: formatBytes(cache),
              ),
              LegendItem(
                color: scheme.onSurface.withValues(alpha: 0.2),
                label: '可用',
                value: formatBytes(metrics.memAvailableBytes),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Sparkline(
            maxValue: 100,
            capacity: ServerMonitor.maxSamples,
            series: [
              SparkSeries(
                values: [for (final sample in history) sample.memory],
                color: _memColor,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _BarRow(
            label: '交換空間',
            percent: metrics.swapPercent,
            color: const Color(0xFF6366F1),
            value: metrics.hasSwap
                ? '${formatBytes(metrics.swapUsedBytes)} / '
                      '${formatBytes(metrics.swapTotalBytes)}'
                : '未啟用',
          ),
        ],
      ),
    );
  }
}

class _NetworkCard extends StatefulWidget {
  const _NetworkCard({required this.metrics, required this.history});

  final ServerMetrics metrics;
  final List<MetricsSample> history;

  @override
  State<_NetworkCard> createState() => _NetworkCardState();
}

class _NetworkCardState extends State<_NetworkCard> {
  /// null 代表所有實體介面加總。
  String? _interface;

  @override
  Widget build(BuildContext context) {
    final metrics = widget.metrics;
    final names = metrics.netInterfaces.map((item) => item.name).toList();
    if (_interface != null && !names.contains(_interface)) _interface = null;
    final selected = _interface == null
        ? null
        : metrics.netInterfaces.firstWhere((item) => item.name == _interface);

    final rx = selected?.rxRate ?? metrics.netRxRate;
    final tx = selected?.txRate ?? metrics.netTxRate;
    final rxTotal = selected?.rxBytes ?? metrics.netRxTotal;
    final txTotal = selected?.txBytes ?? metrics.netTxTotal;
    final rxHistory = [
      for (final sample in widget.history)
        _interface == null
            ? sample.netRx
            : sample.interfaces[_interface]?.$1 ?? 0,
    ];
    final txHistory = [
      for (final sample in widget.history)
        _interface == null
            ? sample.netTx
            : sample.interfaces[_interface]?.$2 ?? 0,
    ];

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.lan_rounded,
            title: '網路',
            trailing: names.isEmpty
                ? null
                : DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      value: _interface,
                      isDense: true,
                      borderRadius: BorderRadius.circular(12),
                      style: Theme.of(context).textTheme.labelMedium,
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('全部介面'),
                        ),
                        for (final name in names)
                          DropdownMenuItem<String?>(
                            value: name,
                            child: Text(name),
                          ),
                      ],
                      onChanged: (value) => setState(() => _interface = value),
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _RateTile(
                  icon: Icons.south_rounded,
                  color: _rxColor,
                  label: '下載',
                  rate: rx,
                  total: rxTotal,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _RateTile(
                  icon: Icons.north_rounded,
                  color: _txColor,
                  label: '上傳',
                  rate: tx,
                  total: txTotal,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Sparkline(
            capacity: ServerMonitor.maxSamples,
            minMax: 10 * 1024,
            series: [
              SparkSeries(values: rxHistory, color: _rxColor),
              SparkSeries(values: txHistory, color: _txColor, fill: false),
            ],
          ),
        ],
      ),
    );
  }
}

class _RateTile extends StatelessWidget {
  const _RateTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.rate,
    required this.total,
  });

  final IconData icon;
  final Color color;
  final String label;
  final double rate;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatRate(rate),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  '$label · 累計 ${formatBytes(total)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DiskCard extends StatelessWidget {
  const _DiskCard({required this.metrics, required this.history});

  final ServerMetrics metrics;
  final List<MetricsSample> history;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final systems = metrics.fileSystems;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle(icon: Icons.storage_rounded, title: '磁碟'),
          const SizedBox(height: 12),
          if (systems.isEmpty)
            _BarRow(
              label: '/',
              percent: metrics.diskPercent,
              color: _diskColor,
              value:
                  '${formatBytes(metrics.diskUsedBytes)} / '
                  '${formatBytes(metrics.diskTotalBytes)}',
            )
          else
            for (final fs in systems) ...[
              Tooltip(
                message: '${fs.mount}（${fs.fsType}）',
                child: _BarRow(
                  label: fs.mount,
                  labelWidth: 86,
                  percent: fs.percent,
                  color: _diskColor,
                  value:
                      '${formatBytes(fs.usedBytes)} / ${formatBytes(fs.totalBytes)}',
                ),
              ),
              const SizedBox(height: 8),
            ],
          const SizedBox(height: 6),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              LegendItem(
                color: const Color(0xFF06B6D4),
                label: '讀取',
                value: formatRate(metrics.diskReadRate),
              ),
              LegendItem(
                color: const Color(0xFFF43F5E),
                label: '寫入',
                value: formatRate(metrics.diskWriteRate),
              ),
              LegendItem(
                color: scheme.outline,
                label: 'IOPS',
                value: metrics.diskIops.toStringAsFixed(0),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Sparkline(
            capacity: ServerMonitor.maxSamples,
            minMax: 64 * 1024,
            height: 60,
            series: [
              SparkSeries(
                values: [for (final sample in history) sample.diskRead],
                color: const Color(0xFF06B6D4),
              ),
              SparkSeries(
                values: [for (final sample in history) sample.diskWrite],
                color: const Color(0xFFF43F5E),
                fill: false,
              ),
            ],
          ),
          if (metrics.disks.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final disk in metrics.disks)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.album_outlined,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        disk.name,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Flexible(
                      flex: 3,
                      child: Text(
                        '讀 ${formatRate(disk.readRate)} · 寫 ${formatRate(disk.writeRate)}'
                        ' · 忙碌 ${formatPercent(disk.busyPercent)}',
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _GpuCard extends StatelessWidget {
  const _GpuCard({required this.metrics, required this.showTemperature});

  final ServerMetrics metrics;
  final bool showTemperature;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.videogame_asset_rounded,
            title: 'GPU',
            caption: '${metrics.gpus.length} 張',
          ),
          for (final gpu in metrics.gpus) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    gpu.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (showTemperature && gpu.temperature != null)
                  TagChip(
                    label: '${gpu.temperature!.round()} °C',
                    icon: Icons.thermostat_rounded,
                  ),
                if (gpu.powerDraw != null) ...[
                  const SizedBox(width: 6),
                  TagChip(
                    label: gpu.powerLimit == null
                        ? '${gpu.powerDraw!.round()} W'
                        : '${gpu.powerDraw!.round()} / ${gpu.powerLimit!.round()} W',
                    icon: Icons.bolt_rounded,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            _BarRow(label: '使用率', percent: gpu.utilPercent, color: _gpuColor),
            const SizedBox(height: 6),
            _BarRow(
              label: '顯示記憶體',
              percent: gpu.memPercent,
              color: _gpuColor,
              value:
                  '${(gpu.memUsedMiB / 1024).toStringAsFixed(1)} / '
                  '${(gpu.memTotalMiB / 1024).toStringAsFixed(1)} GB',
            ),
            if (gpu.processes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'GPU 工作',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              for (final process in gpu.processes)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 64,
                        child: Text(
                          '${process.pid}',
                          style: monoStyle(fontSize: 12),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          process.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        '${process.usedMemoryMiB.round()} MiB',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
            ],
          ],
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
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitle(
            icon: Icons.speed_rounded,
            title: '平均負載',
            trailing: Text(
              '核心容量 ${(metrics.loadPerCore * 100).toStringAsFixed(1)}%',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
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
    final kernel = [
      metrics.kernel,
      metrics.arch,
    ].where((item) => item.isNotEmpty).join(' · ');
    final rows = <Widget>[
      _MetricRow(
        icon: ServerSystem.resolve(
          osId: metrics.osId,
          osName: metrics.osName,
        ).icon,
        label: '作業系統',
        value: metrics.osName.isEmpty ? '未知' : metrics.osName,
      ),
      _MetricRow(
        icon: Icons.terminal,
        label: '核心版本',
        value: kernel.isEmpty ? '未知' : kernel,
      ),
      _MetricRow(
        icon: Icons.dns_outlined,
        label: '主機名稱',
        value: metrics.hostname.isEmpty ? profile.host : metrics.hostname,
      ),
      if (metrics.cpuModel.isNotEmpty)
        _MetricRow(icon: Icons.memory, label: 'CPU', value: metrics.cpuModel),
      if (metrics.ipAddresses.isNotEmpty)
        _MetricRow(
          icon: Icons.lan_outlined,
          label: 'IP 位址',
          value: metrics.ipAddresses.join('\n'),
        ),
      _MetricRow(
        icon: Icons.power_settings_new,
        label: '開機時間',
        value: metrics.bootTime ?? '未知',
      ),
      if (metrics.totalProcesses != null)
        _MetricRow(
          icon: Icons.view_list_outlined,
          label: '程序',
          value:
              '${metrics.totalProcesses} 個（執行中 ${metrics.runningProcesses ?? 0}）',
        ),
    ];

    return SurfaceCard(
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
          child: SelectableText(
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

    return SurfaceCard(
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
              constraints: const BoxConstraints(maxHeight: 360),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                child: SelectableText(raw, style: monoStyle(fontSize: 11.5)),
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

    return SurfaceCard(
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
              '顯示的是上一次成功取得的資料。$message',
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

    return SurfaceCard(
      child: Column(
        children: [
          _Pulse(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
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
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
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
      opacity: Tween<double>(
        begin: 0.4,
        end: 0.9,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}
