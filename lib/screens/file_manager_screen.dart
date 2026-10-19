import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/ssh_service.dart';

class FileManagerScreen extends StatefulWidget {
  const FileManagerScreen({super.key, required this.profile});

  final ServerProfile profile;

  @override
  State<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends State<FileManagerScreen>
    with AutomaticKeepAliveClientMixin {
  final List<String> _history = ['/'];
  List<RemoteFileEntry>? _entries;
  bool _loading = false;
  String? _error;

  String get _currentPath => _history.last;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadHome();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        _buildToolbar(context),
        _buildPathBar(context),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final parent = _parentOf(_currentPath);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: _history.length <= 1
                ? null
                : () {
                    _history.removeLast();
                    _loadDirectory(_currentPath);
                  },
            icon: const Icon(Icons.arrow_back),
            tooltip: '上一頁',
          ),
          IconButton(
            onPressed: parent == null ? null : () => _navigateTo(parent),
            icon: const Icon(Icons.arrow_upward),
            tooltip: '上層目錄',
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text('檔案管理', style: Theme.of(context).textTheme.titleLarge),
          ),
          IconButton(
            onPressed: () => _goToRoot(),
            icon: const Icon(Icons.vertical_align_top),
            tooltip: '回到根目錄 (/)',
          ),
          IconButton(
            onPressed: () => _createFolder(),
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: '新增資料夾',
          ),
          IconButton(
            onPressed: () => _uploadFiles(),
            icon: const Icon(Icons.upload_file),
            tooltip: '上傳檔案',
          ),
          IconButton(
            onPressed: () => _loadDirectory(_currentPath),
            icon: const Icon(Icons.refresh),
            tooltip: '重新整理',
          ),
        ],
      ),
    );
  }

  Widget _buildPathBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.folder_open),
          title: SelectableText(
            _currentPath,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.home_outlined),
                onPressed: _loadHome,
                tooltip: '使用者家目錄',
              ),
              IconButton(
                icon: const Icon(Icons.sd_storage_outlined),
                onPressed: () => _goToRoot(),
                tooltip: '根目錄 (/)',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _loadDirectory(_currentPath),
              child: const Text('重試'),
            ),
          ],
        ),
      );
    }
    final entries = _entries;
    if (entries == null || entries.isEmpty) {
      return const Center(child: Text('這個資料夾是空的'));
    }

    return RefreshIndicator(
      onRefresh: () => _loadDirectory(_currentPath),
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return ListTile(
            leading: Icon(
              entry.isDirectory ? Icons.folder : Icons.insert_drive_file,
              color: entry.isDirectory
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: Text(entry.name),
            subtitle: Text(
              entry.isDirectory
                  ? '資料夾'
                  : entry.size == null
                  ? '檔案'
                  : _formatSize(entry.size!),
            ),
            onTap: entry.isDirectory
                ? () {
                    _history.add(entry.path);
                    _loadDirectory(entry.path);
                  }
                : () => _downloadFile(entry),
            onLongPress: () => _showFileMenu(entry),
            trailing: PopupMenuButton<String>(
              onSelected: (action) {
                if (action == 'download' && !entry.isDirectory) {
                  _downloadFile(entry);
                } else if (action == 'delete') {
                  _deleteEntry(entry);
                }
              },
              itemBuilder: (context) => [
                if (!entry.isDirectory)
                  const PopupMenuItem(value: 'download', child: Text('下載')),
                const PopupMenuItem(value: 'delete', child: Text('刪除')),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 目前路徑的上一層；已在 `/` 時回傳 null。
  String? _parentOf(String path) {
    if (path.isEmpty || path == '/') return null;
    var trimmed = path;
    while (trimmed.length > 1 && trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final index = trimmed.lastIndexOf('/');
    return index <= 0 ? '/' : trimmed.substring(0, index);
  }

  /// 切換目錄並保留上一頁紀錄。
  void _navigateTo(String path) {
    if (path == _currentPath) {
      _loadDirectory(path);
      return;
    }
    _history.add(path);
    _loadDirectory(path);
  }

  void _goToRoot() => _navigateTo('/');

  Future<void> _loadHome() async {
    setState(() => _loading = true);
    try {
      final result = await context.read<SSHService>().run(
        widget.profile,
        'echo -n \$HOME',
      );
      final home = result.success && result.stdout.trim().isNotEmpty
          ? result.stdout.trim()
          : '/';
      _history
        ..clear()
        ..add(home);
      await _loadDirectory(home);
    } catch (error) {
      _history
        ..clear()
        ..add('/');
      await _loadDirectory('/');
    }
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await context.read<SSHService>().listDirectory(
        widget.profile,
        path,
      );
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '無法讀取目錄：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createFolder() async {
    final sshService = context.read<SSHService>();
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增資料夾'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '資料夾名稱'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('新增'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    try {
      await sshService.createDirectory(
        widget.profile,
        _joinPath(_currentPath, name),
      );
      await _loadDirectory(_currentPath);
    } catch (error) {
      _showMessage('新增資料夾失敗：$error');
    }
  }

  Future<void> _uploadFiles() async {
    final sshService = context.read<SSHService>();
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;

    try {
      for (final file in files) {
        if (file.path == null) continue;
        final bytes = File(file.path!).readAsBytesSync();
        await sshService.writeFile(
          widget.profile,
          _joinPath(_currentPath, file.name),
          Uint8List.fromList(bytes),
        );
      }
      await _loadDirectory(_currentPath);
      _showMessage('上傳完成');
    } catch (error) {
      _showMessage('上傳失敗：$error');
    }
  }

  Future<void> _downloadFile(RemoteFileEntry entry) async {
    try {
      final data = await context.read<SSHService>().readFile(
        widget.profile,
        entry.path,
      );
      final savedUri = await FilePicker.saveFile(
        fileName: entry.name,
        bytes: data,
      );
      _showMessage(savedUri == null ? '已取消下載' : '已下載：${savedUri.toFilePath()}');
    } catch (error) {
      _showMessage('下載失敗：$error');
    }
  }

  Future<void> _deleteEntry(RemoteFileEntry entry) async {
    final sshService = context.read<SSHService>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('刪除 ${entry.name}'),
        content: Text(entry.isDirectory ? '只能刪除空資料夾。確定刪除嗎？' : '確定刪除這個檔案嗎？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await sshService.delete(widget.profile, entry.path, entry.isDirectory);
      await _loadDirectory(_currentPath);
    } catch (error) {
      _showMessage('刪除失敗：$error');
    }
  }

  void _showFileMenu(RemoteFileEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('下載'),
              enabled: !entry.isDirectory,
              onTap: () {
                Navigator.pop(context);
                _downloadFile(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('刪除'),
              onTap: () {
                Navigator.pop(context);
                _deleteEntry(entry);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _joinPath(String parent, String name) {
    if (parent.endsWith('/')) return '$parent$name';
    return '$parent/$name';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
