import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/monitor_service.dart';
import '../services/port_forward_service.dart';
import '../services/server_store.dart';
import '../services/ssh_service.dart';
import '../services/terminal_hub.dart';
import '../widgets/common.dart';
import '../widgets/overview_dashboard.dart';
import 'ai_chat_screen.dart';
import 'docker_screen.dart';
import 'file_manager_screen.dart';
import 'port_forward_screen.dart';
import 'process_screen.dart';
import 'scripts_screen.dart';
import 'server_actions.dart';
import 'server_form_screen.dart';
import 'terminal_screen.dart';

enum DetailSection {
  overview('總覽', Icons.insights_outlined, Icons.insights_rounded),
  terminal('終端機', Icons.terminal_outlined, Icons.terminal_rounded),
  files('檔案', Icons.folder_outlined, Icons.folder_rounded),
  processes('程序', Icons.view_list_outlined, Icons.view_list_rounded),
  docker('容器', Icons.view_in_ar_outlined, Icons.view_in_ar_rounded),
  forwards('轉發', Icons.swap_horiz_outlined, Icons.swap_horiz_rounded),
  ai('AI 助理', Icons.auto_awesome_outlined, Icons.auto_awesome_rounded);

  const DetailSection(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class ServerDetailScreen extends StatefulWidget {
  const ServerDetailScreen({
    super.key,
    required this.serverId,
    this.initialSection = DetailSection.overview,
  });

  final String serverId;
  final DetailSection initialSection;

  @override
  State<ServerDetailScreen> createState() => _ServerDetailScreenState();
}

class _ServerDetailScreenState extends State<ServerDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: DetailSection.values.length,
    vsync: this,
    initialIndex: widget.initialSection.index,
  );
  late DetailSection _section = widget.initialSection;
  late final Set<DetailSection> _visited = {widget.initialSection};
  late final MonitorService _monitor;
  final ValueNotifier<String?> _aiDraft = ValueNotifier(null);

  ServerProfile? _profile;
  String? _signature;
  String? _error;
  bool _autoStarted = false;

