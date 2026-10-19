import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/server_metrics.dart';
import '../models/server_profile.dart';

class RemoteRunResult {
  const RemoteRunResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final String stdout;
  final String stderr;
  final int? exitCode;

  bool get success => exitCode == 0;
}

class RemoteFileEntry {
  const RemoteFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modifiedTime,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedTime;
}

class DockerContainer {
  const DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.status,
  });

  final String id;
  final String name;
  final String image;
  final String state;
  final String status;
}

/// 一條可互動的 SSH 連線（client + shell session），供終端機使用。
class SshConnection {
  SshConnection({required this.client, required this.session});

  final SSHClient client;
  final SSHSession session;

  void close() {
    session.close();
    client.close();
  }
}

class SSHService {
  Future<SSHClient> connect(ServerProfile profile) async {
    final socket = await SSHSocket.connect(
      profile.host,
      profile.port,
      timeout: const Duration(seconds: 8),
    );

    return SSHClient(
      socket,
      username: profile.username,
      onPasswordRequest: () => profile.password,
      onUserInfoRequest: (request) => request.prompts.map((prompt) {
        final text = prompt.promptText.toLowerCase();
        if (text.contains('password') ||
            text.contains('passcode') ||
            !prompt.echo) {
          return profile.password;
        }
        if (text.contains('login') || text.contains('username')) {
          return profile.username;
        }
        return '';
      }).toList(),
      keepAliveInterval: const Duration(seconds: 20),
      handshakeTimeout: const Duration(seconds: 10),
      authTimeout: const Duration(seconds: 10),
      disableHostkeyVerification: true,
    );
  }

  /// 開一條互動式 shell（給終端機分頁使用），並保留 client 以便關閉。
  Future<SshConnection> openShell(
    ServerProfile profile, {
    required int width,
    required int height,
  }) async {
    final client = await connect(profile);
    try {
      final session = await client.shell(
        pty: SSHPtyConfig(width: width, height: height),
      );
      return SshConnection(client: client, session: session);
    } catch (_) {
      client.close();
      rethrow;
    }
  }

  Future<RemoteRunResult> run(ServerProfile profile, String command) async {
    final client = await connect(profile);
    try {
      final result = await client
          .runWithResult(command)
          .timeout(const Duration(seconds: 20));
      return RemoteRunResult(
        stdout: utf8.decode(result.stdout, allowMalformed: true),
        stderr: utf8.decode(result.stderr, allowMalformed: true),
        exitCode: result.exitCode,
      );
    } finally {
      client.close();
    }
  }

  Future<bool> checkServer(ServerProfile profile) async {
    final result = await run(profile, 'uname -s');
    return result.success && result.stdout.trim().isNotEmpty;
  }

  /// 取得總覽頁需要的系統指標。
  ///
  /// 只讀取 `/proc`、`df` 等標準來源，不需要 root，也不依賴額外套件；
  /// 為避免各發行版格式差異，遠端一律輸出 `KEY=VALUE` 再由
  /// [ServerMetrics.tryParse] 解析。
  Future<ServerMetrics> fetchMetrics(ServerProfile profile) async {
    final result = await run(profile, _metricsCommand);
    if (!result.success && result.stdout.trim().isEmpty) {
      final stderr = result.stderr.trim();
      throw Exception(stderr.isEmpty ? '無法取得系統資訊' : stderr);
    }
    final metrics = ServerMetrics.tryParse(result.stdout);
    if (metrics == null) {
      throw Exception('無法解析系統資訊，可能是精簡版 Linux 或缺少 /proc');
    }
    return metrics;
  }

