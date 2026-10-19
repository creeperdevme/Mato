import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/ssh_service.dart';
import '../services/server_store.dart';
import 'docker_screen.dart';
import 'file_manager_screen.dart';
import 'server_form_screen.dart';
import 'terminal_screen.dart';

class ServerDetailScreen extends StatefulWidget {
  const ServerDetailScreen({super.key, required this.serverId});

  final String serverId;

  @override
  State<ServerDetailScreen> createState() => _ServerDetailScreenState();
}

class _ServerDetailScreenState extends State<ServerDetailScreen> {
  late ServerProfile _profile;
  String? _systemSummary;
  bool _loadingSummary = false;
  String? _summaryError;

  @override
  void initState() {
    super.initState();
    final store = context.read<ServerStore>();
    _profile = store.servers.firstWhere(
      (server) => server.id == widget.serverId,
      orElse: () => throw StateError('找不到伺服器'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ServerStore>();
    final profile = store.servers.firstWhere(
      (server) => server.id == widget.serverId,
      orElse: () => _profile,
    );

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(profile.name),
          actions: [
            IconButton(
              tooltip: '編輯',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ServerFormScreen(server: profile),
                  ),
                );
              },
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: '總覽'),
              Tab(text: 'SSH 控制'),
              Tab(text: '檔案管理'),
              Tab(text: 'Docker'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _OverviewTab(
              profile: profile,
              summary: _systemSummary,
              error: _summaryError,
              loading: _loadingSummary,
              onRefresh: _loadSummary,
            ),
            TerminalScreen(profile: profile),
            FileManagerScreen(profile: profile),
            DockerScreen(profile: profile),
          ],
        ),
      ),
    );
  }

  Future<void> _loadSummary() async {
    if (_loadingSummary) return;
    setState(() {
      _loadingSummary = true;
      _summaryError = null;
    });
    final store = context.read<ServerStore>();
    final sshService = context.read<SSHService>();
    try {
      final password = await store.getPassword(_profile.id);
      if (password == null) throw Exception('找不到已儲存的密碼');
      final result = await sshService.run(
        _profile.copyWith(password: password),
        'echo "=== 作業系統 ==="; cat /etc/os-release 2>/dev/null | head -n 2; uname -sr; '
        'echo "=== 開機時間 ==="; uptime -s; echo "=== 運行時間 ==="; uptime -p; '
        'echo "=== 負載 ==="; uptime; echo "=== 磁碟 (/) ==="; df -h / | tail -n 1; '
        'echo "=== 記憶體 ==="; free -h | sed -n "2p"',
      );
      if (!result.success) throw Exception(result.stderr);
      setState(() => _systemSummary = result.stdout.trim());
    } catch (error) {
      setState(() => _summaryError = error.toString());
    } finally {
      if (mounted) setState(() => _loadingSummary = false);
    }
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.profile,
    required this.summary,
    required this.error,
    required this.loading,
    required this.onRefresh,
  });

  final ServerProfile profile;
  final String? summary;
  final String? error;
  final bool loading;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ServerStore>();
    final status = store.statusOf(profile.id);

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('伺服器資訊', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  _InfoRow(label: '顯示名稱', value: profile.name),
                  _InfoRow(label: '主機', value: profile.host),
                  _InfoRow(label: '連接埠', value: profile.port.toString()),
                  _InfoRow(label: '帳號', value: profile.username),
                  _InfoRow(label: '狀態', value: _statusText(status)),
                  if (store.statusMessageOf(profile.id).isNotEmpty)
                    _InfoRow(
                      label: '訊息',
                      value: store.statusMessageOf(profile.id),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '系統狀態',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        onPressed: loading ? null : onRefresh,
                        icon: loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  if (!loading && summary == null && error == null)
                    const Text('下拉更新或按下重新整理按鈕'),
                  if (summary != null) SelectableText(summary!),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _statusText(ServerStatus status) {
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
        return '尚未檢查';
    }
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}