  @override
  void initState() {
    super.initState();
    // 進入詳情頁時以互動模式連線，需要 2FA 或確認主機金鑰時才會詢問。
    _monitor = context.read<MonitorService>()
      ..watch(widget.serverId, this, interactive: true);
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging && _tabs.index != _section.index) {
        _select(DetailSection.values[_tabs.index]);
      }
    });
    _resolve();
  }

  @override
  void dispose() {
    _monitor.unwatch(widget.serverId, this);
    _tabs.dispose();
    _aiDraft.dispose();
    super.dispose();
  }

  Future<void> _resolve() async {
    try {
      final profile = await context.read<ServerStore>().resolve(
        widget.serverId,
      );
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _signature = profile.connectionSignature + profile.toJson().toString();
        _error = null;
      });
      _autoStartForwards(profile);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  void _autoStartForwards(ServerProfile profile) {
    if (_autoStarted) return;
    _autoStarted = true;
    final forwards = context.read<PortForwardService>();
    final ssh = context.read<SSHService>();
    for (final rule in forwards.rulesOf(profile.id)) {
      if (rule.autoStart && forwards.activeOf(rule.id) == null) {
        unawaited(forwards.start(rule, profile, ssh));
      }
    }
  }

  void _select(DetailSection section) {
    if (!mounted) return;
    setState(() {
      _section = section;
      _visited.add(section);
    });
    if (_tabs.index != section.index) _tabs.animateTo(section.index);
  }

  void _askAi(String text) {
    _aiDraft.value = text;
    _select(DetailSection.ai);
  }

  void _openTerminal({String? command, String? title, String? initialInput}) {
    final profile = _profile;
    if (profile == null) return;
    context.read<TerminalHub>().open(
      profile,
      command: command,
      title: title,
      initialInput: initialInput,
    );
    _select(DetailSection.terminal);
  }

  Future<void> _edit(ServerProfile server) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ServerFormScreen(server: server)),
    );
    if (mounted) await _resolve();
  }

  Future<void> _runScript() async {
    final profile = _profile;
    if (profile == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScriptRunnerScreen(preselectedServerIds: {profile.id}),
      ),
    );
  }

  Widget _buildSection(DetailSection section, ServerProfile profile) {
    if (!_visited.contains(section)) return const SizedBox.shrink();
    switch (section) {
      case DetailSection.overview:
        return ServerOverviewTab(profile: profile);
      case DetailSection.terminal:
        return TerminalScreen(profile: profile, onAskAi: _askAi);
      case DetailSection.files:
        return FileManagerScreen(
          profile: profile,
          onOpenTerminal: (path) => _openTerminal(
            initialInput: "cd '${path.replaceAll("'", "'\\''")}'",
          ),
        );
      case DetailSection.processes:
        return ProcessScreen(profile: profile);
      case DetailSection.docker:
        return DockerScreen(
          profile: profile,
          onOpenShell: (command, title) =>
              _openTerminal(command: command, title: title),
        );
      case DetailSection.forwards:
        return PortForwardScreen(profile: profile);
      case DetailSection.ai:
        return AiChatScreen(profile: profile, draft: _aiDraft);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ServerStore>();
    final server = store.byId(widget.serverId);
    if (server == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.help_outline_rounded,
          title: '找不到這台伺服器',
          message: '它可能已被刪除。',
        ),
      );
    }
    // 設定被編輯後重新取得連線資料。
    final profile = _profile;
    if (profile != null &&
        _signature != null &&
        server.toJson().toString() != profile.toJson().toString()) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
    }

    final wide = isWide(context);
    final body = profile == null
        ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: '無法載入伺服器',
                  message: _error,
                  error: true,
                  action: FilledButton(
                    onPressed: _resolve,
                    child: const Text('重試'),
                  ),
                ))
        : IndexedStack(
            index: _section.index,
            children: [
              for (final section in DetailSection.values)
                KeyedSubtree(
                  key: ValueKey('${section.name}-$_signature'),
                  child: _buildSection(section, profile),
                ),
            ],
          );

    final appBar = AppBar(
      title: _Title(server: server),
      actions: [
        IconButton(
          tooltip: '執行腳本',
          icon: const Icon(Icons.playlist_play_rounded),
          onPressed: _runScript,
        ),
        IconButton(
          tooltip: '編輯伺服器',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () => _edit(server),
        ),
        PopupMenuButton<String>(
          tooltip: '更多',
          onSelected: (action) async {
            switch (action) {
              case 'reconnect':
                context.read<SSHService>().disconnect(server.id);
                await _monitor.refresh(server.id, interactive: true);
              case 'reboot':
                await powerAction(context, server.id, PowerAction.reboot);
              case 'shutdown':
                await powerAction(context, server.id, PowerAction.shutdown);
              case 'wake':
                await wakeServer(context, server);
              case 'delete':
                if (await deleteServer(context, server) && context.mounted) {
                  Navigator.of(context).pop();
                }
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'reconnect',
              child: ListTile(
                leading: Icon(Icons.sync_rounded),
                title: Text('重新連線'),
              ),
            ),
            if (server.canWake)
              const PopupMenuItem(
                value: 'wake',
                child: ListTile(
                  leading: Icon(Icons.wb_twilight_rounded),
                  title: Text('Wake-on-LAN 喚醒'),
                ),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'reboot',
              child: ListTile(
                leading: Icon(Icons.restart_alt_rounded),
                title: Text('重新啟動'),
              ),
            ),
            const PopupMenuItem(
              value: 'shutdown',
              child: ListTile(
                leading: Icon(Icons.power_settings_new_rounded),
                title: Text('關機'),
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete_outline_rounded),
                title: Text('刪除伺服器'),
              ),
            ),
          ],
        ),
      ],
      bottom: wide
          ? null
          : TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final section in DetailSection.values)
                  Tab(
                    height: 46,
                    icon: null,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          section == _section
                              ? section.selectedIcon
                              : section.icon,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(section.label),
                      ],
                    ),
                  ),
              ],
            ),
    );

    if (!wide) return Scaffold(appBar: appBar, body: body);

    return Scaffold(
      appBar: appBar,
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _section.index,
            onDestinationSelected: (index) =>
                _select(DetailSection.values[index]),
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final section in DetailSection.values)
                NavigationRailDestination(
                  icon: Icon(section.icon),
                  selectedIcon: Icon(section.selectedIcon),
                  label: Text(section.label),
                ),
            ],
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.server});

  final ServerProfile server;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final monitor = context.read<MonitorService>().monitorOf(server.id);
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, _) {
        final color = statusColor(monitor.status, theme);
        return Row(
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    server.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusDot(
                        color: color,
                        animate: monitor.status == ServerStatus.online,
                        size: 7,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '${statusLabel(monitor.status)} · ${server.address}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
