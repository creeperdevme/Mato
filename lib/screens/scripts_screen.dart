import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/script.dart';
import '../models/server_profile.dart';
import '../services/script_store.dart';
import '../services/server_store.dart';
import '../services/ssh_service.dart';
import '../utils/format.dart';
import '../widgets/common.dart';

/// 腳本庫與批次執行紀錄。
class ScriptsScreen extends StatelessWidget {
  const ScriptsScreen({super.key});

  Future<void> _edit(BuildContext context, [Script? script]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScriptEditorScreen(script: script),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('腳本'),
          actions: [
            IconButton(
              tooltip: '執行臨時指令',
              icon: const Icon(Icons.play_circle_outline_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ScriptRunnerScreen(),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '腳本庫'),
              Tab(text: '執行紀錄'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(context),
          icon: const Icon(Icons.add_rounded),
          label: const Text('新增腳本'),
        ),
        body: TabBarView(
          children: [
            _Library(onEdit: (script) => _edit(context, script)),
            const _History(),
          ],
        ),
      ),
    );
  }
}

class _Library extends StatelessWidget {
  const _Library({required this.onEdit});

  final ValueChanged<Script> onEdit;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ScriptStore>();
    final scripts = store.scripts;
    if (scripts.isEmpty) {
      return const EmptyState(
        icon: Icons.terminal_rounded,
        title: '腳本庫是空的',
        message:
            '把常用的維護指令存成腳本，就能一次在多台伺服器上執行，'
            '也能在終端機當成快捷片段使用。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: scripts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final script = scripts[index];
        return ReadableWidth(
          child: SurfaceCard(
            onTap: () => onEdit(script),
            padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              script.name,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          if (script.useSudo) ...[
                            const SizedBox(width: 8),
                            const TagChip(
                              label: 'sudo',
                              icon: Icons.shield_outlined,
                            ),
                          ],
                        ],
                      ),
                      if (script.description.isNotEmpty)
                        Text(
                          script.description,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      const SizedBox(height: 4),
                      Text(
                        script.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: '執行',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ScriptRunnerScreen(script: script),
                    ),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) async {
                    switch (value) {
                      case 'edit':
                        onEdit(script);
                      case 'duplicate':
                        await store.save(
                          Script(
                            id: '',
                            name: '${script.name} 副本',
                            content: script.content,
                            description: script.description,
                            useSudo: script.useSudo,
                            createdAt: DateTime.now(),
                            updatedAt: DateTime.now(),
                          ),
                        );
                      case 'delete':
                        final ok = await confirmAction(
                          context,
                          title: '刪除腳本',
                          message: '確定要刪除「${script.name}」嗎？',
                          confirmLabel: '刪除',
                          destructive: true,
                        );
                        if (ok) await store.delete(script.id);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'edit', child: Text('編輯')),
                    PopupMenuItem(value: 'duplicate', child: Text('複製一份')),
                    PopupMenuItem(value: 'delete', child: Text('刪除')),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _History extends StatelessWidget {
  const _History();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ScriptStore>();
    final runs = store.runs;
    if (runs.isEmpty) {
      return const EmptyState(
        icon: Icons.history_rounded,
        title: '還沒有執行紀錄',
        message: '在腳本庫按 ▶ 選擇伺服器後執行，結果會保存在這裡。',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              final ok = await confirmAction(
                context,
                title: '清除執行紀錄',
                message: '會刪除所有已完成的執行紀錄。',
                confirmLabel: '清除',
              );
              if (ok) await store.clearRuns();
            },
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('清除紀錄'),
          ),
        ),
        for (final run in runs) ...[
          ReadableWidth(child: _RunTile(run: run)),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({required this.run});

  final ScriptRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final finished = run.finished;
    final allOk = finished && run.failedCount == 0;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ScriptRunDetailScreen(runId: run.id),
        ),
      ),
      child: Row(
        children: [
          if (!finished)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          else
            Icon(
              allOk ? Icons.check_circle_rounded : Icons.error_rounded,
              color: allOk ? const Color(0xFF2E7D32) : scheme.error,
            ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  run.scriptName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${formatRelative(run.startedAt)} · ${run.results.length} 台 · '
                  '成功 ${run.successCount} · 失敗 ${run.failedCount}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

/// 新增／編輯腳本。
class ScriptEditorScreen extends StatefulWidget {
  const ScriptEditorScreen({super.key, this.script});

  final Script? script;

  @override
  State<ScriptEditorScreen> createState() => _ScriptEditorScreenState();
}

class _ScriptEditorScreenState extends State<ScriptEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.script?.name ?? '');
  late final _description = TextEditingController(
    text: widget.script?.description ?? '',
  );
  late final _content = TextEditingController(
    text: widget.script?.content ?? '',
  );
  late bool _sudo = widget.script?.useSudo ?? false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save({bool run = false}) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final store = context.read<ScriptStore>();
    final now = DateTime.now();
    final saved = await store.save(
      (widget.script ??
              Script(
                id: '',
                name: '',
                content: '',
                createdAt: now,
                updatedAt: now,
              ))
          .copyWith(
            name: _name.text.trim(),
            description: _description.text.trim(),
            content: _content.text.trimRight(),
            useSudo: _sudo,
          ),
    );
    if (!mounted) return;
    if (run) {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ScriptRunnerScreen(script: saved),
        ),
      );
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.script == null ? '新增腳本' : '編輯腳本'),
        actions: [
          TextButton.icon(
            onPressed: () => _save(run: true),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('儲存並執行'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('儲存')),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ReadableWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '名稱'),
                    validator: (value) =>
                        (value ?? '').trim().isEmpty ? '請輸入名稱' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _description,
                    decoration: const InputDecoration(labelText: '說明（選填）'),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _content,
                    minLines: 10,
                    maxLines: 30,
                    style: monoStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: '腳本內容',
                      hintText: '#!/bin/bash 可省略；會以 bash（沒有時改用 sh）執行',
                      alignLabelWithHint: true,
                    ),
                    validator: (value) =>
                        (value ?? '').trim().isEmpty ? '請輸入腳本內容' : null,
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _sudo,
                    onChanged: (value) => setState(() => _sudo = value),
                    title: const Text('預設以 sudo 執行'),
                    subtitle: const Text('使用各伺服器儲存的密碼回應 sudo；root 帳號會直接執行'),
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

/// 選擇伺服器並執行腳本（或臨時指令）。
class ScriptRunnerScreen extends StatefulWidget {
  const ScriptRunnerScreen({
    super.key,
    this.script,
    this.preselectedServerIds = const {},
  });

  final Script? script;
  final Set<String> preselectedServerIds;

  @override
  State<ScriptRunnerScreen> createState() => _ScriptRunnerScreenState();
}

class _ScriptRunnerScreenState extends State<ScriptRunnerScreen> {
  late final Set<String> _selected = {...widget.preselectedServerIds};
  late String? _scriptId = widget.script?.id;
  late final _adhoc = TextEditingController();
  late bool _sudo = widget.script?.useSudo ?? false;

  @override
  void dispose() {
    _adhoc.dispose();
    super.dispose();
  }

  void _run(List<ServerProfile> servers, Script? script) {
    final content = script?.content ?? _adhoc.text.trim();
    if (content.isEmpty) {
      showMessage(context, '請選擇腳本或輸入指令', error: true);
      return;
    }
    if (_selected.isEmpty) {
      showMessage(context, '請至少選擇一台伺服器', error: true);
      return;
    }
    final store = context.read<ServerStore>();
    final run = context.read<ScriptStore>().startRun(
      name: script?.name ?? (content.split('\n').first),
      content: content,
      sudo: _sudo,
      targets: servers
          .where((server) => _selected.contains(server.id))
          .toList(),
      resolve: store.resolve,
      ssh: context.read<SSHService>(),
    );
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ScriptRunDetailScreen(runId: run.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final servers = context.watch<ServerStore>().servers;
    final groups = context.watch<ServerStore>().groups;
    final scripts = context.watch<ScriptStore>().scripts;
    final script = scripts.where((item) => item.id == _scriptId).firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('執行腳本')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: () => _run(servers, script),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text('在 ${_selected.length} 台伺服器上執行'),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ReadableWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String?>(
                  initialValue: _scriptId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '腳本'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('臨時指令（不存入腳本庫）'),
                    ),
                    for (final item in scripts)
                      DropdownMenuItem<String?>(
                        value: item.id,
                        child: Text(item.name),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _scriptId = value;
                    final selected = scripts
                        .where((item) => item.id == value)
                        .firstOrNull;
                    if (selected != null) _sudo = selected.useSudo;
                  }),
                ),
                const SizedBox(height: 12),
                if (script == null)
                  TextField(
                    controller: _adhoc,
                    minLines: 3,
                    maxLines: 12,
                    style: monoStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: '指令',
                      hintText: 'uptime && df -h',
                      alignLabelWithHint: true,
                    ),
                  )
                else
                  SurfaceCard(
                    child: Text(
                      script.content,
                      maxLines: 12,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(fontSize: 12),
                    ),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _sudo,
                  onChanged: (value) => setState(() => _sudo = value),
                  title: const Text('以 sudo 執行'),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text('伺服器', style: theme.textTheme.titleSmall),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() {
                        if (_selected.length == servers.length) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(servers.map((server) => server.id));
                        }
                      }),
                      child: Text(
                        _selected.length == servers.length ? '全部取消' : '全選',
                      ),
                    ),
                  ],
                ),
                if (groups.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final group in groups)
                        ActionChip(
                          avatar: const Icon(Icons.folder_outlined, size: 16),
                          label: Text('選取「$group」'),
                          onPressed: () => setState(() {
                            _selected.addAll(
                              servers
                                  .where((server) => server.group == group)
                                  .map((server) => server.id),
                            );
                          }),
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                if (servers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('還沒有伺服器'),
                  ),
                for (final server in servers)
                  CheckboxListTile(
                    value: _selected.contains(server.id),
                    onChanged: (value) => setState(() {
                      if (value ?? false) {
                        _selected.add(server.id);
                      } else {
                        _selected.remove(server.id);
                      }
                    }),
                    title: Text(server.name),
                    subtitle: Text(
                      server.group.isEmpty
                          ? server.address
                          : '${server.address} · ${server.group}',
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

/// 一次批次執行的結果。
class ScriptRunDetailScreen extends StatelessWidget {
  const ScriptRunDetailScreen({super.key, required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ScriptStore>();
    final run = store.runById(runId);
    if (run == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(icon: Icons.history_rounded, title: '找不到這筆紀錄'),
      );
    }
    final theme = Theme.of(context);
    final done = run.results.where((result) => result.finished).length;
    final failed = run.results
        .where((result) => result.state == ScriptResultState.failed)
        .map((result) => result.serverId)
        .toSet();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          run.scriptName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (run.finished && failed.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                final servers = context.read<ServerStore>();
                final again = store.startRun(
                  name: run.scriptName,
                  content: run.content,
                  sudo: run.sudo,
                  targets: [for (final id in failed) ?servers.byId(id)],
                  resolve: servers.resolve,
                  ssh: context.read<SSHService>(),
                );
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => ScriptRunDetailScreen(runId: again.id),
                  ),
                );
              },
              icon: const Icon(Icons.replay_rounded),
              label: const Text('重跑失敗的'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ReadableWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${formatDateTime(run.startedAt)} · ${run.sudo ? 'sudo · ' : ''}'
                  '完成 $done/${run.results.length} · 成功 ${run.successCount} · 失敗 ${run.failedCount}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: run.results.isEmpty ? 1 : done / run.results.length,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(2),
                ),
                const SizedBox(height: 12),
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      shape: const Border(),
                      collapsedShape: const Border(),
                      title: const Text('腳本內容'),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [
                        SelectableText(
                          run.content,
                          style: monoStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                for (final result in run.results) ...[
                  _ResultCard(result: result),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final ScriptRunResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color, label) = switch (result.state) {
      ScriptResultState.pending => (
        Icons.schedule_rounded,
        scheme.outline,
        '等待中',
      ),
      ScriptResultState.running => (Icons.sync_rounded, scheme.primary, '執行中'),
      ScriptResultState.success => (
        Icons.check_circle_rounded,
        const Color(0xFF2E7D32),
        '成功',
      ),
      ScriptResultState.failed => (Icons.error_rounded, scheme.error, '失敗'),
    };
    final output = [
      if (result.output.isNotEmpty) result.output.trimRight(),
      ?result.error,
    ].join('\n');

    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: result.state == ScriptResultState.failed,
          shape: const Border(),
          collapsedShape: const Border(),
          leading: result.state == ScriptResultState.running
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, color: color),
          title: Text(result.serverName),
          subtitle: Text(
            [
              label,
              if (result.exitCode != null) '結束代碼 ${result.exitCode}',
              if (result.duration != null)
                '${(result.duration!.inMilliseconds / 1000).toStringAsFixed(1)} 秒',
            ].join(' · '),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 360),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF101614),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                reverse: result.state == ScriptResultState.running,
                child: SelectableText(
                  output.isEmpty ? '（沒有輸出）' : output,
                  style: monoStyle(
                    fontSize: 12,
                    color: const Color(0xFFD8E3DC),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
