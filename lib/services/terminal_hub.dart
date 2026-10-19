import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import '../models/server_profile.dart';
import '../utils/error_messages.dart';
import '../utils/shell.dart';
import 'ssh_service.dart';

enum TerminalSessionState { connecting, connected, closed, failed }

/// 一個終端機分頁。離開伺服器頁面後仍在背景保留，回來可以接著用。
class TerminalSession extends ChangeNotifier {
  TerminalSession({
    required this.serverId,
    required this.title,
    required this.mode,
    this.sessionName = 'mato',
    this.command,
    this.initialInput,
    int scrollback = 5000,
  }) : terminal = Terminal(maxLines: scrollback) {
    terminal.onTitleChange = (value) {
      remoteTitle = value;
      notifyListeners();
    };
  }

  final String id = const Uuid().v4();
  final String serverId;
  final String title;
  final SessionMode mode;
  final String sessionName;

  /// 取代 shell 執行的指令，例如 `docker exec -it ... sh`。
  final String? command;

  /// 連上後自動輸入的一行指令（只在第一次連線時送出）。
  String? initialInput;
  final Terminal terminal;
  final TerminalController controller = TerminalController();

  /// 遠端以 OSC 設定的視窗標題（通常是 `user@host: cwd`）。
  String remoteTitle = '';
  TerminalSessionState state = TerminalSessionState.connecting;
  String stage = '';
  String? error;

  /// 特殊鍵列上「黏住」的修飾鍵，套用到下一個輸入後自動放開。
  bool ctrlLatched = false;
  bool altLatched = false;

  /// ZMODEM：遠端執行 `sz` 時會收到檔案提供，`rz` 時會要求檔案。
  ZModemOfferHandler? onFileOffer;
  ZModemRequestHandler? onFileRequest;

  SshLease? _lease;
  SSHSession? _session;
  ZModemMux? _mux;
  bool _disposed = false;

  bool get connected => state == TerminalSessionState.connected;

  Future<void> connect(SSHService ssh, ServerProfile profile) async {
    if (state == TerminalSessionState.connected) return;
    state = TerminalSessionState.connecting;
    error = null;
    stage = '準備連線…';
    _notify();
    terminal.write(
      '\x1b[2m正在連線到 ${profile.name}（${profile.address}）…\x1b[0m\r\n',
    );

    try {
      final lease = await ssh.lease(
        profile,
        onProgress: (value) {
          stage = value;
          _notify();
        },
      );
      if (_disposed) {
        lease.release();
        return;
      }
      _lease = lease;
      final pty = SSHPtyConfig(
        width: terminal.viewWidth,
        height: terminal.viewHeight,
      );
      final remoteCommand = _remoteCommand();
      final session = remoteCommand == null
          ? await lease.client.shell(pty: pty)
          : await lease.client.execute(remoteCommand, pty: pty);
      _session = session;

      final mux = ZModemMux(stdin: session.stdin, stdout: session.stdout);
      mux.onTerminalInput = terminal.write;
      mux.onFileOffer = (offer) {
        final handler = onFileOffer;
        if (handler == null) {
          offer.skip();
        } else {
          handler(offer);
        }
      };
      mux.onFileRequest = () async =>
          await onFileRequest?.call() ?? const <ZModemOffer>[];
      _mux = mux;

      session.stderr
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(terminal.write);
      terminal.onOutput = _handleInput;
      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        session.resizeTerminal(width, height, pixelWidth, pixelHeight);
      };

      unawaited(
        session.done.then((_) {}, onError: (_) {}).whenComplete(() {
          if (!identical(_session, session)) return;
          _detach();
          state = TerminalSessionState.closed;
          terminal.write('\r\n\x1b[2m[連線已結束]\x1b[0m\r\n');
          _notify();
        }),
      );

      state = TerminalSessionState.connected;
      stage = '';
      _notify();

      if (remoteCommand == null && profile.startupCommand.trim().isNotEmpty) {
        mux.terminalWrite('${profile.startupCommand.trim()}\r');
      }
      final input = initialInput;
      if (input != null && input.isNotEmpty) {
        initialInput = null;
        mux.terminalWrite('$input\r');
      }
    } catch (failure) {
      _detach();
      state = TerminalSessionState.failed;
      error = describeSshError(failure);
      terminal.write('\r\n\x1b[31m連線失敗：$error\x1b[0m\r\n');
      _notify();
    }
  }

  String? _remoteCommand() {
    if (command != null) return command;
    final name = shellQuote(sessionName.isEmpty ? 'mato' : sessionName);
    switch (mode) {
      case SessionMode.shell:
        return null;
      case SessionMode.tmux:
        return posixShell(
          'if command -v tmux >/dev/null 2>&1; then '
          'exec tmux new-session -A -s $name; '
          'else echo "找不到 tmux，改用一般 shell"; exec "\${SHELL:-sh}" -l; fi',
        );
      case SessionMode.zellij:
        return posixShell(
          'if command -v zellij >/dev/null 2>&1; then '
          'exec zellij attach -c $name; '
          'else echo "找不到 zellij，改用一般 shell"; exec "\${SHELL:-sh}" -l; fi',
        );
    }
  }

  /// 終端機（含軟體鍵盤、貼上）產生的輸入；套用黏住的 Ctrl／Alt。
  void _handleInput(String data) => _mux?.terminalWrite(applyModifiers(data));

  /// 把黏住的修飾鍵套用到 [data]（例如 Ctrl + `c` → `\x03`），用完即放開。
  String applyModifiers(String data) {
    if (!(ctrlLatched || altLatched) || data.isEmpty) return data;
    var output = data;
    if (ctrlLatched && data.length == 1) output = _ctrlChar(data) ?? data;
    if (altLatched) output = '\x1b$output';
    ctrlLatched = false;
    altLatched = false;
    _notify();
    return output;
  }

  static String? _ctrlChar(String value) {
    final code = value.toLowerCase().codeUnitAt(0);
    if (code >= 0x61 && code <= 0x7a) return String.fromCharCode(code - 0x60);
    switch (value) {
      case ' ':
      case '@':
      case '2':
        return '\x00';
      case '[':
        return '\x1b';
      case '\\':
        return '\x1c';
      case ']':
        return '\x1d';
      case '^':
      case '6':
        return '\x1e';
      case '_':
      case '-':
        return '\x1f';
      case '?':
        return '\x7f';
    }
    return null;
  }

  /// 送出特殊鍵（方向鍵、Esc、Tab…），會套用黏住的修飾鍵。
  void sendKey(TerminalKey key) {
    final ctrl = ctrlLatched;
    final alt = altLatched;
    if (ctrl || alt) {
      ctrlLatched = false;
      altLatched = false;
      _notify();
    }
    terminal.keyInput(key, ctrl: ctrl, alt: alt);
  }

  /// 直接送出文字（不經過修飾鍵）。
  void sendText(String text) => _mux?.terminalWrite(text);

  /// 以貼上的方式送出（遠端支援時會包 bracketed paste）。
  void paste(String text) => terminal.paste(text);

  void toggleCtrl() {
    ctrlLatched = !ctrlLatched;
    _notify();
  }

  void toggleAlt() {
    altLatched = !altLatched;
    _notify();
  }

  String? get selectedText {
    final selection = controller.selection;
    if (selection == null) return null;
    final text = terminal.buffer.getText(selection);
    return text.isEmpty ? null : text;
  }

  void _detach() {
    _session = null;
    _mux = null;
    _lease?.release();
    _lease = null;
  }

  void close() {
    final session = _session;
    _detach();
    session?.close();
    state = TerminalSessionState.closed;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    close();
    controller.dispose();
    super.dispose();
  }
}

