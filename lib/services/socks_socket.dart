import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// 透過 SOCKS5 代理建立的 TCP 連線，交握完成後當成一般 [SSHSocket] 使用。
class SocksSSHSocket implements SSHSocket {
  SocksSSHSocket._(this._socket, this._controller);

  final Socket _socket;
  final StreamController<Uint8List> _controller;

  static Future<SocksSSHSocket> connect({
    required String proxyHost,
    required int proxyPort,
    required String targetHost,
    required int targetPort,
    String username = '',
    String password = '',
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
    final reader = _ByteReader(socket);
    try {
      await _handshake(
        socket,
        reader,
        targetHost: targetHost,
        targetPort: targetPort,
        username: username,
        password: password,
      ).timeout(timeout);
    } catch (_) {
      await reader.cancel();
      socket.destroy();
      rethrow;
    }
    return SocksSSHSocket._(socket, reader.detach());
  }

  static Future<void> _handshake(
    Socket socket,
    _ByteReader reader, {
    required String targetHost,
    required int targetPort,
    required String username,
    required String password,
  }) async {
    final useAuth = username.isNotEmpty;
    socket.add(useAuth ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]);
    final greeting = await reader.read(2);
    if (greeting[0] != 0x05) {
      throw const SocketException('代理伺服器不是 SOCKS5');
    }
    if (greeting[1] == 0x02) {
      final user = utf8.encode(username);
      final pass = utf8.encode(password);
      socket.add([0x01, user.length, ...user, pass.length, ...pass]);
      final auth = await reader.read(2);
      if (auth[1] != 0x00) {
        throw const SocketException('SOCKS5 代理驗證失敗');
      }
    } else if (greeting[1] != 0x00) {
      throw const SocketException('SOCKS5 代理不接受此驗證方式');
    }

    final address = InternetAddress.tryParse(targetHost);
    final List<int> addressBytes;
    if (address?.type == InternetAddressType.IPv4) {
      addressBytes = [0x01, ...address!.rawAddress];
    } else if (address?.type == InternetAddressType.IPv6) {
      addressBytes = [0x04, ...address!.rawAddress];
    } else {
      final host = utf8.encode(targetHost);
      addressBytes = [0x03, host.length, ...host];
    }
    socket.add([
      0x05,
      0x01,
      0x00,
      ...addressBytes,
      (targetPort >> 8) & 0xff,
      targetPort & 0xff,
    ]);

    final reply = await reader.read(4);
    if (reply[1] != 0x00) {
      throw SocketException('SOCKS5 代理無法連到目標（錯誤碼 ${reply[1]}）');
    }
    // 讀掉代理回報的綁定位址與連接埠。
    switch (reply[3]) {
      case 0x01:
        await reader.read(4 + 2);
      case 0x04:
        await reader.read(16 + 2);
      case 0x03:
        final length = (await reader.read(1))[0];
        await reader.read(length + 2);
      default:
        throw const SocketException('SOCKS5 回應格式錯誤');
    }
  }

  @override
  Stream<Uint8List> get stream => _controller.stream;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async {
    await _socket.close();
  }

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}

/// 在交握階段逐位元組讀取，交握後把剩餘資料與後續串流交給 SSH。
class _ByteReader {
  _ByteReader(Socket socket) {
    _subscription = socket.listen(
      (data) {
        if (_detached != null) {
          _detached!.add(data);
          return;
        }
        _buffer.addAll(data);
        _pump();
      },
      onError: (Object error, StackTrace stack) {
        if (_detached != null) {
          _detached!.addError(error, stack);
        } else {
          _fail(error);
        }
      },
      onDone: () {
        if (_detached != null) {
          _detached!.close();
        } else {
          _fail(const SocketException('代理伺服器關閉了連線'));
        }
      },
    );
  }

  late final StreamSubscription<Uint8List> _subscription;
  final List<int> _buffer = [];
  int _wanted = 0;
  Completer<Uint8List>? _waiting;
  StreamController<Uint8List>? _detached;

  Future<Uint8List> read(int length) {
    // 資料可能已在緩衝區，_pump 會同步完成並清掉 _waiting，所以先留住參照。
    final completer = Completer<Uint8List>();
    _wanted = length;
    _waiting = completer;
    _pump();
    return completer.future;
  }

  void _pump() {
    final waiting = _waiting;
    if (waiting == null || _buffer.length < _wanted) return;
    final chunk = Uint8List.fromList(_buffer.sublist(0, _wanted));
    _buffer.removeRange(0, _wanted);
    _waiting = null;
    waiting.complete(chunk);
  }

  void _fail(Object error) {
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.completeError(error);
  }

  StreamController<Uint8List> detach() {
    final controller = StreamController<Uint8List>(
      onPause: _subscription.pause,
      onResume: _subscription.resume,
      onCancel: _subscription.cancel,
    );
    _detached = controller;
    if (_buffer.isNotEmpty) {
      controller.add(Uint8List.fromList(_buffer));
      _buffer.clear();
    }
    return controller;
  }

  Future<void> cancel() => _subscription.cancel();
}
