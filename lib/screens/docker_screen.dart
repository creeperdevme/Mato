import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/docker_service.dart';
import '../services/ssh_service.dart';
import '../utils/error_messages.dart';
import '../widgets/common.dart';
import '../widgets/process_output.dart';

/// Docker／Podman 管理：容器、映像檔與資源。
class DockerScreen extends StatefulWidget {
  const DockerScreen({super.key, required this.profile, this.onOpenShell});

  final ServerProfile profile;

  /// 在終端機開新分頁執行指定指令（進入容器 shell）。
  final void Function(String command, String title)? onOpenShell;

  @override
  State<DockerScreen> createState() => _DockerScreenState();
}

enum _View { containers, images, resources }

class _DockerScreenState extends State<DockerScreen> {
  DockerRuntime? _runtime;
  String? _error;
  bool _loading = false;
  _View _view = _View.containers;

  List<DockerContainer>? _containers;
  Map<String, ContainerStats> _stats = const {};
  List<DockerImage>? _images;
  List<DockerVolume>? _volumes;
  List<DockerNetwork>? _networks;
  String? _diskUsage;
  String _query = '';

  DockerService get _docker => context.read<DockerService>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final runtime = _runtime ??= await _docker.detect(widget.profile);
      switch (_view) {
        case _View.containers:
          final containers = await _docker.containers(widget.profile, runtime);
          if (mounted) setState(() => _containers = containers);
          if (containers.any((container) => container.running)) {
            unawaited(_loadStats(runtime));
          }
        case _View.images:
          final images = await _docker.images(widget.profile, runtime);
          if (mounted) setState(() => _images = images);
        case _View.resources:
          final results = await Future.wait([
            _docker.volumes(widget.profile, runtime),
            _docker.networks(widget.profile, runtime),
            _docker.systemDf(widget.profile, runtime).catchError((_) => ''),
          ]);
          if (mounted) {
            setState(() {
              _volumes = results[0] as List<DockerVolume>;
              _networks = results[1] as List<DockerNetwork>;
              _diskUsage = results[2] as String;
            });
          }
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is DockerException
              ? error.message
              : describeSshError(error),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadStats(DockerRuntime runtime) async {
    try {
      final stats = await _docker.stats(widget.profile, runtime);
      if (mounted) setState(() => _stats = stats);
    } catch (_) {
      // docker stats 偶爾會逾時，失敗時就不顯示即時用量。
    }
  }

  Future<void> _guard(String working, Future<void> Function() action) async {
    try {
      await runWithProgress(context, working, action);
      await _load();
    } catch (error) {
      if (mounted) {
        showMessage(
          context,
          error is DockerException ? error.message : describeSshError(error),
          error: true,
        );
      }
    }
  }

  // 容器 ----------------------------------------------------------------------

  Future<void> _containerAction(
    DockerContainer container,
    String action,
  ) async {
    final runtime = _runtime!;
    switch (action) {
      case 'logs':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _LogsScreen(
              profile: widget.profile,
              runtime: runtime,
              container: container,
            ),
          ),
        );
      case 'inspect':
        await _inspect(container.id, container.name);
      case 'shell':
        widget.onOpenShell?.call(
          DockerService.execShellCommand(runtime, container.id),
          '容器 · ${container.name}',
        );
      case 'remove':
        final confirmed = await confirmAction(
          context,
          title: '刪除容器',
          message: '確定要刪除「${container.name}」嗎？執行中的容器會被強制停止。',
          confirmLabel: '刪除',
          destructive: true,
        );
        if (!confirmed || !mounted) return;
        await _guard(
          '正在刪除 ${container.name}…',
          () => _docker.removeContainer(widget.profile, runtime, container.id),
        );
      case 'kill':
        final confirmed = await confirmAction(
          context,
          title: '強制停止容器',
          message: '會直接送出 SIGKILL 給「${container.name}」。',
          confirmLabel: '強制停止',
          destructive: true,
        );
        if (!confirmed || !mounted) return;
        await _guard(
          '正在停止 ${container.name}…',
          () => _docker.containerAction(
            widget.profile,
            runtime,
            container.id,
            'kill',
          ),
        );
      default:
        const labels = {
          'start': '啟動',
          'stop': '停止',
          'restart': '重新啟動',
          'pause': '暫停',
          'unpause': '繼續',
        };
        await _guard(
          '正在${labels[action] ?? action} ${container.name}…',
          () => _docker.containerAction(
            widget.profile,
            runtime,
            container.id,
            action,
          ),
        );
    }
  }

  Future<void> _inspect(String target, String title) async {
    try {
      final raw = await runWithProgress(
        context,
        '讀取中…',
        () => _docker.inspect(widget.profile, _runtime!, target),
      );
      var pretty = raw;
      try {
        pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
      } catch (_) {}
      if (mounted) await showTextOutput(context, title: title, text: pretty);
    } catch (error) {
      if (mounted) showMessage(context, describeSshError(error), error: true);
    }
  }

  Future<void> _create({String image = ''}) async {
    final args = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => _CreateContainerScreen(image: image)),
    );
    if (args == null || !mounted) return;
    final runtime = _runtime!;
    final built = _docker.command(widget.profile, runtime, '$args 2>&1');
    final code = await showProcessOutput(
      context,
      title: '建立容器',
      start: () => context.read<SSHService>().start(
        widget.profile,
        built.command,
        stdin: built.stdin,
      ),
    );
    if (code == 0) {
      setState(() => _view = _View.containers);
      await _load();
    }
  }

  // 映像檔 --------------------------------------------------------------------

  Future<void> _pull() async {
    final image = await promptText(
      context,
      title: '拉取映像檔',
      label: '映像檔名稱',
      hint: '例如 nginx:latest、ghcr.io/owner/app:1.2',
      confirmLabel: '拉取',
      monospace: true,
      validator: (value) => value.trim().isEmpty ? '請輸入映像檔名稱' : null,
    );
    if (image == null || !mounted) return;
    await showProcessOutput(
      context,
      title: '拉取 ${image.trim()}',
      start: () => _docker.pull(widget.profile, _runtime!, image.trim()),
    );
    await _load();
  }

  Future<void> _removeImage(DockerImage image) async {
    final confirmed = await confirmAction(
      context,
      title: '刪除映像檔',
      message: '確定要刪除 ${image.reference}（${image.size}）嗎？',
      confirmLabel: '刪除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _guard(
      '正在刪除映像檔…',
      () => _docker.removeImage(
        widget.profile,
        _runtime!,
        image.repository == '<none>' ? image.id : image.reference,
      ),
    );
  }

  // 資源 ----------------------------------------------------------------------

  Future<void> _prune({required bool all}) async {
    final confirmed = await confirmAction(
      context,
      title: all ? '清理所有未使用資源' : '清理停止的容器與懸置映像檔',
      message: all
          ? '會刪除所有停止的容器、未使用的網路，以及沒有容器使用的映像檔與建置快取。'
          : '會刪除所有停止的容器、未使用的網路、懸置（<none>）映像檔與建置快取。',
      confirmLabel: '清理',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      final output = await runWithProgress(
        context,
        '清理中…',
        () => _docker.prune(widget.profile, _runtime!, all: all),
      );
      if (mounted) await showTextOutput(context, title: '清理結果', text: output);
      await _load();
    } catch (error) {
      if (mounted) showMessage(context, describeSshError(error), error: true);
    }
  }

  // 畫面 ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: runtime == null
          ? null
          : switch (_view) {
              _View.containers => FloatingActionButton.extended(
                onPressed: _create,
                icon: const Icon(Icons.add_rounded),
                label: const Text('新增容器'),
              ),
              _View.images => FloatingActionButton.extended(
                onPressed: _pull,
                icon: const Icon(Icons.download_rounded),
                label: const Text('拉取映像檔'),
              ),
              _View.resources => null,
            },
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<_View>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: _View.containers, label: Text('容器')),
                      ButtonSegment(value: _View.images, label: Text('映像檔')),
                      ButtonSegment(value: _View.resources, label: Text('資源')),
                    ],
                    selected: {_view},
                    onSelectionChanged: (value) {
                      setState(() => _view = value.first);
                      _load();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '重新整理',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
          if (runtime != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  TagChip(label: runtime.label, icon: Icons.view_in_ar_rounded),
                  const Spacer(),
                  if (_loading)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return EmptyState(
        icon: Icons.view_in_ar_outlined,
        title: _runtime == null ? '無法使用 Docker' : '讀取失敗',
        message: _error,
        error: true,
        action: FilledButton(
          onPressed: () {
            _runtime = null;
            _load();
          },
          child: const Text('重試'),
        ),
      );
    }
    switch (_view) {
      case _View.containers:
        final containers = _containers;
        if (containers == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (containers.isEmpty) {
          return const EmptyState(
            icon: Icons.inventory_2_outlined,
            title: '沒有容器',
            message: '按右下角「新增容器」或到映像檔分頁拉取映像檔。',
          );
        }
        final query = _query.toLowerCase();
        final visible = containers
            .where(
              (container) =>
                  query.isEmpty ||
                  container.name.toLowerCase().contains(query) ||
                  container.image.toLowerCase().contains(query),
            )
            .toList();
        final running = containers
            .where((container) => container.running)
            .length;
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
            children: [
              if (containers.length > 6)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: '搜尋容器名稱或映像檔',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(
                  '${containers.length} 個容器 · $running 個執行中',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              for (final container in visible) ...[
                _ContainerCard(
                  container: container,
                  stats: _docker.statsFor(_stats, container.id),
                  canOpenShell: widget.onOpenShell != null,
                  onAction: (action) => _containerAction(container, action),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        );
      case _View.images:
        final images = _images;
        if (images == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (images.isEmpty) {
          return const EmptyState(
            icon: Icons.layers_outlined,
            title: '沒有映像檔',
            message: '按右下角「拉取映像檔」下載。',
          );
        }
        return RefreshIndicator(
          onRefresh: _load,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
            itemCount: images.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final image = images[index];
              return SurfaceCard(
                padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
                child: Row(
                  children: [
                    Icon(
                      Icons.layers_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            image.repository == '<none>'
                                ? '<none>'
                                : '${image.repository}:${image.tag}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '${image.id} · ${image.size} · ${image.created}',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        switch (value) {
                          case 'run':
                            _create(image: image.reference);
                          case 'inspect':
                            _inspect(image.id, image.reference);
                          case 'remove':
                            _removeImage(image);
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'run', child: Text('用這個映像檔建立容器')),
                        PopupMenuItem(value: 'inspect', child: Text('檢視詳細資料')),
                        PopupMenuItem(value: 'remove', child: Text('刪除')),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      case _View.resources:
        return _buildResources();
    }
  }

  Widget _buildResources() {
    final volumes = _volumes;
    final networks = _networks;
    if (volumes == null || networks == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          if ((_diskUsage ?? '').isNotEmpty) ...[
            const SectionHeader(
              title: '磁碟用量',
              padding: EdgeInsets.fromLTRB(4, 8, 4, 8),
            ),
            SurfaceCard(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(_diskUsage!, style: monoStyle(fontSize: 12)),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _prune(all: false),
                icon: const Icon(Icons.cleaning_services_outlined),
                label: const Text('清理懸置資源'),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                onPressed: () => _prune(all: true),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('清理所有未使用資源'),
              ),
            ],
          ),
          SectionHeader(
            title: '磁碟區',
            caption: '${volumes.length} 個',
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          ),
          if (volumes.isEmpty)
            const Padding(padding: EdgeInsets.all(8), child: Text('沒有磁碟區'))
          else
            SurfaceCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final volume in volumes)
                    ListTile(
                      leading: const Icon(Icons.storage_rounded),
                      title: Text(
                        volume.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(volume.driver),
                      trailing: IconButton(
                        tooltip: '刪除',
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () async {
                          final ok = await confirmAction(
                            context,
                            title: '刪除磁碟區',
                            message: '「${volume.name}」中的資料會永久刪除。',
                            confirmLabel: '刪除',
                            destructive: true,
                          );
                          if (!ok || !mounted) return;
                          await _guard(
                            '刪除中…',
                            () => _docker.removeVolume(
                              widget.profile,
                              _runtime!,
                              volume.name,
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          SectionHeader(
            title: '網路',
            caption: '${networks.length} 個',
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          ),
          SurfaceCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final network in networks)
                  ListTile(
                    leading: const Icon(Icons.hub_outlined),
                    title: Text(network.name),
                    subtitle: Text(
                      '${network.driver} · ${network.scope} · ${network.id}',
                    ),
                    trailing: network.builtIn
                        ? null
                        : IconButton(
                            tooltip: '刪除',
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: () async {
                              final ok = await confirmAction(
                                context,
                                title: '刪除網路',
                                message: '確定要刪除網路「${network.name}」嗎？',
                                confirmLabel: '刪除',
                                destructive: true,
                              );
                              if (!ok || !mounted) return;
                              await _guard(
                                '刪除中…',
                                () => _docker.removeNetwork(
                                  widget.profile,
                                  _runtime!,
                                  network.id,
                                ),
                              );
                            },
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

class _ContainerCard extends StatelessWidget {
  const _ContainerCard({
    required this.container,
    required this.stats,
    required this.canOpenShell,
    required this.onAction,
  });

  final DockerContainer container;
  final ContainerStats? stats;
  final bool canOpenShell;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = container.running
        ? const Color(0xFF2E7D32)
        : container.paused
        ? const Color(0xFFF9A825)
        : scheme.outline;
    final stateLabel = switch (container.state) {
      'running' => '執行中',
      'paused' => '已暫停',
      'exited' => '已停止',
      'created' => '已建立',
      'restarting' => '重新啟動中',
      'dead' => '已終止',
      _ => container.state,
    };

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 6, 6),
      onTap: () => onAction('logs'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.inventory_2_rounded, color: color, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  container.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TagChip(label: stateLabel, color: color),
              const SizedBox(width: 8),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 34, right: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  container.image,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(container.status, style: theme.textTheme.labelSmall),
                if (container.ports.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      container.ports,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ),
                if (stats != null && container.running)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        TagChip(label: 'CPU ${stats!.cpu}', icon: Icons.memory),
                        TagChip(
                          label: '記憶體 ${stats!.memUsage}',
                          icon: Icons.developer_board_outlined,
                        ),
                        TagChip(
                          label: '網路 ${stats!.netIO}',
                          icon: Icons.lan_outlined,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (container.running)
                IconButton(
                  tooltip: '停止',
                  onPressed: () => onAction('stop'),
                  icon: const Icon(Icons.stop_rounded),
                )
              else if (container.paused)
                IconButton(
                  tooltip: '繼續',
                  onPressed: () => onAction('unpause'),
                  icon: const Icon(Icons.play_arrow_rounded),
                )
              else
                IconButton(
                  tooltip: '啟動',
                  onPressed: () => onAction('start'),
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
              IconButton(
                tooltip: '重新啟動',
                onPressed: () => onAction('restart'),
                icon: const Icon(Icons.restart_alt_rounded),
              ),
              IconButton(
                tooltip: '日誌',
                onPressed: () => onAction('logs'),
                icon: const Icon(Icons.receipt_long_outlined),
              ),
              if (canOpenShell && container.running)
                IconButton(
                  tooltip: '進入容器 shell',
                  onPressed: () => onAction('shell'),
                  icon: const Icon(Icons.terminal_rounded),
                ),
              PopupMenuButton<String>(
                onSelected: onAction,
                itemBuilder: (context) => [
                  if (container.running)
                    const PopupMenuItem(value: 'pause', child: Text('暫停')),
                  if (container.running)
                    const PopupMenuItem(
                      value: 'kill',
                      child: Text('強制停止 (kill)'),
                    ),
                  const PopupMenuItem(value: 'inspect', child: Text('檢視詳細資料')),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'remove', child: Text('刪除容器')),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 容器日誌：可切換即時追蹤（`logs -f`）。
class _LogsScreen extends StatefulWidget {
  const _LogsScreen({
    required this.profile,
    required this.runtime,
    required this.container,
  });

  final ServerProfile profile;
  final DockerRuntime runtime;
  final DockerContainer container;

  @override
  State<_LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<_LogsScreen> {
  final _scroll = ScrollController();
  final _buffer = StringBuffer();
  RemoteProcess? _follow;
  StreamSubscription<String>? _subscription;
  bool _loading = true;
  bool _following = false;
  int _tail = 300;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _stopFollow();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _load() async {
    _stopFollow();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final text = await context.read<DockerService>().logs(
        widget.profile,
        widget.runtime,
        widget.container.id,
        tail: _tail,
      );
      _buffer
        ..clear()
        ..write(text);
      _scrollToEnd();
    } catch (error) {
      _error = describeSshError(error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startFollow() async {
    _stopFollow();
    setState(() {
      _following = true;
      _buffer.clear();
    });
    try {
      final process = await context.read<DockerService>().followLogs(
        widget.profile,
        widget.runtime,
        widget.container.id,
      );
      _follow = process;
      _subscription = process.output.listen((chunk) {
        _buffer.write(chunk);
        if (_buffer.length > 500000) {
          final text = _buffer.toString();
          _buffer
            ..clear()
            ..write(text.substring(text.length - 400000));
        }
        if (mounted) setState(() {});
        _scrollToEnd();
      });
      unawaited(
        process.exitCode.then((_) {
          if (mounted) setState(() => _following = false);
        }),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _following = false;
          _error = describeSshError(error);
        });
      }
    }
  }

  void _stopFollow() {
    _subscription?.cancel();
    _subscription = null;
    _follow?.kill();
    _follow = null;
    _following = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.container.name} 日誌'),
        actions: [
          PopupMenuButton<int>(
            tooltip: '行數',
            initialValue: _tail,
            icon: const Icon(Icons.format_list_numbered_rounded),
            onSelected: (value) {
              setState(() => _tail = value);
              _load();
            },
            itemBuilder: (context) => [
              for (final value in const [100, 300, 1000, 5000])
                PopupMenuItem(value: value, child: Text('最後 $value 行')),
            ],
          ),
          IconButton(
            tooltip: _following ? '停止追蹤' : '即時追蹤',
            isSelected: _following,
            onPressed: () =>
                _following ? setState(_stopFollow) : _startFollow(),
            icon: Icon(
              _following
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
            ),
          ),
          IconButton(
            tooltip: '重新整理',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '複製',
            onPressed: () => copyText(context, _buffer.toString(), label: '日誌'),
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? EmptyState(
              icon: Icons.receipt_long_outlined,
              title: '無法讀取日誌',
              message: _error,
              error: true,
            )
          : Container(
              color: const Color(0xFF101614),
              child: Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: SelectableText(
                      _buffer.isEmpty ? '（沒有日誌）' : _buffer.toString(),
                      style: monoStyle(
                        fontSize: 12,
                        color: const Color(0xFFD8E3DC),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// 建立容器表單，回傳 `docker run` 參數。
class _CreateContainerScreen extends StatefulWidget {
  const _CreateContainerScreen({this.image = ''});

  final String image;

  @override
  State<_CreateContainerScreen> createState() => _CreateContainerScreenState();
}

class _CreateContainerScreenState extends State<_CreateContainerScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _image = TextEditingController(text: widget.image);
  final _name = TextEditingController();
  final _ports = TextEditingController();
  final _env = TextEditingController();
  final _volumes = TextEditingController();
  final _network = TextEditingController();
  final _command = TextEditingController();
  final _extra = TextEditingController();
  String _restart = 'unless-stopped';

  @override
  void dispose() {
    for (final controller in [
      _image,
      _name,
      _ports,
      _env,
      _volumes,
      _network,
      _command,
      _extra,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<String> _lines(TextEditingController controller) => controller.text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  String get _args => DockerService.runArgs(
    image: _image.text,
    name: _name.text,
    ports: _lines(_ports),
    env: _lines(_env),
    volumes: _lines(_volumes),
    restart: _restart,
    network: _network.text,
    extra: _extra.text,
    command: _command.text,
  );

  @override
  Widget build(BuildContext context) {
    InputDecoration field(String label, {String? hint, String? helper}) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          alignLabelWithHint: true,
        );

    return Scaffold(
      appBar: AppBar(title: const Text('新增容器')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ReadableWidth(
              maxWidth: 720,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _image,
                    style: monoStyle(fontSize: 14),
                    decoration: field('映像檔', hint: 'nginx:latest'),
                    validator: (value) =>
                        (value ?? '').trim().isEmpty ? '請輸入映像檔' : null,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _name,
                    decoration: field('容器名稱（選填）'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _ports,
                    minLines: 1,
                    maxLines: 4,
                    style: monoStyle(fontSize: 13),
                    decoration: field('連接埠對應（每行一個）', hint: '8080:80'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _env,
                    minLines: 1,
                    maxLines: 6,
                    style: monoStyle(fontSize: 13),
                    decoration: field('環境變數（每行一個）', hint: 'TZ=Asia/Taipei'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _volumes,
                    minLines: 1,
                    maxLines: 4,
                    style: monoStyle(fontSize: 13),
                    decoration: field('掛載（每行一個）', hint: '/srv/data:/data'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: _restart,
                    decoration: field('重新啟動策略'),
                    items: const [
                      DropdownMenuItem(value: 'no', child: Text('不自動重啟 (no)')),
                      DropdownMenuItem(
                        value: 'always',
                        child: Text('永遠 (always)'),
                      ),
                      DropdownMenuItem(
                        value: 'unless-stopped',
                        child: Text('除非手動停止 (unless-stopped)'),
                      ),
                      DropdownMenuItem(
                        value: 'on-failure',
                        child: Text('失敗時 (on-failure)'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _restart = value ?? 'no'),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _network,
                    decoration: field('網路（選填）', hint: 'bridge'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _command,
                    style: monoStyle(fontSize: 13),
                    decoration: field('啟動指令（選填）'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _extra,
                    style: monoStyle(fontSize: 13),
                    decoration: field(
                      '其他參數（選填）',
                      hint: '--memory 512m --cpus 1',
                      helper: '原樣附加在 docker run 之後',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 18),
                  Text('預覽', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  SurfaceCard(
                    child: SelectableText(
                      'docker $_args',
                      style: monoStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () {
                      if (_formKey.currentState?.validate() ?? false) {
                        Navigator.pop(context, _args);
                      }
                    },
                    icon: const Icon(Icons.rocket_launch_outlined),
                    label: const Text('建立並啟動'),
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
