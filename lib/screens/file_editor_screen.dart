import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/nginx.dart';
import 'package:re_highlight/languages/perl.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../models/server_profile.dart';
import '../services/ssh_service.dart';
import '../utils/error_messages.dart';
import '../utils/format.dart';
import '../utils/shell.dart';
import '../widgets/common.dart';

/// 可以直接開成文字的最大檔案；更大的檔案只讀取尾端（唯讀）。
const _maxEditableBytes = 2 * 1024 * 1024;
const _tailBytes = 1024 * 1024;

/// 依副檔名（或檔名）判斷語法。
(String, Mode) languageFor(String fileName) {
  final name = fileName.toLowerCase();
  final extension = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1)
      : '';
  if (name == 'dockerfile' || name.endsWith('.dockerfile')) {
    return ('dockerfile', langDockerfile);
  }
  if (name == 'makefile') return ('makefile', langMakefile);
  if (name.endsWith('nginx.conf') || name.contains('nginx')) {
    return ('nginx', langNginx);
  }
  if (const {
    '.bashrc',
    '.profile',
    '.zshrc',
    '.bash_profile',
    '.bash_aliases',
  }.contains(name)) {
    return ('bash', langBash);
  }
  switch (extension) {
    case 'sh':
    case 'bash':
    case 'zsh':
    case 'env':
      return ('bash', langBash);
    case 'yml':
    case 'yaml':
      return ('yaml', langYaml);
    case 'json':
    case 'jsonc':
      return ('json', langJson);
    case 'py':
      return ('python', langPython);
    case 'js':
    case 'mjs':
    case 'cjs':
    case 'jsx':
      return ('javascript', langJavascript);
    case 'ts':
    case 'tsx':
      return ('typescript', langTypescript);
    case 'xml':
    case 'html':
    case 'htm':
    case 'svg':
    case 'plist':
      return ('xml', langXml);
    case 'ini':
    case 'conf':
    case 'cfg':
    case 'toml':
    case 'service':
    case 'timer':
    case 'socket':
      return ('ini', langIni);
    case 'properties':
      return ('properties', langProperties);
    case 'go':
      return ('go', langGo);
    case 'rs':
      return ('rust', langRust);
    case 'css':
    case 'scss':
      return ('css', langCss);
    case 'md':
    case 'markdown':
      return ('markdown', langMarkdown);
    case 'sql':
      return ('sql', langSql);
    case 'php':
      return ('php', langPhp);
    case 'java':
    case 'kt':
    case 'gradle':
      return ('java', langJava);
    case 'c':
    case 'h':
      return ('c', langC);
    case 'cpp':
    case 'cc':
    case 'hpp':
      return ('cpp', langCpp);
    case 'rb':
      return ('ruby', langRuby);
    case 'dart':
      return ('dart', langDart);
    case 'lua':
      return ('lua', langLua);
    case 'pl':
      return ('perl', langPerl);
    case 'diff':
    case 'patch':
      return ('diff', langDiff);
  }
  return ('plaintext', langPlaintext);
}

const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'ico'};

bool isImageFile(String name) {
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  return dot >= 0 && _imageExtensions.contains(lower.substring(dot + 1));
}

/// 從 SFTP 讀取並編輯文字檔。
class FileEditorScreen extends StatefulWidget {
  const FileEditorScreen({
    super.key,
    required this.profile,
    required this.path,
    this.size,
  });

  final ServerProfile profile;
  final String path;
  final int? size;

  @override
  State<FileEditorScreen> createState() => _FileEditorScreenState();
}

class _FileEditorScreenState extends State<FileEditorScreen> {
  CodeLineEditingController? _controller;

  /// 搜尋控制器必須綁定實際的編輯控制器，所以載入檔案後才建立。
  CodeFindController? _find;
  String _original = '';
  bool _loading = true;
  bool _saving = false;
  bool _readOnly = false;
  bool _wordWrap = false;
  bool _crlf = false;
  String? _error;
  String? _notice;

