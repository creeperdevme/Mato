import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../models/server_profile.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, required this.profile});

  final ServerProfile profile;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with AutomaticKeepAliveClientMixin {
  final Terminal _terminal = Terminal();
  SSHClient? _client;
  SSHSession? _session;
  bool _connecting = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _session?.close();
    _client?.close();
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
      final socket = await SSHSocket.connect(
        widget.profile.host,
        widget.profile.port,
        timeout: const Duration(seconds: 8),
      );
      final client = SSHClient(
        socket,
        username: widget.profile.username,
        onPasswordRequest: () => widget.profile.password,
        keepAliveInterval: const Duration(seconds: 20),
        handshakeTimeout: const Duration(seconds: 10),
        authTimeout: const Duration(seconds: 10),
        disableHostkeyVerification: true,
      );
      final session = await client.shell(
        pty: SSHPtyConfig(
          width: _terminal.viewWidth,
          height: _terminal.viewHeight,
        ),
      );

      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);
      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        session.resizeTerminal(width, height, pixelWidth, pixelHeight);
      };
      _terminal.onOutput = (output) {
        session.write(Uint8List.fromList(utf8.encode(output)));
      };
      session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write);
      session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_terminal.write);
      session.done.then((_) => _terminal.write('\r\n[連線已結束]\r\n'));

      if (mounted) {
        setState(() {
          _client = client;
          _session = session;
          _connecting = false;
        });
      }
    } catch (error) {
      _terminal.write('連線失敗：$error\r\n');
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        if (_error != null)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: ListTile(
              title: const Text('SSH 連線失敗'),
              subtitle: Text(_error!),
              trailing: TextButton(
                onPressed: _connect,
                child: const Text('重試'),
              ),
            ),
          ),
        Expanded(child: TerminalView(_terminal)),
      ],
    );
  }
}
