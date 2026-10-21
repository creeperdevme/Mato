import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../navigation.dart';
import '../services/monitor_service.dart';
import '../services/port_forward_service.dart';
import '../services/server_store.dart';
import '../services/settings_store.dart';
import '../services/terminal_hub.dart';
import '../utils/format.dart';
import '../widgets/common.dart';
import '../widgets/server_system_icon.dart';
import '../widgets/sparkline.dart';
import '../widgets/usage_ring.dart';
import 'lan_scan_screen.dart';
import 'server_actions.dart';
import 'server_detail_screen.dart';
import 'server_form_screen.dart';

/// 伺服器總覽：每台伺服器一張卡片，即時顯示 CPU、記憶體、磁碟與網路。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  final _searchController = TextEditingController();
  String _query = '';
  String? _group;
  bool _searching = false;
  bool _covered = false;
  Set<String> _watching = {};
  late final MonitorService _monitor;

  @override
  void initState() {
    super.initState();
    _monitor = context.read<MonitorService>();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _searchController.dispose();
    _syncWatching(const {});
    super.dispose();
  }

  // 被詳情頁蓋住時暫停首頁輪詢，回來時恢復。
  @override
  void didPushNext() {
    _covered = true;
    _syncWatching(const {});
  }

  @override
  void didPopNext() {
    _covered = false;
    if (mounted) setState(() {});
  }

  /// 讓監看的伺服器與畫面上的清單一致。
  void _syncWatching(Set<String> wanted) {
    for (final id in _watching.difference(wanted)) {
      _monitor.unwatch(id, this);
    }
    for (final id in wanted.difference(_watching)) {
      _monitor.watch(id, this);
    }
    _watching = wanted;
  }

  List<ServerProfile> _filter(List<ServerProfile> servers) {
    final query = _query.trim().toLowerCase();
    return servers.where((server) {
      if (_group != null && server.group != _group) return false;
      if (query.isEmpty) return true;
      return server.name.toLowerCase().contains(query) ||
          server.host.toLowerCase().contains(query) ||
          server.username.toLowerCase().contains(query) ||
          server.group.toLowerCase().contains(query);
    }).toList();
  }

  Future<void> _add() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ServerFormScreen()));
  }

  Future<void> _scan() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const LanScanScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ServerStore>();
    final live = context.select<SettingsStore, bool>((s) => s.dashboardLive);
    final groups = store.groups;
    if (_group != null && !groups.contains(_group)) _group = null;
    final servers = _filter(store.servers);

    // 首頁看得到時才輪詢（被其他頁面蓋住、或切到底部導覽的其他分頁時暫停）；
    // 關閉「即時監控」時只在手動重新整理時更新。
    final visible = Visibility.of(context);
    final wanted = live && !_covered && visible
        ? {for (final server in store.servers) server.id}
        : <String>{};
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncWatching(wanted);
    });

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜尋名稱、位址或分組',
                  border: InputBorder.none,
                  filled: false,
                ),
                onChanged: (value) => setState(() => _query = value),
              )
            : const Text('伺服器'),
        actions: [
          if (store.servers.isNotEmpty)
            IconButton(
              tooltip: _searching ? '關閉搜尋' : '搜尋',
              icon: Icon(
                _searching ? Icons.close_rounded : Icons.search_rounded,
              ),
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _query = '';
                  _searchController.clear();
                }
              }),
            ),
          IconButton(
            tooltip: '掃描區網中的 SSH 主機',
            icon: const Icon(Icons.radar_rounded),
            onPressed: _scan,
          ),
          if (isWide(context))
            Padding(
              padding: const EdgeInsets.only(right: 12, left: 4),
              child: FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add_rounded),
                label: const Text('新增伺服器'),
              ),
            ),
        ],
      ),
      floatingActionButton: isWide(context) || store.servers.isEmpty
          ? null
          : FloatingActionButton(
              tooltip: '新增伺服器',
              onPressed: _add,
              child: const Icon(Icons.add_rounded),
            ),
      body: !store.loaded
          ? const Center(child: CircularProgressIndicator())
          : store.servers.isEmpty
          ? EmptyState(
              icon: Icons.dns_outlined,
              title: '歡迎使用 Mato',
              message:
                  '新增 SSH 伺服器，即可即時監控狀態，並使用終端機、檔案、'
                  'Docker、程序管理與 AI 助理。',
              action: Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _add,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('新增伺服器'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _scan,
                    icon: const Icon(Icons.radar_rounded),
                    label: const Text('掃描區網'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                final monitor = context.read<MonitorService>();
                await Future.wait([
                  for (final server in servers) monitor.refresh(server.id),
                ]);
              },
              child: CustomScrollView(
                slivers: [
                  if (groups.isNotEmpty)
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 52,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          children: [
                            _GroupChip(
                              label: '全部',
                              selected: _group == null,
                              onTap: () => setState(() => _group = null),
                            ),
                            for (final group in groups)
                              _GroupChip(
                                label: group,
                                selected: _group == group,
                                onTap: () => setState(
                                  () => _group = _group == group ? null : group,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (servers.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: Icons.search_off_rounded,
                        title: '沒有符合的伺服器',
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                      sliver: SliverLayoutBuilder(
                        builder: (context, constraints) {
                          final width = constraints.crossAxisExtent;
                          final columns = width >= 1180
                              ? 3
                              : width >= 680
                              ? 2
                              : 1;
                          return SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  mainAxisExtent: 214,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) =>
                                  _ServerCard(server: servers[index]),
                              childCount: servers.length,
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.server});

  final ServerProfile server;

  @override
  Widget build(BuildContext context) {
    // 只監聽這台的監控資料，其他伺服器更新時不必重繪。
    final monitor = context.read<MonitorService>().monitorOf(server.id);
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) => _buildCard(context, monitor),
    );
  }

  Widget _buildCard(BuildContext context, ServerMonitor monitor) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final metrics = monitor.metrics;
    final stale =
        monitor.status != ServerStatus.online &&
        monitor.status != ServerStatus.checking;
    final terminals = context.select<TerminalHub, int>(
      (hub) => hub.activeCount(server.id),
    );
    final forwards = context.select<PortForwardService, int>(
      (service) => service.activeCount(server.id),
    );

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
      onTap: () => openServer(context, server.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _OsBadge(
                osId: metrics?.osId ?? '',
                osName: metrics?.osName ?? '',
                status: monitor.status,
                iconPath: context
                    .read<ServerStore>()
                    .iconPathOf(server.iconName),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      server.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              StatusPill(
                status: monitor.status,
                message: monitor.statusMessage,
              ),
              _CardMenu(server: server, monitor: monitor),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (server.group.isNotEmpty)
                TagChip(label: server.group, icon: Icons.folder_outlined),
              if (metrics != null && metrics.osName.isNotEmpty)
                TagChip(label: metrics.osName),
              if (terminals > 0)
                TagChip(
                  label: '$terminals 個終端機',
                  icon: Icons.terminal_rounded,
                  color: scheme.primary,
                ),
              if (forwards > 0)
                TagChip(
                  label: '$forwards 個轉發',
                  icon: Icons.swap_horiz_rounded,
                  color: scheme.tertiary,
                ),
            ],
          ),
          const Spacer(),
          if (metrics == null || stale)
            _OfflineBody(server: server, monitor: monitor)
          else
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  MiniRing(
                    label: 'CPU',
                    percent: metrics.cpuPercent,
                    color: MetricColors.cpu,
                  ),
                  const SizedBox(width: 10),
                  MiniRing(
                    label: '記憶體',
                    percent: metrics.memPercent,
                    color: MetricColors.memory,
                  ),
                  const SizedBox(width: 10),
                  MiniRing(
                    label: '磁碟',
                    percent: metrics.diskPercent,
                    color: MetricColors.disk,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Stat(
                          icon: Icons.south_rounded,
                          color: MetricColors.rx,
                          text: formatRate(metrics.netRxRate),
                        ),
                        _Stat(
                          icon: Icons.north_rounded,
                          color: MetricColors.tx,
                          text: formatRate(metrics.netTxRate),
                        ),
                        _Stat(
                          icon: Icons.speed_rounded,
                          text: '負載 ${metrics.load1.toStringAsFixed(2)}',
                        ),
                        if (metrics.uptimeLabel != null)
                          _Stat(
                            icon: Icons.schedule_rounded,
                            text: metrics.uptimeLabel!,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          // 歷史不足兩筆時也保留曲線的高度，讓每張卡片的版面一致。
          if (metrics != null && !stale && monitor.history.length < 2)
            const SizedBox(height: 30),
          if (metrics != null && !stale && monitor.history.length > 1) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Sparkline(
                height: 22,
                capacity: 40,
                maxValue: 100,
                gridLines: 1,
                series: [
                  SparkSeries(
                    values: [for (final sample in monitor.history) sample.cpu],
                    color: MetricColors.cpu,
                  ),
                  SparkSeries(
                    values: [
                      for (final sample in monitor.history) sample.memory,
                    ],
                    color: MetricColors.memory,
                    fill: false,
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

class _OfflineBody extends StatelessWidget {
  const _OfflineBody({required this.server, required this.monitor});

  final ServerProfile server;
  final ServerMonitor monitor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final checking =
        monitor.status == ServerStatus.checking ||
        (monitor.loading && monitor.metrics == null);
    final message = checking
        ? '正在連線…'
        : monitor.error ??
              (monitor.status == ServerStatus.unknown
                  ? '尚未連線，點擊卡片查看詳情'
                  : monitor.statusMessage);

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        children: [
          if (checking)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              monitor.error == null
                  ? Icons.cloud_queue_rounded
                  : Icons.cloud_off_rounded,
              size: 18,
              color: monitor.error == null
                  ? scheme.onSurfaceVariant
                  : scheme.error,
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (server.canWake && monitor.status == ServerStatus.offline)
            TextButton.icon(
              onPressed: () => wakeServer(context, server),
              icon: const Icon(Icons.power_settings_new_rounded, size: 18),
              label: const Text('喚醒'),
            )
          else if (!checking)
            TextButton(
              onPressed: () => context.read<MonitorService>().refresh(
                server.id,
                interactive: true,
              ),
              child: const Text('重試'),
            ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Icon(
            icon,
            size: 13,
            color: color ?? theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 依發行版顯示圖示底色，狀態不佳時改成警示色。
/// 有自訂圖片（[iconPath]）時直接顯示圖片取代系統圖示。
class _OsBadge extends StatelessWidget {
  const _OsBadge({
    required this.osId,
    required this.osName,
    required this.status,
    this.iconPath,
  });

  final String osId;
  final String osName;
  final ServerStatus status;
  final String? iconPath;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final custom = iconPath;
    if (custom != null) {
      return SizedBox(
        width: 40,
        height: 40,
        child: ServerCustomImage(
          path: custom,
          borderRadius: BorderRadius.circular(12),
        ),
      );
    }
    final system = ServerSystem.resolve(osId: osId, osName: osName);
    final base = system.color ?? scheme.primary;
    final dim = status == ServerStatus.offline || status == ServerStatus.error;
    final color = dim ? scheme.outline : base;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ServerSystemIcon(
        osId: osId,
        osName: osName,
        color: color,
        size: 22,
      ),
    );
  }
}

class _CardMenu extends StatelessWidget {
  const _CardMenu({required this.server, required this.monitor});

  final ServerProfile server;
  final ServerMonitor monitor;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      onSelected: (action) async {
        switch (action) {
          case 'terminal':
            await openServer(
              context,
              server.id,
              section: DetailSection.terminal,
            );
          case 'files':
            await openServer(context, server.id, section: DetailSection.files);
          case 'refresh':
            await context.read<MonitorService>().refresh(
              server.id,
              interactive: true,
            );
          case 'edit':
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ServerFormScreen(server: server),
              ),
            );
          case 'duplicate':
            await context.read<ServerStore>().duplicate(server.id);
          case 'wake':
            await wakeServer(context, server);
          case 'delete':
            await deleteServer(context, server);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'terminal',
          child: ListTile(
            leading: Icon(Icons.terminal_rounded),
            title: Text('開啟終端機'),
          ),
        ),
        const PopupMenuItem(
          value: 'files',
          child: ListTile(
            leading: Icon(Icons.folder_open_rounded),
            title: Text('檔案管理'),
          ),
        ),
        const PopupMenuItem(
          value: 'refresh',
          child: ListTile(
            leading: Icon(Icons.refresh_rounded),
            title: Text('重新整理'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(
            leading: Icon(Icons.edit_outlined),
            title: Text('編輯'),
          ),
        ),
        const PopupMenuItem(
          value: 'duplicate',
          child: ListTile(
            leading: Icon(Icons.copy_all_outlined),
            title: Text('複製一份'),
          ),
        ),
        if (server.canWake)
          const PopupMenuItem(
            value: 'wake',
            child: ListTile(
              leading: Icon(Icons.power_settings_new_rounded),
              title: Text('Wake-on-LAN 喚醒'),
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline_rounded),
            title: Text('刪除'),
          ),
        ),
      ],
    );
  }
}
