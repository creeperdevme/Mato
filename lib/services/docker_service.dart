import '../models/server_profile.dart';
import '../utils/shell.dart';
import 'ssh_service.dart';

class DockerContainer {
  const DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.status,
    this.ports = '',
    this.createdAt = '',
  });

  final String id;
  final String name;
  final String image;
  final String state;
  final String status;
  final String ports;
  final String createdAt;

  bool get running => state == 'running';
  bool get paused => state == 'paused';
}

class ContainerStats {
  const ContainerStats({
    required this.cpu,
    required this.memUsage,
    required this.memPercent,
    required this.netIO,
    required this.blockIO,
  });

  final String cpu;
  final String memUsage;
  final String memPercent;
  final String netIO;
  final String blockIO;
}

class DockerImage {
  const DockerImage({
    required this.id,
    required this.repository,
    required this.tag,
    required this.size,
    required this.created,
  });

  final String id;
  final String repository;
  final String tag;
  final String size;
  final String created;

  String get reference => repository == '<none>'
      ? id
      : '$repository:${tag == '<none>' ? 'latest' : tag}';
}

class DockerVolume {
  const DockerVolume({required this.name, required this.driver});

  final String name;
  final String driver;
}

class DockerNetwork {
  const DockerNetwork({
    required this.id,
    required this.name,
    required this.driver,
    required this.scope,
  });

  final String id;
  final String name;
  final String driver;
  final String scope;

  bool get builtIn => const {'bridge', 'host', 'none', 'podman'}.contains(name);
}

/// 偵測到的容器執行環境。
class DockerRuntime {
  const DockerRuntime({
    required this.binary,
    required this.version,
    this.sudo = false,
  });

  /// `docker` 或 `podman`。
  final String binary;
  final String version;

  /// 目前帳號沒有 docker.sock 權限，需要透過 sudo。
  final bool sudo;

  String get label =>
      '${binary == 'podman' ? 'Podman' : 'Docker'} $version${sudo ? '（sudo）' : ''}';
}

class DockerException implements Exception {
  const DockerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 透過 SSH 執行 docker／podman CLI。
class DockerService {
  DockerService(this._ssh);

  final SSHService _ssh;
  static const _sep = '|~|';

  Future<DockerRuntime> detect(ServerProfile profile) async {
    final docker = await _ssh.run(
      profile,
      "docker version --format '{{.Server.Version}}' 2>&1",
    );
    final output = docker.stdout.trim();
    if (docker.success && output.isNotEmpty) {
      return DockerRuntime(binary: 'docker', version: output);
    }
    final lower = output.toLowerCase();
    if (lower.contains('permission denied') && !profile.isRoot) {
      if (profile.password.isEmpty) {
        throw const DockerException(
          '目前帳號沒有 Docker 權限。請把帳號加入 docker 群組，'
          '或在伺服器設定中儲存密碼以便使用 sudo。',
        );
      }
      final viaSudo = await _ssh.run(
        profile,
        "sudo -S -p '' docker version --format '{{.Server.Version}}' 2>&1",
        stdin: '${profile.password}\n',
      );
      if (viaSudo.success && viaSudo.stdout.trim().isNotEmpty) {
        return DockerRuntime(
          binary: 'docker',
          version: viaSudo.stdout.trim(),
          sudo: true,
        );
      }
      throw DockerException('sudo 執行 Docker 失敗：${viaSudo.stdout.trim()}');
    }
    if (lower.contains('cannot connect to the docker daemon') ||
        lower.contains('is the docker daemon running')) {
      throw const DockerException('Docker 服務未啟動（找不到 docker daemon）');
    }

    final podman = await _ssh.run(
      profile,
      "podman version --format '{{.Client.Version}}' 2>&1",
    );
    if (podman.success && podman.stdout.trim().isNotEmpty) {
      return DockerRuntime(binary: 'podman', version: podman.stdout.trim());
    }
    throw const DockerException('找不到 Docker 或 Podman，請確認伺服器已安裝並允許目前使用者存取');
  }

  /// 組出完整指令；需要 sudo 時回傳要寫進 stdin 的密碼。
  ({String command, String? stdin}) command(
    ServerProfile profile,
    DockerRuntime runtime,
    String args,
  ) {
    final base = '${runtime.binary} $args';
    if (!runtime.sudo) return (command: base, stdin: null);
    return (command: "sudo -S -p '' $base", stdin: '${profile.password}\n');
  }

