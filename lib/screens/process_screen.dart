import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/process_info.dart';
import '../models/server_profile.dart';
import '../services/ssh_service.dart';
import '../utils/error_messages.dart';
import '../utils/format.dart';
import '../widgets/common.dart';

enum _SortKey { cpu, memory, pid, name }

/// 程序管理：列出所有程序、排序、搜尋，並送出訊號結束程序。
class ProcessScreen extends StatefulWidget {
  const ProcessScreen({super.key, required this.profile});

  final ServerProfile profile;

  @override
  State<ProcessScreen> createState() => _ProcessScreenState();
}

class _ProcessScreenState extends State<ProcessScreen> {
  List<ProcessInfo>? _processes;
  String? _error;
  bool _loading = false;
  bool _autoRefresh = true;
  bool _hideKernel = true;
  String _query = '';
  _SortKey _sort = _SortKey.cpu;
  bool _descending = true;
  Timer? _timer;

  /// 所在分頁是否可見（IndexedStack 中被切走時暫停自動更新）。
  bool _tabVisible = true;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_autoRefresh && mounted && !_loading && _tabVisible) {
        _load(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final result = await context.read<SSHService>().run(
        widget.profile,
        ProcessInfo.command,
      );
      final list = ProcessInfo.parse(result.stdout);
      if (list.isEmpty && !result.success) {
        throw SshException(
          result.stderr.trim().isEmpty ? '無法取得程序列表' : result.stderr.trim(),
        );
      }
      if (!mounted) return;
      setState(() {
        _processes = list;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = describeSshError(error));
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  List<ProcessInfo> get _visible {
    final query = _query.trim().toLowerCase();
    final list = (_processes ?? const <ProcessInfo>[]).where((process) {
      if (_hideKernel && process.isKernelThread) return false;
      if (query.isEmpty) return true;
      return process.args.toLowerCase().contains(query) ||
          process.user.toLowerCase().contains(query) ||
          '${process.pid}' == query;
    }).toList();
    int compare(ProcessInfo a, ProcessInfo b) => switch (_sort) {
      _SortKey.cpu => a.cpu.compareTo(b.cpu),
      _SortKey.memory => a.rssKb.compareTo(b.rssKb),
      _SortKey.pid => a.pid.compareTo(b.pid),
      _SortKey.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    };
    list.sort((a, b) => _descending ? compare(b, a) : compare(a, b));
    return list;
  }

  void _setSort(_SortKey key) {
    setState(() {
      if (_sort == key) {
        _descending = !_descending;
      } else {
        _sort = key;
        _descending = key == _SortKey.cpu || key == _SortKey.memory;
      }
    });
  }

  Future<void> _signal(ProcessInfo process, String signal) async {
    final destructive = signal == 'KILL' || signal == 'TERM';
    if (destructive) {
      final confirmed = await confirmAction(
        context,
        title: '${processSignals[signal]}',
        message: '確定要對 ${process.name}（PID ${process.pid}）送出 SIG$signal 嗎？',
        confirmLabel: '送出',
        destructive: true,
      );
      if (!confirmed || !mounted) return;
    }
    final ssh = context.read<SSHService>();
    final command = 'kill -$signal ${process.pid}';
    try {
      var result = await ssh.run(widget.profile, command);
      final denied = result.stderr.toLowerCase().contains('not permitted');
      if (denied && mounted) {
        final retry = await confirmAction(
          context,
          title: '權限不足',
          message: '這個程序屬於 ${process.user}，要改用 sudo 送出訊號嗎？',
          confirmLabel: '使用 sudo',
        );
        if (!retry) return;
        result = await ssh.runPrivileged(widget.profile, command);
      }
      if (!mounted) return;
      if (result.success) {
        showMessage(context, '已送出 SIG$signal 給 PID ${process.pid}');
        await _load(silent: true);
      } else {
        showMessage(
          context,
          '送出失敗：${result.stderr.trim().isEmpty ? '結束代碼 ${result.exitCode}' : result.stderr.trim()}',
          error: true,
        );
      }
    } catch (error) {
      if (mounted) showMessage(context, describeSshError(error), error: true);
    }
  }

  void _details(ProcessInfo process) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  process.name,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'PID ${process.pid} · 父程序 ${process.ppid} · ${process.user} · ${process.stateLabel}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 160),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      process.args,
                      style: monoStyle(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text('CPU ${process.cpu.toStringAsFixed(1)}%'),
                    Text('記憶體 ${process.memory.toStringAsFixed(1)}%'),
                    Text('RSS ${formatBytes(process.rssKb * 1024)}'),
                    if (process.elapsed != null)
                      Text('已執行 ${formatDuration(process.elapsed!)}'),
                  ],
                ),
                const SizedBox(height: 16),
                Text('送出訊號', style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in processSignals.entries)
                      ActionChip(
                        avatar: Icon(
                          entry.key == 'KILL' || entry.key == 'TERM'
                              ? Icons.stop_circle_outlined
                              : Icons.send_rounded,
                          size: 18,
                        ),
                        label: Text(entry.value),
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _signal(process, entry.key);
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    _tabVisible = Visibility.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final processes = _processes;
    final visible = _visible;
    final running =
        processes?.where((process) => process.isRunning).length ?? 0;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: '搜尋指令、使用者或 PID',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: _autoRefresh ? '暫停自動更新' : '自動更新',
                onPressed: () => setState(() => _autoRefresh = !_autoRefresh),
                icon: Icon(
                  _autoRefresh ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              IconButton(
                tooltip: '重新整理',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              for (final (key, label) in const [
                (_SortKey.cpu, 'CPU'),
                (_SortKey.memory, '記憶體'),
                (_SortKey.pid, 'PID'),
                (_SortKey.name, '名稱'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(label),
                    selected: _sort == key,
                    showCheckmark: false,
                    avatar: _sort == key
                        ? Icon(
                            _descending
                                ? Icons.arrow_downward_rounded
                                : Icons.arrow_upward_rounded,
                            size: 16,
                          )
                        : null,
                    onSelected: (_) => _setSort(key),
                  ),
                ),
              FilterChip(
                label: const Text('隱藏核心執行緒'),
                selected: _hideKernel,
                onSelected: (value) => setState(() => _hideKernel = value),
              ),
            ],
          ),
        ),
        if (processes != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: Row(
              children: [
                Text(
                  '共 ${processes.length} 個程序 · 執行中 $running · 顯示 ${visible.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
              ],
            ),
          ),
        Expanded(
          child: processes == null
              ? (_error == null
                    ? const Center(child: CircularProgressIndicator())
                    : EmptyState(
                        icon: Icons.view_list_outlined,
                        title: '無法取得程序列表',
                        message: _error,
                        error: true,
                        action: FilledButton(
                          onPressed: _load,
                          child: const Text('重試'),
                        ),
                      ))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: visible.length,
                    itemBuilder: (context, index) => _ProcessTile(
                      process: visible[index],
                      onTap: () => _details(visible[index]),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ProcessTile extends StatelessWidget {
  const _ProcessTile({required this.process, required this.onTap});

  final ProcessInfo process;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cpuColor = usageColor(
      process.cpu.clamp(0, 100).toDouble(),
      scheme.primary,
    );

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 58,
              child: Text(
                '${process.pid}',
                style: monoStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          process.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (process.isZombie) ...[
                        const SizedBox(width: 6),
                        TagChip(label: '殭屍', color: scheme.error),
                      ],
                    ],
                  ),
                  Text(
                    '${process.user} · ${process.args}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 58,
              child: Text(
                '${process.cpu.toStringAsFixed(1)}%',
                textAlign: TextAlign.right,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: process.cpu >= 1 ? cpuColor : scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            SizedBox(
              width: 76,
              child: Text(
                formatBytes(process.rssKb * 1024),
                textAlign: TextAlign.right,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
