import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../models/server_profile.dart';
import '../services/script_store.dart';
import '../services/settings_store.dart';
import '../services/ssh_service.dart';
import '../services/terminal_hub.dart';
import '../utils/error_messages.dart';
import '../utils/format.dart';
import '../utils/shell.dart';
import '../widgets/common.dart';
import '../widgets/terminal_themes.dart';

bool get _isDesktop =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 互動式 SSH 終端機：多分頁、特殊鍵列、片段、ZMODEM 檔案傳輸。
///
/// 桌面平台（Windows／Linux／macOS）改用 `hardwareKeyboardOnly` 直接接收硬體
/// 鍵盤事件：預設的文字輸入連線（IME）在桌面上常常拿不到焦點，會出現「畫
/// 面看得到、卻打不了字」的情況。需要輸入中文時可用「多行輸入」。
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.profile, this.onAskAi});

  final ServerProfile profile;

  /// 把選取的文字（或最後幾行輸出）交給 AI 助理。
  final ValueChanged<String>? onAskAi;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'mato-terminal');
  late final TerminalHub _hub;
  String? _activeId;
  bool? _showKeys;

  @override
  void initState() {
    super.initState();
    _hub = context.read<TerminalHub>()..addListener(_onHubChanged);
    if (_hub.sessionsOf(widget.profile.id).isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open();
      });
    }
  }

  @override
  void dispose() {
    _hub.removeListener(_onHubChanged);
    // 離開頁面後分頁仍在背景運作，但沒有畫面可以詢問 ZMODEM 存檔位置。
    for (final session in _hub.sessionsOf(widget.profile.id)) {
      session.onFileOffer = null;
      session.onFileRequest = null;
    }
    _focusNode.dispose();
    super.dispose();
  }

  void _onHubChanged() {
    if (mounted) setState(() {});
  }

  List<TerminalSession> get _sessions => _hub.sessionsOf(widget.profile.id);

  TerminalSession? get _active {
    final sessions = _sessions;
    if (sessions.isEmpty) return null;
    return sessions.firstWhere(
      (session) => session.id == _activeId,
      orElse: () => sessions.last,
    );
  }

  void _open({SessionMode? mode, String? command, String? title}) {
    final settings = context.read<SettingsStore>();
    final session = _hub.open(
      widget.profile,
      mode: mode,
      command: command,
      title: title,
      scrollback: settings.terminalScrollback,
    );
    setState(() => _activeId = session.id);
    _focus();
  }

  void _focus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus) _focusNode.requestFocus();
    });
  }

  void _attachHandlers(TerminalSession session) {
    session.onFileOffer ??= (offer) => _receiveFile(session, offer);
    session.onFileRequest ??= _sendFiles;
  }

  // ZMODEM --------------------------------------------------------------------

  /// 遠端執行 `sz`：詢問是否接收，接收後另存到本機。
  Future<void> _receiveFile(TerminalSession session, ZModemOffer offer) async {
    final info = offer.info;
    final name = remoteBaseName(info.pathname);
    final accept = await confirmAction(
      context,
      title: '接收檔案（ZMODEM）',
      message:
          '伺服器要傳送「$name」'
          '${info.length == null ? '' : '（${formatBytes(info.length!)}）'}，要接收嗎？',
      confirmLabel: '接收',
    );
    if (!accept) {
      offer.skip();
      return;
    }
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in offer.accept(0)) {
        builder.add(chunk);
      }
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: builder.takeBytes(),
      );
      if (mounted) {
        showMessage(context, saved == null ? '已取消儲存' : '已儲存 $name');
      }
    } catch (error) {
      if (mounted) showMessage(context, '接收失敗：$error', error: true);
    }
  }

  /// 遠端執行 `rz`：選擇本機檔案上傳。
  Future<Iterable<ZModemOffer>> _sendFiles() async {
    final files = await FilePicker.pickFiles(dialogTitle: '選擇要傳送的檔案');
    final sizes = [for (final file in files) await file.length() ?? 0];
    var remainingBytes = sizes.fold<int>(0, (sum, size) => sum + size);
    final offers = <ZModemOffer>[];
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      offers.add(
        ZModemCallbackOffer(
          ZModemFileInfo(
            pathname: file.name,
            length: sizes[i],
            mode: '100644',
            filesRemaining: files.length - i,
            bytesRemaining: remainingBytes,
          ),
          onAccept: (offset) => file.xFile.openRead(offset),
        ),
      );
      remainingBytes -= sizes[i];
    }
    return offers;
  }

  // 工具列動作 -----------------------------------------------------------------

  Future<void> _paste(TerminalSession session) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    session.paste(text);
    _focus();
  }

  void _copy(TerminalSession session) {
    final text = session.selectedText;
    if (text == null) return;
    copyText(context, text, label: '選取的文字');
    session.controller.clearSelection();
  }

  String _recentOutput(TerminalSession session, {int lines = 60}) {
    final all = session.terminal.buffer.getText().trimRight().split('\n');
    return all.skip((all.length - lines).clamp(0, all.length)).join('\n');
  }

  void _askAi(TerminalSession session) {
    final selected = session.selectedText;
    final content = selected ?? _recentOutput(session);
    widget.onAskAi?.call(
      selected == null
          ? '以下是終端機最近的輸出，請幫我看看：\n```\n$content\n```'
          : '請解釋這段終端機內容：\n```\n$content\n```',
    );
  }

  Future<void> _typePassword(TerminalSession session) async {
    final password = widget.profile.password;
    if (password.isEmpty) {
      showMessage(context, '這台伺服器沒有儲存密碼', error: true);
      return;
    }
    session.sendText(password);
    _focus();
  }

  Future<void> _multiLine(TerminalSession session) async {
    final text = await promptText(
      context,
      title: '多行輸入',
      hint: '可輸入多行指令或中文，送出後依序執行',
      confirmLabel: '送出',
      multiline: true,
      monospace: true,
    );
    if (text == null || text.isEmpty) return;
    session.paste(text);
    if (!text.endsWith('\n')) session.sendText('\r');
    _focus();
  }

  Future<void> _snippets(TerminalSession session) async {
    final scripts = context.read<ScriptStore>().scripts;
    final result = await showModalBottomSheet<(String, bool)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: scripts.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('腳本庫是空的，可以到「腳本」分頁新增常用指令。'),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    const ListTile(
                      title: Text('快捷片段'),
                      subtitle: Text('點一下貼上，按「執行」直接送出'),
                    ),
                    for (final script in scripts)
                      ListTile(
                        leading: const Icon(Icons.bolt_rounded),
                        title: Text(script.name),
                        subtitle: Text(
                          script.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(fontSize: 12),
                        ),
                        onTap: () => Navigator.pop(sheetContext, (
                          script.content,
                          false,
                        )),
                        trailing: TextButton(
                          onPressed: () => Navigator.pop(sheetContext, (
                            script.content,
                            true,
                          )),
                          child: const Text('執行'),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
    if (result == null) return;
    session.paste(result.$1);
    if (result.$2) session.sendText('\r');
    _focus();
  }

  /// 「為 Claude Code 等 CLI 工具設計」：上傳檔案到伺服器，並把路徑貼進終端機。
  Future<void> _uploadAndPaste(TerminalSession session) async {
    final files = await FilePicker.pickFiles(dialogTitle: '選擇要上傳的檔案或圖片');
    if (files.isEmpty || !mounted) return;
    final ssh = context.read<SSHService>();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final directory = '/tmp/mato-upload-$stamp';
    try {
      final paths = await runWithProgress(
        context,
        '正在上傳 ${files.length} 個檔案…',
        () async {
          await ssh.createDirectory(widget.profile, directory);
          final uploaded = <String>[];
          for (final file in files) {
            final remote = joinRemotePath(directory, file.name);
            await ssh.upload(
              widget.profile,
              remote,
              file.readAsByteStream(),
              await file.length() ?? 0,
            );
            uploaded.add(remote);
          }
          return uploaded;
        },
      );
      session.paste('${paths.map(shellQuote).join(' ')} ');
      _focus();
    } catch (error) {
      if (mounted) {
        showMessage(context, '上傳失敗：${describeSshError(error)}', error: true);
      }
    }
  }

  Future<void> _attachTmux() async {
    final ssh = context.read<SSHService>();
    try {
      final result = await ssh.run(
        widget.profile,
        "tmux ls -F '#{session_name}|#{session_windows}|#{?session_attached,attached,detached}' 2>&1",
      );
      final lines = result.stdout
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.contains('|'))
          .toList();
      if (!mounted) return;
      if (!result.success || lines.isEmpty) {
        showMessage(
          context,
          result.stdout.contains('not found')
              ? '伺服器沒有安裝 tmux'
              : '目前沒有 tmux 工作階段',
        );
        return;
      }
      final name = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('附加到 tmux 工作階段')),
              for (final line in lines)
                Builder(
                  builder: (_) {
                    final parts = line.split('|');
                    return ListTile(
                      leading: const Icon(Icons.layers_outlined),
                      title: Text(parts[0]),
                      subtitle: Text(
                        '${parts.length > 1 ? parts[1] : '?'} 個視窗'
                        '${parts.length > 2 && parts[2] == 'attached' ? ' · 已有連線' : ''}',
                      ),
                      onTap: () => Navigator.pop(sheetContext, parts[0]),
                    );
                  },
                ),
            ],
          ),
        ),
      );
      if (name == null) return;
      _open(
        command: 'tmux attach -t ${shellQuote(name)}',
        title: 'tmux · $name',
      );
    } catch (error) {
      if (mounted) showMessage(context, describeSshError(error), error: true);
    }
  }

  void _close(TerminalSession session) {
    _hub.close(session);
    final remaining = _sessions;
    setState(() => _activeId = remaining.isEmpty ? null : remaining.last.id);
  }

  void _showContextMenu(TerminalSession session, Offset position) {
    final hasSelection = session.selectedText != null;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'copy',
          enabled: hasSelection,
          child: const Text('複製'),
        ),
        const PopupMenuItem(value: 'paste', child: Text('貼上')),
        if (widget.onAskAi != null)
          PopupMenuItem(
            value: 'ai',
            child: Text(hasSelection ? '把選取內容交給 AI' : '把最近輸出交給 AI'),
          ),
        const PopupMenuItem(value: 'clear', child: Text('清除畫面')),
      ],
    ).then((value) {
      switch (value) {
        case 'copy':
          _copy(session);
        case 'paste':
          _paste(session);
        case 'ai':
          _askAi(session);
        case 'clear':
          session.sendText('\x0c');
      }
    });
  }

  Map<ShortcutActivator, Intent> get _shortcuts {
    if (Platform.isMacOS || Platform.isIOS) {
      return {
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
            CopySelectionTextIntent.copy,
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            const PasteTextIntent(SelectionChangedCause.keyboard),
      };
    }
    // Ctrl+A／Ctrl+V 要留給 shell（游標移到行首、逐字輸入），複製貼上改用
    // Ctrl+Shift+C／V，與一般 Linux 終端機一致。
    return {
      const SingleActivator(
        LogicalKeyboardKey.keyC,
        control: true,
        shift: true,
      ): CopySelectionTextIntent.copy,
      const SingleActivator(
        LogicalKeyboardKey.keyV,
        control: true,
        shift: true,
      ): const PasteTextIntent(
        SelectionChangedCause.keyboard,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final sessions = _sessions;
    final active = _active;
    final palette = paletteById(settings.terminalTheme);
    final showKeys = _showKeys ?? settings.extraKeysOverride ?? !_isDesktop;
    for (final session in sessions) {
      _attachHandlers(session);
    }

    return Column(
      children: [
        _SessionBar(
          sessions: sessions,
          active: active,
          onSelect: (session) {
            setState(() => _activeId = session.id);
            _focus();
          },
          onClose: _close,
          onNew: (mode) => _open(mode: mode),
          onAttachTmux: _attachTmux,
          actions: active == null
              ? const []
              : [
                  _ToolButton(
                    icon: Icons.content_paste_rounded,
                    tooltip: _isDesktop ? '貼上（Ctrl+Shift+V）' : '貼上',
                    onPressed: () => _paste(active),
                  ),
                  ListenableBuilder(
                    listenable: active.controller,
                    builder: (context, _) => _ToolButton(
                      icon: Icons.copy_rounded,
                      tooltip: '複製選取內容',
                      onPressed: active.controller.selection == null
                          ? null
                          : () => _copy(active),
                    ),
                  ),
                  _ToolButton(
                    icon: Icons.bolt_rounded,
                    tooltip: '快捷片段',
                    onPressed: () => _snippets(active),
                  ),
                  _ToolButton(
                    icon: Icons.upload_file_rounded,
                    tooltip: '上傳檔案並貼上路徑',
                    onPressed: () => _uploadAndPaste(active),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    icon: const Icon(Icons.more_horiz_rounded, size: 20),
                    onSelected: (value) {
                      switch (value) {
                        case 'multiline':
                          _multiLine(active);
                        case 'password':
                          _typePassword(active);
                        case 'ai':
                          _askAi(active);
                        case 'bigger':
                          settings.terminalFontSize =
                              settings.terminalFontSize + 1;
                        case 'smaller':
                          settings.terminalFontSize =
                              settings.terminalFontSize - 1;
                        case 'keys':
                          setState(() => _showKeys = !showKeys);
                        case 'clear':
                          active.sendText('\x0c');
                        case 'reconnect':
                          _hub.reconnect(active, widget.profile);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'multiline',
                        child: ListTile(
                          leading: Icon(Icons.notes_rounded),
                          title: Text('多行輸入'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'password',
                        enabled: widget.profile.password.isNotEmpty,
                        child: const ListTile(
                          leading: Icon(Icons.password_rounded),
                          title: Text('輸入已存密碼'),
                        ),
                      ),
                      if (widget.onAskAi != null)
                        const PopupMenuItem(
                          value: 'ai',
                          child: ListTile(
                            leading: Icon(Icons.auto_awesome_rounded),
                            title: Text('交給 AI 助理'),
                          ),
                        ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'bigger',
                        child: ListTile(
                          leading: const Icon(Icons.text_increase_rounded),
                          title: Text(
                            '放大字級（${settings.terminalFontSize.round()}）',
                          ),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'smaller',
                        child: ListTile(
                          leading: Icon(Icons.text_decrease_rounded),
                          title: Text('縮小字級'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'keys',
                        child: ListTile(
                          leading: const Icon(Icons.keyboard_alt_outlined),
                          title: Text(showKeys ? '隱藏特殊鍵列' : '顯示特殊鍵列'),
                        ),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'clear',
                        child: ListTile(
                          leading: Icon(Icons.cleaning_services_outlined),
                          title: Text('清除畫面'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'reconnect',
                        child: ListTile(
                          leading: Icon(Icons.sync_rounded),
                          title: Text('重新連線'),
                        ),
                      ),
                    ],
                  ),
                ],
        ),
        Expanded(
          child: active == null
              ? EmptyState(
                  icon: Icons.terminal_rounded,
                  title: '沒有開啟的終端機',
                  action: FilledButton.icon(
                    onPressed: _open,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('開啟新的終端機'),
                  ),
                )
              : ListenableBuilder(
                  listenable: active,
                  builder: (context, _) => Stack(
                    children: [
                      Positioned.fill(
                        child: ColoredBox(
                          color: palette.theme.background,
                          child: TerminalView(
                            active.terminal,
                            key: ValueKey(active.id),
                            controller: active.controller,
                            focusNode: _focusNode,
                            autofocus: true,
                            hardwareKeyboardOnly: _isDesktop,
                            padding: const EdgeInsets.all(8),
                            theme: palette.theme,
                            keyboardAppearance: palette.light
                                ? Brightness.light
                                : Brightness.dark,
                            cursorType: switch (settings.terminalCursor) {
                              TerminalCursorStyle.block =>
                                TerminalCursorType.block,
                              TerminalCursorStyle.underline =>
                                TerminalCursorType.underline,
                              TerminalCursorStyle.bar =>
                                TerminalCursorType.verticalBar,
                            },
                            textStyle: TerminalStyle(
                              fontSize: settings.terminalFontSize,
                              fontFamily: settings.terminalFontFamily.isEmpty
                                  ? monoFonts.first
                                  : settings.terminalFontFamily,
                              fontFamilyFallback: monoFonts,
                            ),
                            shortcuts: _shortcuts,
                            onSecondaryTapDown: (details, _) =>
                                _showContextMenu(
                                  active,
                                  details.globalPosition,
                                ),
                          ),
                        ),
                      ),
                      if (active.state != TerminalSessionState.connected)
                        Positioned(
                          left: 12,
                          right: 12,
                          bottom: 12,
                          child: _StatusBanner(
                            session: active,
                            onRetry: () =>
                                _hub.reconnect(active, widget.profile),
                            onClose: () => _close(active),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        if (active != null && showKeys)
          ListenableBuilder(
            listenable: active,
            builder: (context, _) => _ExtraKeys(
              session: active,
              haptics: settings.keyHaptics,
              onKeyboard: () {
                if (_focusNode.hasFocus) {
                  _focusNode.unfocus();
                } else {
                  _focusNode.requestFocus();
                }
              },
            ),
          ),
      ],
    );
  }
}

class _SessionBar extends StatelessWidget {
  const _SessionBar({
    required this.sessions,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onNew,
    required this.onAttachTmux,
    required this.actions,
  });

  final List<TerminalSession> sessions;
  final TerminalSession? active;
  final ValueChanged<TerminalSession> onSelect;
  final ValueChanged<TerminalSession> onClose;
  final ValueChanged<SessionMode> onNew;
  final VoidCallback onAttachTmux;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                children: [
                  for (final session in sessions)
                    _SessionTab(
                      session: session,
                      selected: identical(session, active),
                      onTap: () => onSelect(session),
                      onClose: () => onClose(session),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '新增終端機',
                    icon: const Icon(Icons.add_rounded, size: 20),
                    onSelected: (value) {
                      switch (value) {
                        case 'shell':
                          onNew(SessionMode.shell);
                        case 'tmux':
                          onNew(SessionMode.tmux);
                        case 'zellij':
                          onNew(SessionMode.zellij);
                        case 'attach':
                          onAttachTmux();
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'shell',
                        child: ListTile(
                          leading: Icon(Icons.terminal_rounded),
                          title: Text('新 Shell'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'tmux',
                        child: ListTile(
                          leading: Icon(Icons.layers_outlined),
                          title: Text('tmux（斷線可接回）'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'zellij',
                        child: ListTile(
                          leading: Icon(Icons.dashboard_outlined),
                          title: Text('zellij'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'attach',
                        child: ListTile(
                          leading: Icon(Icons.link_rounded),
                          title: Text('附加既有 tmux 工作階段…'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            ...actions,
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

class _SessionTab extends StatelessWidget {
  const _SessionTab({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final TerminalSession session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = switch (session.state) {
      TerminalSessionState.connected => const Color(0xFF2E7D32),
      TerminalSessionState.connecting => const Color(0xFFF9A825),
      TerminalSessionState.failed => scheme.error,
      TerminalSessionState.closed => scheme.outline,
    };
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusDot(
                  color: color,
                  animate: session.state == TerminalSessionState.connecting,
                  size: 7,
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Tooltip(
                    message: session.remoteTitle.isEmpty
                        ? session.title
                        : session.remoteTitle,
                    child: Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '關閉分頁',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      iconSize: 20,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.session,
    required this.onRetry,
    required this.onClose,
  });

  final TerminalSession session;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = session.state == TerminalSessionState.failed;
    final connecting = session.state == TerminalSessionState.connecting;

    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: failed ? scheme.errorContainer : scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            if (connecting)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                failed ? Icons.error_outline_rounded : Icons.link_off_rounded,
                color: failed ? scheme.error : scheme.onSurfaceVariant,
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                connecting
                    ? (session.stage.isEmpty ? '連線中…' : session.stage)
                    : failed
                    ? '連線失敗：${session.error ?? ''}'
                    : '連線已結束',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: failed ? scheme.onErrorContainer : null,
                ),
              ),
            ),
            if (!connecting) ...[
              TextButton(onPressed: onClose, child: const Text('關閉')),
              FilledButton.tonal(onPressed: onRetry, child: const Text('重新連線')),
            ],
          ],
        ),
      ),
    );
  }
}

/// 行動裝置的特殊鍵列：Esc、Tab、黏住的 Ctrl／Alt、方向鍵與常用符號。
class _ExtraKeys extends StatelessWidget {
  const _ExtraKeys({
    required this.session,
    required this.haptics,
    required this.onKeyboard,
  });

  final TerminalSession session;
  final bool haptics;
  final VoidCallback onKeyboard;

  void _tap(VoidCallback action) {
    if (haptics) HapticFeedback.selectionClick();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keys = <Widget>[
      _KeyButton(
        icon: Icons.keyboard_rounded,
        tooltip: '鍵盤',
        onTap: () => _tap(onKeyboard),
      ),
      _KeyButton(
        label: 'ESC',
        onTap: () => _tap(() => session.sendKey(TerminalKey.escape)),
      ),
      _KeyButton(
        label: 'TAB',
        onTap: () => _tap(() => session.sendKey(TerminalKey.tab)),
      ),
      _KeyButton(
        label: 'CTRL',
        active: session.ctrlLatched,
        onTap: () => _tap(session.toggleCtrl),
      ),
      _KeyButton(
        label: 'ALT',
        active: session.altLatched,
        onTap: () => _tap(session.toggleAlt),
      ),
      _KeyButton(
        icon: Icons.keyboard_arrow_left_rounded,
        repeat: true,
        onTap: () => _tap(() => session.sendKey(TerminalKey.arrowLeft)),
      ),
      _KeyButton(
        icon: Icons.keyboard_arrow_up_rounded,
        repeat: true,
        onTap: () => _tap(() => session.sendKey(TerminalKey.arrowUp)),
      ),
      _KeyButton(
        icon: Icons.keyboard_arrow_down_rounded,
        repeat: true,
        onTap: () => _tap(() => session.sendKey(TerminalKey.arrowDown)),
      ),
      _KeyButton(
        icon: Icons.keyboard_arrow_right_rounded,
        repeat: true,
        onTap: () => _tap(() => session.sendKey(TerminalKey.arrowRight)),
      ),
      _KeyButton(
        label: '^C',
        onTap: () => _tap(() => session.sendText('\x03')),
      ),
      _KeyButton(
        label: '^D',
        onTap: () => _tap(() => session.sendText('\x04')),
      ),
      _KeyButton(
        label: 'HOME',
        onTap: () => _tap(() => session.sendKey(TerminalKey.home)),
      ),
      _KeyButton(
        label: 'END',
        onTap: () => _tap(() => session.sendKey(TerminalKey.end)),
      ),
      _KeyButton(
        label: 'PGUP',
        onTap: () => _tap(() => session.sendKey(TerminalKey.pageUp)),
      ),
      _KeyButton(
        label: 'PGDN',
        onTap: () => _tap(() => session.sendKey(TerminalKey.pageDown)),
      ),
      for (final symbol in const [
        '|',
        '/',
        '-',
        '~',
        '_',
        '`',
        r'$',
        '&',
        '*',
        ':',
      ])
        _KeyButton(
          label: symbol,
          onTap: () => _tap(() => session.terminal.textInput(symbol)),
        ),
    ];

    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 46,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            itemCount: keys.length,
            separatorBuilder: (_, _) => const SizedBox(width: 5),
            itemBuilder: (context, index) => keys[index],
          ),
        ),
      ),
    );
  }
}

class _KeyButton extends StatefulWidget {
  const _KeyButton({
    this.label,
    this.icon,
    this.tooltip,
    required this.onTap,
    this.active = false,
    this.repeat = false,
  });

  final String? label;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback onTap;
  final bool active;

  /// 長按連續送出（方向鍵）。
  final bool repeat;

  @override
  State<_KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<_KeyButton> {
  Timer? _timer;

  void _startRepeat() {
    if (!widget.repeat) return;
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(milliseconds: 70),
      (_) => widget.onTap(),
    );
  }

  void _stopRepeat() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopRepeat();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final button = Material(
      color: widget.active ? scheme.primary : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: widget.onTap,
        onLongPress: widget.repeat ? _startRepeat : null,
        onTapCancel: _stopRepeat,
        onTapUp: (_) => _stopRepeat(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 42),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Center(
              child: widget.icon != null
                  ? Icon(
                      widget.icon,
                      size: 20,
                      color: widget.active
                          ? scheme.onPrimary
                          : scheme.onSurface,
                    )
                  : Text(
                      widget.label!,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: widget.active
                            ? scheme.onPrimary
                            : scheme.onSurface,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
    return Listener(
      onPointerUp: (_) => _stopRepeat(),
      child: widget.tooltip == null
          ? button
          : Tooltip(message: widget.tooltip!, child: button),
    );
  }
}