/// 所有伺服器的終端機分頁。
class TerminalHub extends ChangeNotifier {
  TerminalHub(this._ssh);

  final SSHService _ssh;
  final Map<String, List<TerminalSession>> _sessions = {};
  final Map<String, int> _counters = {};

  List<TerminalSession> sessionsOf(String serverId) =>
      List.unmodifiable(_sessions[serverId] ?? const []);

  int activeCount(String serverId) =>
      (_sessions[serverId] ?? const []).where((item) => item.connected).length;

  TerminalSession open(
    ServerProfile profile, {
    SessionMode? mode,
    String? command,
    String? title,
    String? initialInput,
    int scrollback = 5000,
  }) {
    final effectiveMode = command != null
        ? SessionMode.shell
        : mode ?? profile.sessionMode;
    final number = (_counters[profile.id] ?? 0) + 1;
    _counters[profile.id] = number;
    final label =
        title ??
        switch (effectiveMode) {
          SessionMode.shell => 'Shell $number',
          SessionMode.tmux => 'tmux · ${profile.sessionName}',
          SessionMode.zellij => 'zellij · ${profile.sessionName}',
        };
    final session = TerminalSession(
      serverId: profile.id,
      title: label,
      mode: effectiveMode,
      sessionName: profile.sessionName,
      command: command,
      initialInput: initialInput,
      scrollback: scrollback,
    );
    _sessions.putIfAbsent(profile.id, () => []).add(session);
    session.addListener(notifyListeners);
    notifyListeners();
    unawaited(session.connect(_ssh, profile));
    return session;
  }

  Future<void> reconnect(TerminalSession session, ServerProfile profile) async {
    session.close();
    await session.connect(_ssh, profile);
  }

  void close(TerminalSession session) {
    _sessions[session.serverId]?.remove(session);
    session.removeListener(notifyListeners);
    session.dispose();
    notifyListeners();
  }

  void closeAll(String serverId) {
    for (final session in List.of(_sessions[serverId] ?? const [])) {
      close(session);
    }
  }
}
