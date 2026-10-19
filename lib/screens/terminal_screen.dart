import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../models/server_profile.dart';
import '../services/ssh_service.dart';

/// 互動式 SSH 終端機。
///
/// 桌面平台（Windows／Linux／macOS）改用 `hardwareKeyboardOnly` 直接接收硬體
/// 鍵盤事件：預設的文字輸入連線（IME）在桌面上常常拿不到焦點，會出現「畫
/// 面看得到、卻打不了字」的情況。
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.profile});

  final ServerProfile profile;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with AutomaticKeepAliveClientMixin {
  final Terminal _terminal = Terminal();
  final FocusNode _focusNode = FocusNode(debugLabel: 'mato-terminal');

  SshConnection? _connection;
  bool _connecting = false;
  String? _error;

  /// 桌面平台只吃硬體鍵盤事件，避免 IME 輸入連線在桌面失效。
  bool get _hardwareKeyboardOnly =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get _connected => _connection != null;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _connection?.close();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    _terminal.write('正在連線...\r\n');

    try {
      final connection = await context
          .read<SSHService>()
          .openShell(
            widget.profile,
            width: _terminal.viewWidth,
            height: _terminal.viewHeight,
          );

      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);

      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        connection.session.resizeTerminal(
          width,
          height,
          pixelWidth,
          pixelHeight,
        );
      };
      _terminal.onOutput = (output) {
        connection.session.write(Uint8List.fromList(utf8.encode(output)));
      };

      connection.session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write);
      connection.session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write);

      connection.session.done.then((_) {
        _terminal.write('\r\n[連線已結束]\r\n');
        if (!mounted) return;
        setState(() {
          _connection = null;
          _connecting = false;
        });
      });

      if (!mounted) {
        connection.close();
        return;
      }
      setState(() {
        _connection = connection;
        _connecting = false;
      });
      // 連上就把焦點交給終端機，鍵盤可立即使用。
      _requestFocus();
    } catch (error) {
      _terminal.write('連線失敗：$error\r\n');
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = error.toString();
      });
    }
  }

  void _requestFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus) _focusNode.requestFocus();
    });
  }

  Future<void> _reconnect() async {
    _connection?.close();
    _connection = null;
    if (mounted) setState(() {});
    await _connect();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);

    return Column(
      children: [
        _StatusBar(
          connecting: _connecting,
          connected: _connected,
          error: _error,
          onRetry: _reconnect,
          onFocus: () => _focusNode.requestFocus(),
        ),
        Expanded(
          child: ColoredBox(
            color: theme.brightness == Brightness.dark
                ? const Color(0xFF101614)
                : theme.colorScheme.surfaceContainerHighest,
            child: TerminalView(
              _terminal,
              focusNode: _focusNode,
              autofocus: true,
              hardwareKeyboardOnly: _hardwareKeyboardOnly,
              padding: const EdgeInsets.all(8),
              textStyle: const TerminalStyle(fontSize: 13.5),
              theme: TerminalThemes.defaultTheme,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.connecting,
    required this.connected,
    required this.error,
    required this.onRetry,
    required this.onFocus,
  });

  final bool connecting;
  final bool connected;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = error != null;

    final Color color;
    final String label;
    if (failed) {
      color = scheme.error;
      label = '連線失敗';
    } else if (connecting) {
      color = const Color(0xFFF9A825);
      label = '連線中…';
    } else if (connected) {
      color = const Color(0xFF2E7D32);
      label = '已連線 · 可直接輸入指令';
    } else {
      color = scheme.onSurfaceVariant;
      label = '未連線';
    }

    return Material(
      color: failed
          ? scheme.errorContainer.withValues(alpha: 0.5)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                failed ? '$label：$error' : label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: failed ? scheme.onErrorContainer : scheme.onSurface,
                ),
              ),
            ),
            if (failed)
              TextButton(onPressed: onRetry, child: const Text('重試'))
            else
              IconButton(
                tooltip: '聚焦終端機（鍵盤輸入）',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.keyboard_alt_outlined, size: 20),
                onPressed: onFocus,
              ),
            if (!failed)
              IconButton(
                tooltip: '重新連線',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, size: 20),
                onPressed: connecting ? null : onRetry,
              ),
          ],
        ),
      ),
    );
  }
}
