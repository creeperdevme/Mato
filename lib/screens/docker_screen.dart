import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/ssh_service.dart';

class DockerScreen extends StatefulWidget {
  const DockerScreen({super.key, required this.profile});

  final ServerProfile profile;

  @override
  State<DockerScreen> createState() => _DockerScreenState();
}

class _DockerScreenState extends State<DockerScreen>
    with AutomaticKeepAliveClientMixin {
  List<DockerContainer>? _containers;
  bool _loading = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: _loading ? null : _load,
        child: const Icon(Icons.refresh),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _containers == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重試')),
            ],
          ),
        ),
      );
    }
    final containers = _containers;
    if (containers == null || containers.isEmpty) {
      return const Center(child: Text('沒有 Docker 容器'));
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: containers.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final container = containers[index];
          final running = container.state == 'running';
          return Card(
            child: ListTile(
              leading: Icon(
                Icons.inventory_2_outlined,
                color: running ? Colors.green : Colors.grey,
              ),
              title: Text(container.name),
              subtitle: Text('${container.image}\n${container.status}'),
              isThreeLine: true,
              trailing: PopupMenuButton<String>(
                onSelected: (action) => _performAction(container, action),
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'start', child: Text('啟動')),
                  const PopupMenuItem(value: 'stop', child: Text('停止')),
                  const PopupMenuItem(value: 'restart', child: Text('重新啟動')),
                  const PopupMenuItem(value: 'logs', child: Text('檢視日誌')),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final containers = await context.read<SSHService>().listDockerContainers(
        widget.profile,
      );
      if (!mounted) return;
      setState(() => _containers = containers);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _performAction(DockerContainer container, String action) async {
    try {
      if (action == 'logs') {
        final sshService = context.read<SSHService>();
        final result = await sshService.run(
          widget.profile,
          'docker logs --tail 100 ${_quoteArg(container.id)}',
        );
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('${container.name} 日誌'),
            content: SizedBox(
              width: 680,
              child: SingleChildScrollView(
                child: SelectableText(
                  result.stdout.isEmpty ? result.stderr : result.stdout,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('關閉'),
              ),
            ],
          ),
        );
        return;
      }

      await context.read<SSHService>().controlDockerContainer(
        widget.profile,
        container.id,
        action,
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('操作失敗：$error')));
    }
  }

  String _quoteArg(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }
}