  Future<RemoteRunResult> run(
    ServerProfile profile,
    DockerRuntime runtime,
    String args, {
    Duration timeout = const Duration(seconds: 60),
  }) {
    final built = command(profile, runtime, args);
    return _ssh.run(
      profile,
      built.command,
      stdin: built.stdin,
      timeout: timeout,
    );
  }

  Future<String> _checked(
    ServerProfile profile,
    DockerRuntime runtime,
    String args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final result = await run(profile, runtime, args, timeout: timeout);
    if (!result.success) {
      final message = result.stderr.trim().isEmpty
          ? result.stdout.trim()
          : result.stderr.trim();
      throw DockerException(message.isEmpty ? '指令執行失敗' : message);
    }
    return result.stdout;
  }

  List<List<String>> _rows(String output, int columns) => output
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .map((line) {
        final parts = line.split(_sep);
        while (parts.length < columns) {
          parts.add('');
        }
        return parts;
      })
      .toList();

  Future<List<DockerContainer>> containers(
    ServerProfile profile,
    DockerRuntime runtime,
  ) async {
    final output = await _checked(
      profile,
      runtime,
      "ps -a --format '{{.ID}}$_sep{{.Names}}$_sep{{.Image}}$_sep{{.State}}"
      "$_sep{{.Status}}$_sep{{.Ports}}$_sep{{.CreatedAt}}'",
    );
    final list = _rows(output, 7)
        .map(
          (row) => DockerContainer(
            id: row[0],
            name: row[1],
            image: row[2],
            state: row[3].toLowerCase(),
            status: row[4],
            ports: row[5],
            createdAt: row[6],
          ),
        )
        .toList();
    list.sort((a, b) {
      if (a.running != b.running) return a.running ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return list;
  }

  /// 以容器 ID 前 12 碼為 key。
  Future<Map<String, ContainerStats>> stats(
    ServerProfile profile,
    DockerRuntime runtime,
  ) async {
    final output = await _checked(
      profile,
      runtime,
      "stats --no-stream --format '{{.ID}}$_sep{{.CPUPerc}}$_sep{{.MemUsage}}"
      "$_sep{{.MemPerc}}$_sep{{.NetIO}}$_sep{{.BlockIO}}'",
    );
    return {
      for (final row in _rows(output, 6))
        _shortId(row[0]): ContainerStats(
          cpu: row[1],
          memUsage: row[2],
          memPercent: row[3],
          netIO: row[4],
          blockIO: row[5],
        ),
    };
  }

  static String _shortId(String id) =>
      id.length > 12 ? id.substring(0, 12) : id;

  ContainerStats? statsFor(Map<String, ContainerStats> stats, String id) =>
      stats[_shortId(id)];

  static const containerActions = {
    'start',
    'stop',
    'restart',
    'pause',
    'unpause',
    'kill',
  };

  Future<void> containerAction(
    ServerProfile profile,
    DockerRuntime runtime,
    String id,
    String action,
  ) async {
    if (!containerActions.contains(action)) {
      throw ArgumentError('不支援的容器操作：$action');
    }
    await _checked(profile, runtime, '$action ${shellQuote(id)}');
  }

  Future<void> removeContainer(
    ServerProfile profile,
    DockerRuntime runtime,
    String id, {
    bool volumes = false,
  }) => _checked(
    profile,
    runtime,
    'rm -f ${volumes ? '-v ' : ''}${shellQuote(id)}',
  );

  Future<String> logs(
    ServerProfile profile,
    DockerRuntime runtime,
    String id, {
    int tail = 300,
    bool timestamps = false,
  }) async {
    final result = await run(
      profile,
      runtime,
      'logs --tail $tail ${timestamps ? '--timestamps ' : ''}${shellQuote(id)} 2>&1',
    );
    return result.stdout.isEmpty ? result.stderr : result.stdout;
  }

  Future<RemoteProcess> followLogs(
    ServerProfile profile,
    DockerRuntime runtime,
    String id, {
    int tail = 100,
  }) {
    final built = command(
      profile,
      runtime,
      'logs -f --tail $tail ${shellQuote(id)} 2>&1',
    );
    return _ssh.start(profile, built.command, stdin: built.stdin);
  }

  Future<String> inspect(
    ServerProfile profile,
    DockerRuntime runtime,
    String target,
  ) => _checked(profile, runtime, 'inspect ${shellQuote(target)}');

  Future<List<DockerImage>> images(
    ServerProfile profile,
    DockerRuntime runtime,
  ) async {
    final output = await _checked(
      profile,
      runtime,
      "images --format '{{.ID}}$_sep{{.Repository}}$_sep{{.Tag}}$_sep{{.Size}}"
      "$_sep{{.CreatedSince}}'",
    );
    return _rows(output, 5)
        .map(
          (row) => DockerImage(
            id: row[0],
            repository: row[1],
            tag: row[2],
            size: row[3],
            created: row[4],
          ),
        )
        .toList();
  }

  Future<void> removeImage(
    ServerProfile profile,
    DockerRuntime runtime,
    String id, {
    bool force = false,
  }) =>
      _checked(profile, runtime, 'rmi ${force ? '-f ' : ''}${shellQuote(id)}');

  Future<RemoteProcess> pull(
    ServerProfile profile,
    DockerRuntime runtime,
    String image,
  ) {
    final built = command(profile, runtime, 'pull ${shellQuote(image)} 2>&1');
    return _ssh.start(profile, built.command, stdin: built.stdin);
  }

  Future<List<DockerVolume>> volumes(
    ServerProfile profile,
    DockerRuntime runtime,
  ) async {
    final output = await _checked(
      profile,
      runtime,
      "volume ls --format '{{.Name}}$_sep{{.Driver}}'",
    );
    return _rows(
      output,
      2,
    ).map((row) => DockerVolume(name: row[0], driver: row[1])).toList();
  }

  Future<List<DockerNetwork>> networks(
    ServerProfile profile,
    DockerRuntime runtime,
  ) async {
    final output = await _checked(
      profile,
      runtime,
      "network ls --format '{{.ID}}$_sep{{.Name}}$_sep{{.Driver}}$_sep{{.Scope}}'",
    );
    return _rows(output, 4)
        .map(
          (row) => DockerNetwork(
            id: row[0],
            name: row[1],
            driver: row[2],
            scope: row[3],
          ),
        )
        .toList();
  }

  Future<void> removeVolume(
    ServerProfile profile,
    DockerRuntime runtime,
    String name,
  ) => _checked(profile, runtime, 'volume rm ${shellQuote(name)}');

  Future<void> removeNetwork(
    ServerProfile profile,
    DockerRuntime runtime,
    String id,
  ) => _checked(profile, runtime, 'network rm ${shellQuote(id)}');

  Future<String> systemDf(ServerProfile profile, DockerRuntime runtime) =>
      _checked(profile, runtime, 'system df');

  Future<String> prune(
    ServerProfile profile,
    DockerRuntime runtime, {
    bool all = false,
    bool volumes = false,
  }) => _checked(
    profile,
    runtime,
    'system prune -f${all ? ' -a' : ''}${volumes ? ' --volumes' : ''}',
    timeout: const Duration(minutes: 10),
  );

  /// 建立並啟動容器（`docker run -d`）。
  static String runArgs({
    required String image,
    String name = '',
    List<String> ports = const [],
    List<String> env = const [],
    List<String> volumes = const [],
    String restart = 'no',
    String network = '',
    String extra = '',
    String command = '',
  }) {
    final args = StringBuffer('run -d');
    if (name.trim().isNotEmpty) {
      args.write(' --name ${shellQuote(name.trim())}');
    }
    for (final port in ports.where((item) => item.trim().isNotEmpty)) {
      args.write(' -p ${shellQuote(port.trim())}');
    }
    for (final item in env.where((item) => item.trim().isNotEmpty)) {
      args.write(' -e ${shellQuote(item.trim())}');
    }
    for (final volume in volumes.where((item) => item.trim().isNotEmpty)) {
      args.write(' -v ${shellQuote(volume.trim())}');
    }
    if (restart != 'no') args.write(' --restart ${shellQuote(restart)}');
    if (network.trim().isNotEmpty) {
      args.write(' --network ${shellQuote(network.trim())}');
    }
    // 進階參數由使用者自行負責引號，原樣附加。
    if (extra.trim().isNotEmpty) args.write(' ${extra.trim()}');
    args.write(' ${shellQuote(image.trim())}');
    if (command.trim().isNotEmpty) args.write(' ${command.trim()}');
    return args.toString();
  }

  /// 進入容器的互動式 shell。
  static String execShellCommand(DockerRuntime runtime, String id) {
    final base =
        '${runtime.binary} exec -it ${shellQuote(id)} '
        'sh -c "command -v bash >/dev/null 2>&1 && exec bash || exec sh"';
    return runtime.sudo ? 'sudo $base' : base;
  }
}
