import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

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
      keepAliveInterval: const Duration(seconds: 20),
      handshakeTimeout: const Duration(seconds: 10),
      authTimeout: const Duration(seconds: 10),
      disableHostkeyVerification: true,
    );
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
