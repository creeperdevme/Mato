import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/settings_store.dart';
import '../services/ssh_service.dart';
import '../utils/error_messages.dart';
import '../utils/format.dart';
import '../utils/shell.dart';
import '../widgets/common.dart';
import 'file_editor_screen.dart';

const _saveDialogLimit = 100 * 1024 * 1024;

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 傳輸中的檔案（上傳或下載）。
class _Transfer {
  _Transfer(this.label);

  final String label;
  int done = 0;
  int total = 0;

  double? get progress => total <= 0 ? null : (done / total).clamp(0, 1);
}

/// SFTP 檔案管理。
class FileManagerScreen extends StatefulWidget {
  const FileManagerScreen({
    super.key,
    required this.profile,
    this.onOpenTerminal,
  });

  final ServerProfile profile;

  /// 在終端機開啟目前資料夾。
  final ValueChanged<String>? onOpenTerminal;

  @override
  State<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends State<FileManagerScreen> {
  final List<String> _history = [];
  final _filterController = TextEditingController();
  List<RemoteFileEntry>? _entries;
  bool _loading = false;
  String? _error;
  String _filter = '';
  bool _filtering = false;
  _Transfer? _transfer;

  String get _currentPath => _history.isEmpty ? '/' : _history.last;

  @override
  void initState() {
    super.initState();
    _loadHome();
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  SSHService get _ssh => context.read<SSHService>();

  Future<void> _loadHome() async {
    setState(() => _loading = true);
    String home;
    try {
      home = await _ssh.homeDirectory(widget.profile);
    } catch (_) {
      try {
        final result = await _ssh.run(widget.profile, r'echo -n $HOME');
        home = result.success && result.stdout.trim().isNotEmpty
            ? result.stdout.trim()
            : '/';
      } catch (_) {
        home = '/';
      }
    }
    _history
      ..clear()
      ..add(home);
    await _loadDirectory(home);
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _ssh.listDirectory(widget.profile, path);
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '無法讀取 $path：${describeSshError(error)}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _navigateTo(String path) {
    if (path != _currentPath) _history.add(path);
    _filterController.clear();
    _filter = '';
    _loadDirectory(path);
  }

  void _back() {
    if (_history.length <= 1) return;
    _history.removeLast();
    _loadDirectory(_currentPath);
  }

  List<RemoteFileEntry> _visible(SettingsStore settings) {
    final entries = _entries ?? const <RemoteFileEntry>[];
    final query = _filter.trim().toLowerCase();
    final list = entries.where((entry) {
      if (!settings.sftpShowHidden && entry.isHidden) return false;
      if (query.isNotEmpty && !entry.name.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList();
    final descending = settings.sftpSortDescending;
    int compare(RemoteFileEntry a, RemoteFileEntry b) {
      switch (settings.sftpSort) {
        case 'size':
          return (a.size ?? 0).compareTo(b.size ?? 0);
        case 'mtime':
          return (a.modifiedTime ?? DateTime(0)).compareTo(
            b.modifiedTime ?? DateTime(0),
          );
        default:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    }

    list.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      final result = compare(a, b);
      return descending ? -result : result;
    });
    return list;
  }

  // 動作 ----------------------------------------------------------------------

  Future<void> _open(RemoteFileEntry entry) async {
    if (entry.isDirectory) {
      _navigateTo(entry.path);
      return;
    }
    if (isImageFile(entry.name)) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ImagePreviewScreen(profile: widget.profile, path: entry.path),
        ),
      );
      return;
    }
    await _edit(entry);
  }

  Future<void> _edit(RemoteFileEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileEditorScreen(
          profile: widget.profile,
          path: entry.path,
          size: entry.size,
        ),
      ),
    );
    if (mounted) await _loadDirectory(_currentPath);
  }

  Future<void> _goTo() async {
    final path = await promptText(
      context,
      title: '前往路徑',
      initial: _currentPath,
      monospace: true,
      validator: (value) =>
          value.trim().startsWith('/') || value.trim().startsWith('~')
          ? null
          : '請輸入絕對路徑（以 / 開頭）',
    );
    if (path == null) return;
    var target = path.trim();
    if (target.startsWith('~')) {
      final home = await _ssh.homeDirectory(widget.profile);
      target = home + target.substring(1);
    }
    _navigateTo(target);
  }

  Future<void> _createFolder() async {
    final name = await promptText(
      context,
      title: '新增資料夾',
      label: '資料夾名稱',
      confirmLabel: '新增',
      validator: _nameValidator,
    );
    if (name == null) return;
    try {
      await _ssh.createDirectory(
        widget.profile,
        joinRemotePath(_currentPath, name.trim()),
      );
      await _loadDirectory(_currentPath);
    } catch (error) {
      _fail('新增資料夾失敗', error);
    }
  }

  Future<void> _createFile() async {
    final name = await promptText(
      context,
      title: '新增檔案',
      label: '檔案名稱',
      confirmLabel: '建立並編輯',
      validator: _nameValidator,
    );
    if (name == null) return;
    final path = joinRemotePath(_currentPath, name.trim());
    try {
      await _ssh.writeFile(widget.profile, path, Uint8List(0));
      if (!mounted) return;
      await _edit(
        RemoteFileEntry(
          name: name.trim(),
          path: path,
          isDirectory: false,
          size: 0,
          modifiedTime: DateTime.now(),
        ),
      );
    } catch (error) {
      _fail('建立檔案失敗', error);
    }
  }

  String? _nameValidator(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '請輸入名稱';
    if (trimmed.contains('/')) return '名稱不能包含 /';
    if (trimmed == '.' || trimmed == '..') return '名稱不正確';
    return null;
  }

  Future<void> _upload() async {
    final files = await FilePicker.pickFiles(dialogTitle: '選擇要上傳的檔案');
    if (files.isEmpty || !mounted) return;
    final existing = {
      for (final entry in _entries ?? const <RemoteFileEntry>[]) entry.name,
    };
    final conflicts = files
        .where((file) => existing.contains(file.name))
        .toList();
    if (conflicts.isNotEmpty) {
      final overwrite = await confirmAction(
        context,
        title: '覆蓋檔案',
        message:
            '以下檔案已存在，要覆蓋嗎？\n${conflicts.map((file) => file.name).join('\n')}',
        confirmLabel: '覆蓋',
        destructive: true,
      );
      if (!overwrite) return;
    }

    var index = 0;
    try {
      for (final file in files) {
        index++;
        final size = await file.length() ?? 0;
        final transfer = _Transfer('上傳 ${file.name}（$index/${files.length}）')
          ..total = size;
        setState(() => _transfer = transfer);
        await _ssh.upload(
          widget.profile,
          joinRemotePath(_currentPath, file.name),
          file.readAsByteStream(),
          size,
          onProgress: (sent, total) {
            if (!mounted) return;
            setState(() => transfer.done = sent);
          },
        );
      }
      if (mounted) showMessage(context, '已上傳 ${files.length} 個檔案');
    } catch (error) {
      _fail('上傳失敗', error);
    } finally {
      if (mounted) setState(() => _transfer = null);
      await _loadDirectory(_currentPath);
    }
  }

  Future<void> _download(RemoteFileEntry entry) async {
    final size = entry.size ?? 0;
    try {
      if (size > _saveDialogLimit) {
        if (!_isDesktop) {
          throw const FormatException('檔案超過 100 MB，請改用電腦版下載。');
        }
        // 大檔案直接串流寫到資料夾，不把整個檔案放進記憶體。
        final directory = await FilePicker.getDirectoryPath(
          dialogTitle: '選擇儲存位置',
        );
        if (directory == null) return;
        final target = '$directory${Platform.pathSeparator}${entry.name}';
        final transfer = _Transfer('下載 ${entry.name}')..total = size;
        setState(() => _transfer = transfer);
        await _ssh.downloadFile(
          widget.profile,
          entry.path,
          target,
          onProgress: (received, total) {
            if (mounted) setState(() => transfer.done = received);
          },
        );
        if (mounted) showMessage(context, '已下載到 $target');
        return;
      }

      final transfer = _Transfer('下載 ${entry.name}')..total = size;
      setState(() => _transfer = transfer);
      final bytes = await _ssh.readFile(widget.profile, entry.path);
      if (mounted) setState(() => _transfer = null);
      final saved = await FilePicker.saveFile(
        fileName: entry.name,
        bytes: bytes,
      );
      if (mounted) {
        showMessage(context, saved == null ? '已取消下載' : '已下載 ${entry.name}');
      }
    } catch (error) {
      _fail('下載失敗', error);
    } finally {
      if (mounted) setState(() => _transfer = null);
    }
  }

  Future<void> _rename(RemoteFileEntry entry) async {
    final name = await promptText(
      context,
      title: '重新命名',
      initial: entry.name,
      confirmLabel: '重新命名',
      validator: _nameValidator,
    );
    if (name == null || name.trim() == entry.name) return;
    try {
      await _ssh.rename(
        widget.profile,
        entry.path,
        joinRemotePath(_currentPath, name.trim()),
      );
      await _loadDirectory(_currentPath);
    } catch (error) {
      _fail('重新命名失敗', error);
    }
  }

  Future<void> _delete(RemoteFileEntry entry) async {
    final confirmed = await confirmAction(
      context,
      title: '刪除 ${entry.name}',
      message: entry.isDirectory
          ? '會連同資料夾內的所有檔案一起刪除，且無法復原。'
          : '確定要刪除這個檔案嗎？此動作無法復原。',
      confirmLabel: '刪除',
      destructive: true,
    );
    if (!confirmed) return;
    try {
      await _ssh.delete(widget.profile, entry.path, entry.isDirectory);
      await _loadDirectory(_currentPath);
      if (mounted) showMessage(context, '已刪除 ${entry.name}');
    } catch (error) {
      _fail('刪除失敗', error);
    }
  }

  Future<void> _chmod(RemoteFileEntry entry) async {
    final mode = await showDialog<int>(
      context: context,
      builder: (_) =>
          _PermissionDialog(name: entry.name, mode: entry.mode ?? 0x1a4),
    );
    if (mode == null) return;
    try {
      await _ssh.chmod(widget.profile, entry.path, mode);
      await _loadDirectory(_currentPath);
    } catch (error) {
      _fail('變更權限失敗', error);
    }
  }

  Future<void> _info(RemoteFileEntry entry) async {
    final buffer = StringBuffer()
      ..writeln('路徑：${entry.path}')
      ..writeln(
        '類型：${entry.isDirectory ? '資料夾' : '檔案'}${entry.isSymlink ? '（符號連結）' : ''}',
      )
      ..writeln(
        '權限：${entry.permissions}（${(entry.mode ?? 0).toRadixString(8).padLeft(3, '0')}）',
      );
    if (entry.size != null && !entry.isDirectory) {
      buffer.writeln('大小：${formatBytes(entry.size!)}（${entry.size} bytes）');
    }
    if (entry.modifiedTime != null) {
      buffer.writeln('修改時間：${formatDateTime(entry.modifiedTime!)}');
    }
    try {
      final path = shellQuote(entry.path);
      final command = entry.isDirectory
          ? 'du -sh $path 2>/dev/null; stat $path 2>/dev/null'
          : 'stat $path 2>/dev/null; echo; md5sum $path 2>/dev/null; sha256sum $path 2>/dev/null';
      final result = await runWithProgress(
        context,
        entry.isDirectory ? '計算資料夾大小…' : '計算雜湊值…',
        () => _ssh.run(
          widget.profile,
          command,
          timeout: const Duration(minutes: 2),
        ),
      );
      buffer
        ..writeln()
        ..write(result.text.trim());
    } catch (error) {
      buffer
        ..writeln()
        ..write('無法取得更多資訊：${describeSshError(error)}');
    }
    if (!mounted) return;
    await showTextOutput(context, title: entry.name, text: buffer.toString());
  }

  Future<void> _runCustom(SftpCommand command, RemoteFileEntry entry) async {
    final directory = parentRemotePath(entry.path) ?? '/';
    final text = command.command
        .replaceAll('{path}', shellQuote(entry.path))
        .replaceAll('{name}', shellQuote(entry.name))
        .replaceAll('{dir}', shellQuote(directory));
    try {
      final result = await runWithProgress(
        context,
        '執行「${command.name}」…',
        () =>
            _ssh.run(widget.profile, text, timeout: const Duration(minutes: 5)),
      );
      if (!mounted) return;
      await showTextOutput(
        context,
        title: '${command.name}（結束代碼 ${result.exitCode}）',
        text: [
          result.stdout,
          result.stderr,
        ].where((part) => part.trim().isNotEmpty).join('\n'),
      );
      await _loadDirectory(_currentPath);
    } catch (error) {
      _fail('執行失敗', error);
    }
  }

  void _fail(String title, Object error) {
    if (!mounted) return;
    final message = error is FormatException
        ? error.message
        : describeSshError(error);
    showMessage(context, '$title：$message', error: true);
  }

  void _showMenu(RemoteFileEntry entry) {
    final commands = context.read<SettingsStore>().sftpCommands;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        void run(VoidCallback action) {
          Navigator.pop(sheetContext);
          action();
        }

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: Icon(_iconFor(entry)),
                  title: Text(entry.name, maxLines: 2),
                  subtitle: Text(entry.path, style: monoStyle(fontSize: 12)),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.open_in_new_rounded),
                  title: Text(entry.isDirectory ? '開啟' : '開啟／預覽'),
                  onTap: () => run(() => _open(entry)),
                ),
                if (!entry.isDirectory) ...[
                  ListTile(
                    leading: const Icon(Icons.edit_note_rounded),
                    title: const Text('以文字編輯'),
                    onTap: () => run(() => _edit(entry)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.download_rounded),
                    title: const Text('下載'),
                    onTap: () => run(() => _download(entry)),
                  ),
                ],
                if (entry.isDirectory && widget.onOpenTerminal != null)
                  ListTile(
                    leading: const Icon(Icons.terminal_rounded),
                    title: const Text('在終端機開啟'),
                    onTap: () => run(() => widget.onOpenTerminal!(entry.path)),
                  ),
                ListTile(
                  leading: const Icon(Icons.drive_file_rename_outline_rounded),
                  title: const Text('重新命名'),
                  onTap: () => run(() => _rename(entry)),
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('複製路徑'),
                  onTap: () =>
                      run(() => copyText(context, entry.path, label: '路徑')),
                ),
                ListTile(
                  leading: const Icon(Icons.lock_outline_rounded),
                  title: const Text('權限'),
                  subtitle: Text(
                    entry.permissions,
                    style: monoStyle(fontSize: 12),
                  ),
                  onTap: () => run(() => _chmod(entry)),
                ),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: Text(entry.isDirectory ? '資訊與大小' : '資訊與 MD5／SHA-256'),
                  onTap: () => run(() => _info(entry)),
                ),
                if (commands.isNotEmpty) ...[
                  const Divider(height: 1),
                  for (final command in commands)
                    ListTile(
                      leading: const Icon(Icons.play_arrow_rounded),
                      title: Text(command.name),
                      subtitle: Text(
                        command.command,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(fontSize: 11),
                      ),
                      onTap: () => run(() => _runCustom(command, entry)),
                    ),
                ],
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    Icons.delete_outline_rounded,
                    color: Theme.of(sheetContext).colorScheme.error,
                  ),
                  title: Text(
                    '刪除',
                    style: TextStyle(
                      color: Theme.of(sheetContext).colorScheme.error,
                    ),
                  ),
                  onTap: () => run(() => _delete(entry)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 畫面 ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final parent = parentRemotePath(_currentPath);
    final visible = _visible(settings);

    return Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: _history.length <= 1 ? null : _back,
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: '上一頁',
                ),
                IconButton(
                  onPressed: parent == null ? null : () => _navigateTo(parent),
                  icon: const Icon(Icons.arrow_upward_rounded),
                  tooltip: '上層目錄',
                ),
                Expanded(
                  child: _filtering
                      ? TextField(
                          controller: _filterController,
                          autofocus: true,
                          decoration: const InputDecoration(
                            hintText: '篩選目前資料夾',
                            prefixIcon: Icon(Icons.filter_list_rounded),
                          ),
                          onChanged: (value) => setState(() => _filter = value),
                        )
                      : _Breadcrumbs(path: _currentPath, onTap: _navigateTo),
                ),
                IconButton(
                  tooltip: _filtering ? '關閉篩選' : '篩選',
                  onPressed: () => setState(() {
                    _filtering = !_filtering;
                    if (!_filtering) {
                      _filter = '';
                      _filterController.clear();
                    }
                  }),
                  icon: Icon(
                    _filtering
                        ? Icons.close_rounded
                        : Icons.filter_list_rounded,
                  ),
                ),
                IconButton(
                  onPressed: _upload,
                  icon: const Icon(Icons.upload_rounded),
                  tooltip: '上傳檔案',
                ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (value) {
                    switch (value) {
                      case 'folder':
                        _createFolder();
                      case 'file':
                        _createFile();
                      case 'refresh':
                        _loadDirectory(_currentPath);
                      case 'home':
                        _loadHome();
                      case 'root':
                        _navigateTo('/');
                      case 'goto':
                        _goTo();
                      case 'terminal':
                        widget.onOpenTerminal?.call(_currentPath);
                      case 'hidden':
                        settings.sftpShowHidden = !settings.sftpShowHidden;
                      case 'name':
                      case 'size':
                      case 'mtime':
                        if (settings.sftpSort == value) {
                          settings.sftpSortDescending =
                              !settings.sftpSortDescending;
                        } else {
                          settings.sftpSort = value;
                          settings.sftpSortDescending = value != 'name';
                        }
                    }
                  },
                  itemBuilder: (context) {
                    PopupMenuItem<String> sort(String value, String label) =>
                        PopupMenuItem(
                          value: value,
                          child: ListTile(
                            leading: Icon(
                              settings.sftpSort != value
                                  ? Icons.sort_rounded
                                  : settings.sftpSortDescending
                                  ? Icons.arrow_downward_rounded
                                  : Icons.arrow_upward_rounded,
                            ),
                            title: Text('依$label排序'),
                            selected: settings.sftpSort == value,
                          ),
                        );
                    return [
                      const PopupMenuItem(
                        value: 'folder',
                        child: ListTile(
                          leading: Icon(Icons.create_new_folder_outlined),
                          title: Text('新增資料夾'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'file',
                        child: ListTile(
                          leading: Icon(Icons.note_add_outlined),
                          title: Text('新增檔案'),
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'refresh',
                        child: ListTile(
                          leading: Icon(Icons.refresh_rounded),
                          title: Text('重新整理'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'home',
                        child: ListTile(
                          leading: Icon(Icons.home_outlined),
                          title: Text('家目錄'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'root',
                        child: ListTile(
                          leading: Icon(Icons.sd_storage_outlined),
                          title: Text('根目錄 (/)'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'goto',
                        child: ListTile(
                          leading: Icon(Icons.drive_folder_upload_outlined),
                          title: Text('前往路徑…'),
                        ),
                      ),
                      if (widget.onOpenTerminal != null)
                        const PopupMenuItem(
                          value: 'terminal',
                          child: ListTile(
                            leading: Icon(Icons.terminal_rounded),
                            title: Text('在終端機開啟此資料夾'),
                          ),
                        ),
                      const PopupMenuDivider(),
                      sort('name', '名稱'),
                      sort('size', '大小'),
                      sort('mtime', '修改時間'),
                      PopupMenuItem(
                        value: 'hidden',
                        child: ListTile(
                          leading: Icon(
                            settings.sftpShowHidden
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                          title: Text(
                            settings.sftpShowHidden ? '隱藏隱藏檔' : '顯示隱藏檔',
                          ),
                        ),
                      ),
                    ];
                  },
                ),
              ],
            ),
          ),
        ),
        if (_transfer != null)
          _TransferBar(transfer: _transfer!)
        else if (_loading && _entries != null)
          const LinearProgressIndicator(minHeight: 2)
        else
          const SizedBox(height: 2),
        Expanded(child: _buildBody(visible)),
      ],
    );
  }

  Widget _buildBody(List<RemoteFileEntry> visible) {
    if (_loading && _entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.folder_off_outlined,
        title: '無法讀取資料夾',
        message: _error,
        error: true,
        action: Wrap(
          spacing: 12,
          children: [
            OutlinedButton(onPressed: _loadHome, child: const Text('回家目錄')),
            FilledButton(
              onPressed: () => _loadDirectory(_currentPath),
              child: const Text('重試'),
            ),
          ],
        ),
      );
    }
    if (visible.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _loadDirectory(_currentPath),
        child: ListView(
          children: [
            SizedBox(
              height: 320,
              child: EmptyState(
                icon: Icons.folder_open_outlined,
                title: _filter.isNotEmpty ? '沒有符合的檔案' : '這個資料夾是空的',
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadDirectory(_currentPath),
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final entry = visible[index];
          return _EntryTile(
            entry: entry,
            onTap: () => _open(entry),
            onMenu: () => _showMenu(entry),
          );
        },
      ),
    );
  }
}

IconData _iconFor(RemoteFileEntry entry) {
  if (entry.isDirectory) {
    return entry.isSymlink
        ? Icons.folder_special_rounded
        : Icons.folder_rounded;
  }
  final name = entry.name.toLowerCase();
  if (isImageFile(name)) return Icons.image_outlined;
  if (RegExp(r'\.(zip|tar|gz|tgz|bz2|xz|7z|rar|zst)$').hasMatch(name)) {
    return Icons.folder_zip_outlined;
  }
  if (RegExp(r'\.(log|out)$').hasMatch(name)) {
    return Icons.receipt_long_outlined;
  }
  if (RegExp(r'\.(sh|py|js|ts|go|rs|c|cpp|java|php|rb|dart|lua)$')
      .hasMatch(name)) {
    return Icons.code_rounded;
  }
  if (RegExp(r'\.(conf|cfg|ini|ya?ml|json|toml|env|service)$').hasMatch(name)) {
    return Icons.settings_applications_outlined;
  }
  if (entry.isSymlink) return Icons.link_rounded;
  return Icons.insert_drive_file_outlined;
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.onTap,
    required this.onMenu,
  });

  final RemoteFileEntry entry;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final details = [
      if (!entry.isDirectory && entry.size != null) formatBytes(entry.size!),
      if (entry.modifiedTime != null) formatDateTime(entry.modifiedTime!),
    ].join(' · ');

    return ListTile(
      onTap: onTap,
      onLongPress: onMenu,
      leading: Icon(
        _iconFor(entry),
        color: entry.isDirectory ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: entry.isHidden
            ? TextStyle(color: scheme.onSurfaceVariant)
            : null,
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              details.isEmpty ? (entry.isDirectory ? '資料夾' : '檔案') : details,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (entry.permissions.isNotEmpty)
            Text(
              entry.permissions,
              style: monoStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
      trailing: IconButton(
        tooltip: '操作',
        icon: const Icon(Icons.more_vert_rounded),
        onPressed: onMenu,
      ),
    );
  }
}

class _Breadcrumbs extends StatefulWidget {
  const _Breadcrumbs({required this.path, required this.onTap});

  final String path;
  final ValueChanged<String> onTap;

  @override
  State<_Breadcrumbs> createState() => _BreadcrumbsState();
}

class _BreadcrumbsState extends State<_Breadcrumbs> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_Breadcrumbs oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 路徑變長時捲到最右邊，讓目前資料夾保持可見。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segments = remotePathSegments(widget.path);
    return SizedBox(
      height: 40,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        itemCount: segments.length,
        separatorBuilder: (_, _) => Icon(
          Icons.chevron_right_rounded,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        itemBuilder: (context, index) {
          final segment = segments[index];
          final last = index == segments.length - 1;
          final label = index == 0 ? '/' : remoteBaseName(segment);
          return Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: last ? null : () => widget.onTap(segment),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: last ? FontWeight.w700 : FontWeight.w500,
                    color: last
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TransferBar extends StatelessWidget {
  const _TransferBar({required this.transfer});

  final _Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = transfer.progress;
    return Container(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  transfer.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium,
                ),
              ),
              if (transfer.total > 0)
                Text(
                  '${formatBytes(transfer.done)} / ${formatBytes(transfer.total)}',
                  style: theme.textTheme.labelSmall,
                ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: progress, minHeight: 4),
        ],
      ),
    );
  }
}