  String get _name => remoteBaseName(widget.path);
  bool get _dirty => _controller != null && _controller!.text != _original;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _find?.dispose();
    super.dispose();
  }

  Future<void> _load({bool tail = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final ssh = context.read<SSHService>();
    try {
      final size =
          widget.size ??
          (await ssh.stat(widget.profile, widget.path)).size ??
          0;
      if (size > _maxEditableBytes && !tail) {
        if (!mounted) return;
        final readTail = await confirmAction(
          context,
          title: '檔案較大',
          message:
              '這個檔案有 ${formatBytes(size)}，要只讀取最後 '
              '${formatBytes(_tailBytes)}（唯讀）嗎？適合查看日誌。',
          confirmLabel: '讀取尾端',
        );
        if (!readTail) {
          if (mounted) Navigator.of(context).pop();
          return;
        }
        await _load(tail: true);
        return;
      }
      final offset = tail ? size - _tailBytes : 0;
      final bytes = await ssh.readFile(
        widget.profile,
        widget.path,
        offset: offset < 0 ? 0 : offset,
        length: tail ? _tailBytes : null,
      );
      if (_looksBinary(bytes)) {
        throw const FormatException('這是二進位檔案，無法以文字開啟。');
      }
      var text = utf8.decode(bytes, allowMalformed: true);
      if (tail) {
        // 去掉被切斷的第一行。
        final newline = text.indexOf('\n');
        if (newline >= 0) text = text.substring(newline + 1);
      }
      _crlf = text.contains('\r\n');
      final controller = CodeLineEditingController.fromText(
        text,
        CodeLineOptions(
          lineBreak: _crlf ? TextLineBreak.crlf : TextLineBreak.lf,
          indentSize: 2,
        ),
      );
      _find?.dispose();
      _controller?.dispose();
      _controller = controller..addListener(_onChanged);
      _find = CodeFindController(controller);
      _original = controller.text;
      if (!mounted) return;
      setState(() {
        _readOnly = tail;
        _notice = tail ? '只顯示最後 ${formatBytes(_tailBytes)}（唯讀）' : null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is FormatException
            ? error.message
            : describeSshError(error);
      });
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  static bool _looksBinary(Uint8List bytes) {
    final sample = bytes.length > 8000 ? bytes.sublist(0, 8000) : bytes;
    return sample.contains(0);
  }

  Future<void> _save() async {
    final controller = _controller;
    if (controller == null || _readOnly || _saving) return;
    setState(() => _saving = true);
    try {
      final text = controller.text;
      await context.read<SSHService>().writeFile(
        widget.profile,
        widget.path,
        Uint8List.fromList(utf8.encode(text)),
      );
      _original = text;
      if (mounted) showMessage(context, '已儲存 $_name');
    } catch (error) {
      if (mounted) {
        showMessage(context, '儲存失敗：${describeSshError(error)}', error: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return confirmAction(
      context,
      title: '尚未儲存',
      message: '「$_name」有尚未儲存的修改，確定要離開嗎？',
      confirmLabel: '放棄修改',
      destructive: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final language = languageFor(_name);
    final controller = _controller;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          _original = _controller?.text ?? '';
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(child: Text(_name, overflow: TextOverflow.ellipsis)),
                  if (_dirty) ...[
                    const SizedBox(width: 8),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                '${widget.path} · ${language.$1}${_crlf ? ' · CRLF' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '搜尋與取代',
              onPressed: _find == null ? null : () => _find!.findMode(),
              icon: const Icon(Icons.search_rounded),
            ),
            IconButton(
              tooltip: _wordWrap ? '關閉自動換行' : '自動換行',
              isSelected: _wordWrap,
              onPressed: () => setState(() => _wordWrap = !_wordWrap),
              icon: const Icon(Icons.wrap_text_rounded),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'reload':
                    _load();
                  case 'copy':
                    copyText(context, controller?.text ?? '', label: '全部內容');
                  case 'path':
                    copyText(context, widget.path, label: '路徑');
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'reload', child: Text('重新載入')),
                PopupMenuItem(value: 'copy', child: Text('複製全部內容')),
                PopupMenuItem(value: 'path', child: Text('複製路徑')),
              ],
            ),
            if (!_readOnly)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  onPressed: _dirty && !_saving ? _save : null,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_rounded, size: 18),
                  label: const Text('儲存'),
                ),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? EmptyState(
                icon: Icons.description_outlined,
                title: '無法開啟檔案',
                message: _error,
                error: true,
                action: FilledButton(onPressed: _load, child: const Text('重試')),
              )
            : Column(
                children: [
                  if (_notice != null)
                    MaterialBanner(
                      content: Text(_notice!),
                      leading: const Icon(Icons.info_outline_rounded),
                      actions: [
                        TextButton(
                          onPressed: () => setState(() => _notice = null),
                          child: const Text('知道了'),
                        ),
                      ],
                    ),
                  Expanded(
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(
                          LogicalKeyboardKey.keyS,
                          control: true,
                        ): _save,
                        const SingleActivator(
                          LogicalKeyboardKey.keyS,
                          meta: true,
                        ): _save,
                      },
                      child: CodeEditor(
                        controller: controller,
                        findController: _find,
                        readOnly: _readOnly,
                        wordWrap: _wordWrap,
                        autofocus: false,
                        toolbarController: const _EditorMenu(),
                        findBuilder: (context, find, readOnly) =>
                            _FindPanel(controller: find, readOnly: readOnly),
                        style: CodeEditorStyle(
                          fontSize: 13.5,
                          fontFamily: monoFonts.first,
                          fontFamilyFallback: monoFonts.sublist(1),
                          backgroundColor: dark
                              ? const Color(0xFF1E2127)
                              : const Color(0xFFFCFCFC),
                          codeTheme: CodeHighlightTheme(
                            languages: {
                              language.$1: CodeHighlightThemeMode(
                                mode: language.$2,
                              ),
                            },
                            theme: dark ? atomOneDarkTheme : atomOneLightTheme,
                          ),
                        ),
                        indicatorBuilder:
                            (
                              context,
                              editingController,
                              chunkController,
                              notifier,
                            ) => Row(
                              children: [
                                DefaultCodeLineNumber(
                                  controller: editingController,
                                  notifier: notifier,
                                ),
                                DefaultCodeChunkIndicator(
                                  width: 18,
                                  controller: chunkController,
                                  notifier: notifier,
                                ),
                              ],
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

/// 編輯器的右鍵／長按選單。
class _EditorMenu implements SelectionToolbarController {
  const _EditorMenu();

  @override
  void hide(BuildContext context) {}

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    showMenu<void>(
      context: context,
      position: RelativeRect.fromSize(
        anchors.primaryAnchor & const Size(160, double.infinity),
        MediaQuery.sizeOf(context),
      ),
      items: [
        PopupMenuItem(onTap: controller.cut, child: const Text('剪下')),
        PopupMenuItem(onTap: controller.copy, child: const Text('複製')),
        PopupMenuItem(onTap: controller.paste, child: const Text('貼上')),
        PopupMenuItem(onTap: controller.selectAll, child: const Text('全選')),
      ],
    );
  }
}

class _FindPanel extends StatelessWidget implements PreferredSizeWidget {
  const _FindPanel({required this.controller, required this.readOnly});

  final CodeFindController controller;
  final bool readOnly;

  @override
  Size get preferredSize => Size(
    double.infinity,
    controller.value == null
        ? 0
        : controller.value!.replaceMode
        ? 104
        : 56,
  );

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final result = value.result;
    final count = result == null
        ? ''
        : result.matches.isEmpty
        ? '無結果'
        : '${result.index + 1}/${result.matches.length}';

    InputDecoration decoration(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    );

    return Material(
      color: scheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller.findInputController,
                    autofocus: true,
                    decoration: decoration('搜尋'),
                    onSubmitted: (_) => controller.nextMatch(),
                  ),
                ),
                SizedBox(
                  width: 64,
                  child: Text(count, textAlign: TextAlign.center),
                ),
                IconButton(
                  tooltip: '上一個',
                  onPressed: controller.previousMatch,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                ),
                IconButton(
                  tooltip: '下一個',
                  onPressed: controller.nextMatch,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
                if (!readOnly)
                  IconButton(
                    tooltip: '取代',
                    isSelected: value.replaceMode,
                    onPressed: controller.toggleMode,
                    icon: const Icon(Icons.find_replace_rounded),
                  ),
                IconButton(
                  tooltip: '關閉',
                  onPressed: controller.close,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            if (value.replaceMode) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller.replaceInputController,
                      decoration: decoration('取代為'),
                    ),
                  ),
                  TextButton(
                    onPressed: controller.replaceMatch,
                    child: const Text('取代'),
                  ),
                  TextButton(
                    onPressed: controller.replaceAllMatches,
                    child: const Text('全部取代'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 圖片預覽（可縮放）。
class ImagePreviewScreen extends StatefulWidget {
  const ImagePreviewScreen({
    super.key,
    required this.profile,
    required this.path,
  });

  final ServerProfile profile;
  final String path;

  @override
  State<ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<ImagePreviewScreen> {
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final ssh = context.read<SSHService>();
      final size = (await ssh.stat(widget.profile, widget.path)).size ?? 0;
      if (size > 40 * 1024 * 1024) {
        throw const FormatException('圖片超過 40 MB，請下載後再開啟。');
      }
      final bytes = await ssh.readFile(widget.profile, widget.path);
      if (mounted) setState(() => _bytes = bytes);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : describeSshError(error),
        );
      }
    }
  }

  Future<void> _download() async {
    final bytes = _bytes;
    if (bytes == null) return;
    final saved = await FilePicker.saveFile(
      fileName: remoteBaseName(widget.path),
      bytes: bytes,
    );
    if (mounted && saved != null) showMessage(context, '已儲存');
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(remoteBaseName(widget.path)),
        actions: [
          IconButton(
            tooltip: '下載',
            onPressed: bytes == null ? null : _download,
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.white70),
              ),
            )
          : bytes == null
          ? const Center(child: CircularProgressIndicator())
          : InteractiveViewer(
              maxScale: 8,
              child: Center(
                child: Image.memory(
                  bytes,
                  errorBuilder: (_, _, _) => const Text(
                    '無法解碼這張圖片',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
    );
  }
}
