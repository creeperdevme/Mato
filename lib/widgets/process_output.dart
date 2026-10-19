import 'dart:async';

import 'package:flutter/material.dart';

import '../services/ssh_service.dart';
import '../utils/error_messages.dart';
import 'common.dart';

/// 執行遠端指令並即時顯示輸出，結束後回傳結束代碼（失敗或取消時為 null）。
Future<int?> showProcessOutput(
  BuildContext context, {
  required String title,
  required Future<RemoteProcess> Function() start,
}) {
  return showDialog<int?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ProcessOutputDialog(title: title, start: start),
  );
}

class _ProcessOutputDialog extends StatefulWidget {
  const _ProcessOutputDialog({required this.title, required this.start});

  final String title;
  final Future<RemoteProcess> Function() start;

  @override
  State<_ProcessOutputDialog> createState() => _ProcessOutputDialogState();
}

class _ProcessOutputDialogState extends State<_ProcessOutputDialog> {
  final _buffer = StringBuffer();
  final _scroll = ScrollController();
  RemoteProcess? _process;
  StreamSubscription<String>? _subscription;
  bool _running = true;
  int? _exitCode;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final process = await widget.start();
      _process = process;
      _subscription = process.output.listen((chunk) {
        // 進度列常用 \r 覆寫同一行，這裡簡化成換行顯示。
        _buffer.write(chunk.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
        if (_buffer.length > 400000) {
          final text = _buffer.toString();
          _buffer
            ..clear()
            ..write(text.substring(text.length - 300000));
        }
        if (mounted) setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      });
      final code = await process.exitCode;
      if (!mounted) return;
      setState(() {
        _running = false;
        _exitCode = code;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = describeSshError(error);
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _process?.kill();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final success = _exitCode == 0;
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(widget.title)),
          if (_running)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              success ? Icons.check_circle_rounded : Icons.error_rounded,
              color: success ? const Color(0xFF2E7D32) : scheme.error,
            ),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF101614),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      _buffer.isEmpty && _running
                          ? '等待輸出…'
                          : _buffer.toString(),
                      style: monoStyle(
                        fontSize: 12,
                        color: const Color(0xFFD8E3DC),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (!_running) ...[
              const SizedBox(height: 10),
              Text(
                _error ?? '結束代碼：${_exitCode ?? '未知（連線中斷）'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: success ? null : scheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_running)
          TextButton(
            onPressed: () {
              _process?.kill();
              Navigator.pop(context);
            },
            child: const Text('中止'),
          )
        else ...[
          TextButton(
            onPressed: () => copyText(context, _buffer.toString(), label: '輸出'),
            child: const Text('複製'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _exitCode),
            child: const Text('關閉'),
          ),
        ],
      ],
    );
  }
}