/// 以勾選框編輯 rwx 權限。
class _PermissionDialog extends StatefulWidget {
  const _PermissionDialog({required this.name, required this.mode});

  final String name;
  final int mode;

  @override
  State<_PermissionDialog> createState() => _PermissionDialogState();
}

class _PermissionDialogState extends State<_PermissionDialog> {
  late int _mode = widget.mode & 0x1ff;
  late final _octal = TextEditingController(text: _octalText);

  String get _octalText => _mode.toRadixString(8).padLeft(3, '0');

  @override
  void dispose() {
    _octal.dispose();
    super.dispose();
  }

  void _toggle(int bit, bool value) {
    setState(() {
      _mode = value ? _mode | bit : _mode & ~bit;
      _octal.text = _octalText;
    });
  }

  @override
  Widget build(BuildContext context) {
    const groups = [('擁有者', 6), ('群組', 3), ('其他人', 0)];
    const kinds = [('讀', 2), ('寫', 1), ('執行', 0)];
    return AlertDialog(
      title: Text('權限：${widget.name}'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Table(
              columnWidths: const {0: FlexColumnWidth(1.4)},
              children: [
                TableRow(
                  children: [
                    const SizedBox(),
                    for (final (label, _) in kinds) Center(child: Text(label)),
                  ],
                ),
                for (final (group, shift) in groups)
                  TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(group),
                      ),
                      for (final (_, bit) in kinds)
                        Checkbox(
                          value: _mode & (1 << (shift + bit)) != 0,
                          onChanged: (value) =>
                              _toggle(1 << (shift + bit), value ?? false),
                        ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _octal,
              style: monoStyle(fontSize: 16),
              decoration: InputDecoration(
                labelText: '八進位',
                helperText: permissionString(_mode),
              ),
              onChanged: (value) {
                final parsed = int.tryParse(value, radix: 8);
                if (parsed != null && parsed >= 0 && parsed <= 0x1ff) {
                  setState(() => _mode = parsed);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _mode),
          child: const Text('套用'),
        ),
      ],
    );
  }
}
