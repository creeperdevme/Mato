import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/ssh_service.dart';
import '../services/server_store.dart';
import 'server_detail_screen.dart';
import 'server_form_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ServerStore>();
    final servers = store.servers;

    return Scaffold(
      appBar: AppBar(title: const Text('Mato'), centerTitle: false),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ServerFormScreen()),
        ),
        icon: const Icon(Icons.dns),
        label: const Text('新增伺服器'),
      ),
      body: servers.isEmpty
          ? _EmptyState(
              onAdd: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ServerFormScreen(),
                  ),
                );
              },
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              itemCount: servers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final server = servers[index];
                return _ServerCard(server: server);
              },
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dns_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 20),
            Text('歡迎使用 Mato', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            const Text(
              '新增 SSH 伺服器，即可管理狀態、終端機、檔案與 Docker。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('新增第一台伺服器'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.server});

  final ServerProfile server;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ServerStore>();
    final status = store.statusOf(server.id);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ServerDetailScreen(serverId: server.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _StatusBadge(status: status),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${server.username}@${server.host}:${server.port}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '檢查狀態',
                icon: status == ServerStatus.checking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                onPressed: status == ServerStatus.checking
                    ? null
                    : () => _check(context),
              ),
              IconButton(
                tooltip: '刪除',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDelete(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _check(BuildContext context) async {
    final store = context.read<ServerStore>();
    final sshService = context.read<SSHService>();
    final messenger = ScaffoldMessenger.of(context);
    final password = await store.getPassword(server.id);
    if (password == null) {
      messenger.showSnackBar(const SnackBar(content: Text('找不到已儲存的密碼')));
      return;
    }
    await store.refreshStatus(
      server.id,
      () => sshService.checkServer(
        ServerProfile(
          id: server.id,
          name: server.name,
          host: server.host,
          port: server.port,
          username: server.username,
          password: password,
          createdAt: server.createdAt,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final store = context.read<ServerStore>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('刪除伺服器'),
        content: Text('確定要刪除「${server.name}」嗎？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await store.deleteServer(server.id);
    }
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final ServerStatus status;

  @override
  Widget build(BuildContext context) {
    late final Color color;
    late final IconData icon;
    switch (status) {
      case ServerStatus.online:
        color = Colors.green;
        icon = Icons.check_circle;
      case ServerStatus.checking:
        color = Colors.blue;
        icon = Icons.sync;
      case ServerStatus.authFailed:
        color = Colors.orange;
        icon = Icons.key;
      case ServerStatus.offline:
      case ServerStatus.error:
        color = Colors.red;
        icon = Icons.error_outline;
      case ServerStatus.unknown:
        color = Colors.grey;
        icon = Icons.help_outline;
    }
    return Icon(icon, color: color, size: 28);
  }
}
