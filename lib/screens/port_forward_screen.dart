import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/port_forward.dart';
import '../models/server_profile.dart';
import '../services/port_forward_service.dart';
import '../services/ssh_service.dart';
import '../utils/format.dart';
import '../widgets/common.dart';

/// 連接埠轉發：本機轉發（-L）與 SOCKS5 動態轉發（-D）。
class PortForwardScreen extends StatelessWidget {
  const PortForwardScreen({super.key, required this.profile});

  final ServerProfile profile;

  Future<void> _edit(BuildContext context, [PortForwardRule? rule]) async {
    final result = await showDialog<PortForwardRule>(
      context: context,
      builder: (_) => _RuleDialog(serverId: profile.id, rule: rule),
    );
    if (result == null || !context.mounted) return;
    await context.read<PortForwardService>().saveRule(result);
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<PortForwardService>();
    final rules = service.rulesOf(profile.id);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: rules.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('新增轉發'),
            ),
      body: rules.isEmpty
          ? EmptyState(
              icon: Icons.swap_horiz_rounded,
              title: '還沒有轉發規則',
              message:
                  '把伺服器內部的服務（資料庫、管理介面…）安全地轉到本機，'
                  '或建立 SOCKS5 代理讓流量經由伺服器送出。',
              action: FilledButton.icon(
                onPressed: () => _edit(context),
                icon: const Icon(Icons.add_rounded),
                label: const Text('新增轉發'),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: rules.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final rule = rules[index];
                return _RuleCard(
                  rule: rule,
                  profile: profile,
                  onEdit: () => _edit(context, rule),
                );
              },
            ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.profile,
    required this.onEdit,
  });

  final PortForwardRule rule;
  final ServerProfile profile;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final service = context.watch<PortForwardService>();
    final active = service.activeOf(rule.id);
    final starting = service.isStarting(rule.id);
    final error = service.errorOf(rule.id);
    final running = active != null;

    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                rule.kind == ForwardKind.dynamic
                    ? Icons.public_rounded
                    : Icons.swap_horiz_rounded,
                color: running
                    ? const Color(0xFF2E7D32)
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.name.isEmpty ? rule.summary : rule.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(rule.summary, style: monoStyle(fontSize: 12)),
                  ],
                ),
              ),
              if (starting)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Switch(
                  value: running,
                  onChanged: (value) {
                    if (value) {
                      service.start(rule, profile, context.read<SSHService>());
                    } else {
                      service.stop(rule.id);
                    }
                  },
                ),
              PopupMenuButton<String>(
                onSelected: (value) async {
                  switch (value) {
                    case 'edit':
                      onEdit();
                    case 'copy':
                      await copyText(
                        context,
                        '${rule.bindAddress}:${rule.localPort}',
                        label: '本機位址',
                      );
                    case 'delete':
                      final ok = await confirmAction(
                        context,
                        title: '刪除轉發規則',
                        message:
                            '確定要刪除「${rule.name.isEmpty ? rule.summary : rule.name}」嗎？',
                        confirmLabel: '刪除',
                        destructive: true,
                      );
                      if (ok) await service.deleteRule(rule.id);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('編輯')),
                  PopupMenuItem(value: 'copy', child: Text('複製本機位址')),
                  PopupMenuItem(value: 'delete', child: Text('刪除')),
                ],
              ),
            ],
          ),
          if (running || error != null || rule.autoStart) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (running) ...[
                    TagChip(
                      label: '執行中 · ${formatRelative(active.startedAt)}啟動',
                      icon: Icons.play_circle_outline,
                      color: const Color(0xFF2E7D32),
                    ),
                    if (rule.kind == ForwardKind.local)
                      TagChip(
                        label:
                            '${active.openConnections} 個連線（累計 ${active.totalConnections}）',
                        icon: Icons.cable_rounded,
                      ),
                  ],
                  if (rule.autoStart)
                    const TagChip(label: '自動啟動', icon: Icons.bolt_rounded),
                  if (error != null)
                    TagChip(
                      label: error,
                      icon: Icons.error_outline,
                      color: scheme.error,
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

class _RuleDialog extends StatefulWidget {
  const _RuleDialog({required this.serverId, this.rule});

  final String serverId;
  final PortForwardRule? rule;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  final _formKey = GlobalKey<FormState>();
  late ForwardKind _kind = widget.rule?.kind ?? ForwardKind.local;
  late final _name = TextEditingController(text: widget.rule?.name ?? '');
  late final _localPort = TextEditingController(
    text: widget.rule == null ? '' : '${widget.rule!.localPort}',
  );
  late final _bind = TextEditingController(
    text: widget.rule?.bindAddress ?? '127.0.0.1',
  );
  late final _remoteHost = TextEditingController(
    text: widget.rule?.remoteHost ?? '127.0.0.1',
  );
  late final _remotePort = TextEditingController(
    text: widget.rule == null || widget.rule!.remotePort == 0
        ? ''
        : '${widget.rule!.remotePort}',
  );
  late bool _autoStart = widget.rule?.autoStart ?? false;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _localPort,
      _bind,
      _remoteHost,
      _remotePort,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _port(String? value) {
    final port = int.tryParse((value ?? '').trim());
    if (port == null || port < 1 || port > 65535) return '需為 1–65535';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.rule == null ? '新增轉發' : '編輯轉發'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<ForwardKind>(
                  segments: const [
                    ButtonSegment(
                      value: ForwardKind.local,
                      label: Text('本機轉發 -L'),
                    ),
                    ButtonSegment(
                      value: ForwardKind.dynamic,
                      label: Text('SOCKS5 -D'),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (value) =>
                      setState(() => _kind = value.first),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: '名稱（選填）',
                    hintText: '例如：PostgreSQL、Grafana',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _bind,
                        decoration: const InputDecoration(
                          labelText: '本機監聽位址',
                          helperText: '0.0.0.0 會開放給區網其他裝置',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _localPort,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '本機連接埠'),
                        validator: _port,
                      ),
                    ),
                  ],
                ),
                if (_kind == ForwardKind.local) ...[
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextFormField(
                          controller: _remoteHost,
                          decoration: const InputDecoration(
                            labelText: '目標主機（從伺服器看）',
                          ),
                          validator: (value) =>
                              (value ?? '').trim().isEmpty ? '請輸入目標主機' : null,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _remotePort,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: '目標連接埠'),
                          validator: _port,
                        ),
                      ),
                    ],
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _autoStart,
                  onChanged: (value) => setState(() => _autoStart = value),
                  title: const Text('開啟伺服器頁面時自動啟動'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? false)) return;
            Navigator.pop(
              context,
              PortForwardRule(
                id: widget.rule?.id ?? '',
                serverId: widget.serverId,
                name: _name.text.trim(),
                kind: _kind,
                localPort: int.parse(_localPort.text.trim()),
                bindAddress: _bind.text.trim().isEmpty
                    ? '127.0.0.1'
                    : _bind.text.trim(),
                remoteHost: _remoteHost.text.trim(),
                remotePort: int.tryParse(_remotePort.text.trim()) ?? 0,
                autoStart: _autoStart,
              ),
            );
          },
          child: const Text('儲存'),
        ),
      ],
    );
  }
}