  Future<List<RemoteFileEntry>> listDirectory(
    ServerProfile profile,
    String path,
  ) async {
    final client = await connect(profile);
    try {
      final sftp = await client.sftp();
      final items = await sftp.listdir(path);
      final entries = <RemoteFileEntry>[];
      for (final item in items) {
        if (item.filename == '.' || item.filename == '..') continue;
        entries.add(
          RemoteFileEntry(
            name: item.filename,
            path: _joinPath(path, item.filename),
            isDirectory: item.attr.isDirectory,
            size: item.attr.size,
            modifiedTime: item.attr.modifyTime == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    item.attr.modifyTime! * 1000,
                  ),
          ),
        );
      }
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return entries;
    } finally {
      client.close();
    }
  }

  Future<Uint8List> readFile(ServerProfile profile, String path) async {
    final client = await connect(profile);
    try {
      final sftp = await client.sftp();
      final file = await sftp.open(path, mode: SftpFileOpenMode.read);
      try {
        return await file.readBytes();
      } finally {
        await file.close();
      }
    } finally {
      client.close();
    }
  }

  Future<void> writeFile(
    ServerProfile profile,
    String path,
    Uint8List data,
  ) async {
    final client = await connect(profile);
    try {
      final sftp = await client.sftp();
      final file = await sftp.open(
        path,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(data);
      } finally {
        await file.close();
      }
    } finally {
      client.close();
    }
  }

  Future<void> createDirectory(ServerProfile profile, String path) async {
    final client = await connect(profile);
    try {
      final sftp = await client.sftp();
      await sftp.mkdir(path);
    } finally {
      client.close();
    }
  }

  Future<void> delete(
    ServerProfile profile,
    String path,
    bool directory,
  ) async {
    final client = await connect(profile);
    try {
      final sftp = await client.sftp();
      if (directory) {
        await sftp.rmdir(path);
      } else {
        await sftp.remove(path);
      }
    } finally {
      client.close();
    }
  }

  Future<List<DockerContainer>> listDockerContainers(
    ServerProfile profile,
  ) async {
    const command =
        'docker ps -a --format "{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}|{{.Status}}"';
    final result = await run(profile, command);
    if (!result.success) {
      if (result.stderr.contains('not found')) {
        throw Exception('找不到 Docker CLI，請確認伺服器已安裝並允許目前使用者存取');
      }
      throw Exception(
        result.stderr.trim().isEmpty ? 'Docker 指令執行失敗' : result.stderr,
      );
    }

    return result.stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) {
          final parts = line.split('|');
          return DockerContainer(
            id: parts.isNotEmpty ? parts[0] : '',
            name: parts.length > 1 ? parts[1] : '',
            image: parts.length > 2 ? parts[2] : '',
            state: parts.length > 3 ? parts[3] : '',
            status: parts.length > 4 ? parts[4] : '',
          );
        })
        .toList();
  }

  Future<String> controlDockerContainer(
    ServerProfile profile,
    String containerId,
    String action,
  ) async {
    final result = await run(
      profile,
      'docker ${_safeAction(action)} ${_quoteArg(containerId)}',
    );
    if (!result.success) {
      throw Exception(result.stderr.trim().isEmpty ? '操作失敗' : result.stderr);
    }
    return result.stdout.trim();
  }

  /// 遠端指標蒐集腳本：輸出固定格式的 `KEY=VALUE`，方便解析。
  ///
  /// - `OS`：/etc/os-release 的 PRETTY_NAME，退回 lsb-release 或 /etc/issue
  /// - `MEM`／`SWAP`：kB 為單位（total 與 available／free）
  /// - `DISK`：1K blocks（total 與 used）
  /// - `CPU1`／`CPU2`：兩次 /proc/stat 取樣，用於換算使用率
  static const String _metricsCommand = r'''
echo "OS=$( (grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null || grep -m1 '^DISTRIB_DESCRIPTION=' /etc/lsb-release 2>/dev/null || head -n1 /etc/issue 2>/dev/null) | head -n1 | sed 's/^[A-Z_]*=//' | tr -d '"')"
echo "KERNEL=$(uname -r 2>/dev/null)"
echo "HOST=$(hostname 2>/dev/null)"
echo "UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
echo "BOOT=$(uptime -s 2>/dev/null | head -n1)"
echo "LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
echo "CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
echo "MEM=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^MemFree:/{f=$2} END{if (a=="") a=f; print t, a}' /proc/meminfo 2>/dev/null)"
echo "SWAP=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t, f}' /proc/meminfo 2>/dev/null)"
echo "DISK=$(df -Pk / 2>/dev/null | awk 'NR==2{print $2, $3}')"
echo "CPU1=$(awk '/^cpu /{print $2+$3+$4, $5+$6}' /proc/stat 2>/dev/null)"
sleep 0.4
echo "CPU2=$(awk '/^cpu /{print $2+$3+$4, $5+$6}' /proc/stat 2>/dev/null)"
''';

  String _joinPath(String parent, String name) {
    if (parent.endsWith('/')) return '$parent$name';
    return '$parent/$name';
  }

  String _safeAction(String action) {
    const allowed = {'start', 'stop', 'restart', 'pause', 'unpause'};
    if (!allowed.contains(action)) throw ArgumentError('不支援的 Docker 操作');
    return action;
  }

  String _quoteArg(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }
}
