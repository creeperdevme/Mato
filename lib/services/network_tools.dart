import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Wake-on-LAN 魔術封包。
class WakeOnLan {
  static final _macPattern = RegExp(r'^[0-9a-fA-F]{12}$');

  static bool isValidMac(String mac) =>
      _macPattern.hasMatch(mac.replaceAll(RegExp(r'[:\-.\s]'), ''));

  /// 6 個 0xFF 加上重複 16 次的 MAC。
  static Uint8List magicPacket(String mac) {
    final hex = mac.replaceAll(RegExp(r'[:\-.\s]'), '');
    if (!_macPattern.hasMatch(hex)) {
      throw const FormatException('MAC 位址格式不正確');
    }
    final bytes = [
      for (var i = 0; i < 12; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    return Uint8List.fromList([
      for (var i = 0; i < 6; i++) 0xff,
      for (var i = 0; i < 16; i++) ...bytes,
    ]);
  }

  /// 送到指定廣播位址；未指定時送到 255.255.255.255 與各網卡的子網廣播。
  static Future<void> send(
    String mac, {
    String broadcast = '',
    int port = 9,
  }) async {
    final packet = magicPacket(mac);
    final targets = <String>{
      if (broadcast.trim().isNotEmpty) broadcast.trim() else '255.255.255.255',
    };
    if (broadcast.trim().isEmpty) {
      for (final prefix in await LanScanner.localPrefixes()) {
        targets.add('$prefix.255');
      }
    }
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      socket.broadcastEnabled = true;
      for (var round = 0; round < 3; round++) {
        for (final target in targets) {
          final address = InternetAddress.tryParse(target);
          if (address != null) socket.send(packet, address, port);
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } finally {
      socket.close();
    }
  }
}

class LanHost {
  const LanHost({required this.address, required this.port, this.banner = ''});

  final String address;
  final int port;

  /// SSH 伺服器的版本字串，例如 `SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13`。
  final String banner;

  /// 從版本字串猜作業系統。
  String get osHint {
    final lower = banner.toLowerCase();
    for (final name in [
      'ubuntu',
      'debian',
      'raspbian',
      'freebsd',
      'synology',
      'dropbear',
    ]) {
      if (lower.contains(name)) {
        return name[0].toUpperCase() + name.substring(1);
      }
    }
    return '';
  }
}

/// 掃描區網內開著 SSH 的主機（每張網卡的 /24 子網）。
class LanScanner {
  static Future<List<String>> localPrefixes() async {
    final prefixes = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.isLoopback || address.isLinkLocal) continue;
          final parts = address.address.split('.');
          if (parts.length == 4) prefixes.add(parts.take(3).join('.'));
        }
      }
    } catch (_) {
      // 某些平台（例如沙盒）不允許列出網卡。
    }
    return prefixes.toList()..sort();
  }

  /// 逐一回報找到的主機；取消訂閱即停止掃描。
  static Stream<LanHost> scan({
    int port = 22,
    List<String>? prefixes,
    void Function(int done, int total)? onProgress,
    Duration timeout = const Duration(milliseconds: 450),
    int concurrency = 64,
  }) {
    late StreamController<LanHost> controller;
    var cancelled = false;

    Future<void> run() async {
      final subnets = prefixes ?? await localPrefixes();
      final candidates = [
        for (final prefix in subnets)
          for (var i = 1; i < 255; i++) '$prefix.$i',
      ];
      var done = 0;
      onProgress?.call(0, candidates.length);
      var cursor = 0;

      Future<void> worker() async {
        while (!cancelled && cursor < candidates.length) {
          final address = candidates[cursor++];
          final host = await probe(address, port, timeout);
          done++;
          onProgress?.call(done, candidates.length);
          if (host != null && !cancelled) controller.add(host);
        }
      }

      await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<LanHost>(
      onListen: () => unawaited(run()),
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }

  static Future<LanHost?> probe(
    String address,
    int port,
    Duration timeout,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(address, port, timeout: timeout);
      final banner = await socket
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(milliseconds: 900), onTimeout: () => '');
      return LanHost(address: address, port: port, banner: banner.trim());
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }
}
