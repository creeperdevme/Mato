import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/server_metrics.dart';
import '../models/server_profile.dart';
import '../utils/shell.dart';
import 'known_hosts_store.dart';
import 'socks_socket.dart';

class RemoteRunResult {
  const RemoteRunResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    this.truncated = false,
  });

  final String stdout;
  final String stderr;
  final int? exitCode;

  /// 輸出超過上限而被截斷。
  final bool truncated;

  bool get success => exitCode == 0;

  /// stdout 為主，沒有時退回 stderr，方便直接顯示。
  String get text => stdout.trim().isEmpty ? stderr : stdout;
}

class RemoteFileEntry {
  const RemoteFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modifiedTime,
    this.isSymlink = false,
    this.mode,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
  final DateTime? modifiedTime;
  final bool isSymlink;

  /// 權限位元（例如 0o755）。
  final int? mode;

  bool get isHidden => name.startsWith('.');
  String get permissions => mode == null ? '' : permissionString(mode!);
}

/// 主機金鑰與上次記錄不同時要使用者確認的內容。
class HostKeyChallenge {
  const HostKeyChallenge({
    required this.host,
    required this.port,
    required this.type,
    required this.fingerprint,
    required this.previous,
  });

  final String host;
  final int port;
  final String type;
  final String fingerprint;
  final KnownHost previous;
}

/// keyboard-interactive 驗證（例如 2FA 驗證碼）需要使用者輸入的內容。
class InteractiveChallenge {
  const InteractiveChallenge({
    required this.serverName,
    required this.title,
    required this.instruction,
    required this.prompts,
  });

  final String serverName;
  final String title;
  final String instruction;
  final List<SSHUserInfoPrompt> prompts;
}

typedef HostKeyPrompt = Future<bool> Function(HostKeyChallenge challenge);
typedef InteractivePrompt = Future<List<String>?> Function(
  InteractiveChallenge challenge,
);
typedef ConnectProgress = void Function(String stage);

class SshException implements Exception {
  const SshException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 主機金鑰與已知主機的紀錄不符，連線已中止。
class HostKeyMismatchException extends SshException {
  const HostKeyMismatchException(this.host, this.port)
    : super(
        '主機金鑰與上次記錄不同，已中止連線：可能是伺服器重灌，也可能遭到中間人攻擊。'
        '確認無誤後，請到「設定 › 安全 › 已知主機」移除舊紀錄再重新連線。',
      );

  final String host;
  final int port;
}

/// 長時間占用的連線（終端機、連接埠轉發），用完要 [release]。
class SshLease {
  SshLease._(this._service, this._entry);

  final SSHService _service;
  final _PoolEntry _entry;
  bool _released = false;

  SSHClient get client => _entry.client!;

  /// 底層連線中斷時完成（不會丟出錯誤）。
  Future<void> get done => SSHService._whenClosed(_entry.client!);

  void release() {
    if (_released) return;
    _released = true;
    _service._release(_entry);
  }
}

/// 背景執行中的遠端指令，可即時讀取輸出或中止。
class RemoteProcess {
  RemoteProcess._(this._session, this._lease) {
    final decoder = const Utf8Decoder(allowMalformed: true);
    var open = 2;
    void finish() {
      open--;
      if (open == 0) _output.close();
    }

    _session.stdout
        .cast<List<int>>()
        .transform(decoder)
        .listen(_output.add, onError: _output.addError, onDone: finish);
    _session.stderr
        .cast<List<int>>()
        .transform(decoder)
        .listen(_output.add, onError: _output.addError, onDone: finish);
    _exit = _session.done
        .then<int?>((_) => _session.exitCode, onError: (_) => null)
        .whenComplete(_lease.release);
  }

  final SSHSession _session;
  final SshLease _lease;
  final StreamController<String> _output = StreamController<String>();
  late final Future<int?> _exit;

  /// stdout 與 stderr 合併後的文字輸出。
  Stream<String> get output => _output.stream;
  Future<int?> get exitCode => _exit;

  void write(String text) =>
      _session.stdin.add(Uint8List.fromList(utf8.encode(text)));

  void kill() => _session.close();
}

class _PoolEntry {
  _PoolEntry(this.signature);

  final String signature;
  SSHClient? client;
  Future<void>? connecting;
  Future<SftpClient>? sftp;
  int leases = 0;
  DateTime lastUsed = DateTime.now();
  final List<void Function()> onClose = [];

  bool get alive => client != null && !client!.isClosed;

  void close() {
    final current = client;
    client = null;
    sftp = null;
    current?.close();
    for (final callback in onClose) {
      callback();
    }
    onClose.clear();
  }
}

/// SSH 連線與遠端操作。
///
/// 同一台伺服器共用一條長連線（連線池），監控輪詢、SFTP、Docker 等操作都在
/// 上面開新 channel，不必每次重新交握；閒置超過 [idleTimeout] 才關閉。
class SSHService {
  SSHService({KnownHostsStore? knownHosts})
    : knownHosts = knownHosts ?? KnownHostsStore();

  final KnownHostsStore knownHosts;

  /// 主機金鑰改變時詢問使用者；由 UI 層設定。
  HostKeyPrompt? hostKeyPrompt;

  /// 需要使用者輸入驗證碼或密碼時詢問；由 UI 層設定。
  InteractivePrompt? interactivePrompt;

  static const Duration idleTimeout = Duration(minutes: 3);
  static const Duration connectTimeout = Duration(seconds: 10);

  final Map<String, _PoolEntry> _pool = {};
  Timer? _reaper;

  bool isConnected(String serverId) => _pool[serverId]?.alive ?? false;

  /// 關閉某台伺服器的共用連線（例如設定變更後）。
  void disconnect(String serverId) {
    _pool.remove(serverId)?.close();
  }

  void disconnectAll() {
    for (final entry in _pool.values) {
      entry.close();
    }
    _pool.clear();
  }

  Future<T> withClient<T>(
    ServerProfile profile,
    Future<T> Function(SSHClient client) action, {
    bool interactive = false,
  }) async {
    final entry = await _acquire(profile, interactive: interactive);
    try {
      return await action(entry.client!);
    } finally {
      _release(entry);
    }
  }

  Future<SshLease> lease(
    ServerProfile profile, {
    bool interactive = true,
    ConnectProgress? onProgress,
  }) async {
    final entry = await _acquire(
      profile,
      interactive: interactive,
      onProgress: onProgress,
    );
    return SshLease._(this, entry);
  }

  Future<_PoolEntry> _acquire(
    ServerProfile profile, {
    required bool interactive,
    ConnectProgress? onProgress,
  }) async {
    _reaper ??= Timer.periodic(const Duration(seconds: 30), (_) => _reap());
    final signature = profile.connectionSignature;
    var entry = _pool[profile.id];
    if (entry != null &&
        (entry.signature != signature ||
            (entry.connecting == null && !entry.alive))) {
      // 設定改了或連線已斷：舊連線上的 lease 仍可用到自然結束，這裡只換新的。
      if (entry.leases == 0) entry.close();
      _pool.remove(profile.id);
      entry = null;
    }
    entry ??= _pool[profile.id] = _PoolEntry(signature);
    entry.leases++;
    entry.lastUsed = DateTime.now();

    try {
      if (!entry.alive) {
        final pending = entry.connecting ??= _connectEntry(
          entry,
          profile,
          interactive: interactive,
          onProgress: onProgress,
        );
        await pending;
      } else {
        onProgress?.call('已連線');
      }
      return entry;
    } catch (_) {
      entry.leases--;
      if (identical(_pool[profile.id], entry)) _pool.remove(profile.id);
      rethrow;
    }
  }

  Future<void> _connectEntry(
    _PoolEntry entry,
    ServerProfile profile, {
    required bool interactive,
    ConnectProgress? onProgress,
  }) async {
    try {
      final opened = await _open(
        profile,
        interactive: interactive,
        onProgress: onProgress,
      );
      entry.client = opened.client;
      if (opened.onClose != null) entry.onClose.add(opened.onClose!);
      unawaited(
        _whenClosed(opened.client).then((_) {
          if (identical(entry.client, opened.client)) entry.close();
        }),
      );
    } finally {
      entry.connecting = null;
    }
  }

  void _release(_PoolEntry entry) {
    entry.leases = (entry.leases - 1).clamp(0, 1 << 30);
    entry.lastUsed = DateTime.now();
    if (entry.leases == 0 && !_pool.containsValue(entry)) {
      // 已被替換的舊連線，最後一個使用者離開後就關掉。
      entry.close();
    }
  }

  void _reap() {
    final now = DateTime.now();
    final idle = _pool.entries
        .where(
          (item) =>
              item.value.leases == 0 &&
              item.value.connecting == null &&
              now.difference(item.value.lastUsed) > idleTimeout,
        )
        .map((item) => item.key)
        .toList();
    for (final id in idle) {
      _pool.remove(id)?.close();
    }
  }

  /// 建立一條新的、獨立的 SSH 連線（不進連線池）。
  Future<SSHClient> connect(
    ServerProfile profile, {
    bool interactive = false,
    ConnectProgress? onProgress,
  }) async {
    final opened = await _open(
      profile,
      interactive: interactive,
      onProgress: onProgress,
    );
    if (opened.onClose != null) {
      unawaited(_whenClosed(opened.client).then((_) => opened.onClose!()));
    }
    return opened.client;
  }

  /// 連線結束（不論正常或異常）時完成，不會丟出錯誤。
  static Future<void> _whenClosed(SSHClient client) =>
      client.done.then((_) {}, onError: (_) {});

  Future<({SSHClient client, void Function()? onClose})> _open(
    ServerProfile profile, {
    required bool interactive,
    ConnectProgress? onProgress,
  }) async {
    final targets = [
      (host: profile.host, port: profile.port),
      for (final alternate in profile.alternateHosts)
        if (alternate.trim().isNotEmpty) parseHostPort(alternate, profile.port),
    ];

    SshLease? jumpLease;
    final jump = profile.jump;
    if (jump != null) {
      onProgress?.call('連線到跳板機 ${jump.name}…');
      jumpLease = await lease(jump, interactive: interactive);
    }

    Object? lastError;
    for (final target in targets) {
      SSHSocket socket;
      try {
        if (jumpLease != null) {
          onProgress?.call('經由跳板機連到 ${target.host}:${target.port}…');
          socket = await jumpLease.client
              .forwardLocal(target.host, target.port)
              .timeout(connectTimeout);
        } else if (profile.proxy != null) {
          final proxy = profile.proxy!;
          onProgress?.call('經由 SOCKS5 代理 ${proxy.host}:${proxy.port}…');
          socket = await SocksSSHSocket.connect(
            proxyHost: proxy.host,
            proxyPort: proxy.port,
            targetHost: target.host,
            targetPort: target.port,
            username: proxy.username,
            password: profile.proxyPassword,
            timeout: connectTimeout,
          );
        } else {
          onProgress?.call('連線到 ${target.host}:${target.port}…');
          socket = await SSHSocket.connect(
            target.host,
            target.port,
            timeout: connectTimeout,
          );
        }
      } catch (error) {
        lastError = error;
        continue;
      }

      try {
        final client = await _handshake(
          socket,
          profile,
          host: target.host,
          port: target.port,
          interactive: interactive,
          onProgress: onProgress,
        );
        onProgress?.call('已連線');
        return (client: client, onClose: jumpLease?.release);
      } catch (error) {
        jumpLease?.release();
        rethrow;
      }
    }
    jumpLease?.release();
    throw lastError ?? const SshException('無法連線');
  }

  Future<SSHClient> _handshake(
    SSHSocket socket,
    ServerProfile profile, {
    required String host,
    required int port,
    required bool interactive,
    ConnectProgress? onProgress,
  }) async {
    List<SSHKeyPair>? identities;
    if (profile.authMethod == AuthMethod.privateKey &&
        profile.privateKey.trim().isNotEmpty) {
      try {
        identities = SSHKeyPair.fromPem(
          profile.privateKey,
          profile.passphrase.isEmpty ? null : profile.passphrase,
        );
      } catch (error) {
        socket.destroy();
        throw SshException('私鑰無法解析：$error');
      }
    }

    onProgress?.call('SSH 交握中…');
    var passwordUsed = false;
    var hostKeyRejected = false;
    final client = SSHClient(
      socket,
      username: profile.username,
      identities: identities,
      onVerifyHostKey: (type, fingerprint) async {
        final accepted = await _verifyHostKey(
          host,
          port,
          type,
          utf8.decode(fingerprint, allowMalformed: true),
          interactive: interactive,
        );
        hostKeyRejected = !accepted;
        return accepted;
      },
      onPasswordRequest: () async {
        if (profile.password.isNotEmpty && !passwordUsed) {
          passwordUsed = true;
          return profile.password;
        }
        if (!interactive || interactivePrompt == null) return null;
        final answers = await interactivePrompt!(
          InteractiveChallenge(
            serverName: profile.name,
            title: passwordUsed ? '密碼錯誤，請重新輸入' : '請輸入密碼',
            instruction: profile.address,
            prompts: [SSHUserInfoPrompt('密碼', false)],
          ),
        );
        return answers?.firstOrNull;
      },
      onUserInfoRequest: (request) async {
        if (request.prompts.isEmpty) return const <String>[];
        final answers = List<String?>.filled(request.prompts.length, null);
        for (var i = 0; i < request.prompts.length; i++) {
          final text = request.prompts[i].promptText.toLowerCase();
          final isPassword =
              text.contains('password') ||
              text.contains('passphrase') ||
              text.contains('密碼');
          if (isPassword && profile.password.isNotEmpty && !passwordUsed) {
            answers[i] = profile.password;
            passwordUsed = true;
          }
        }
        if (answers.every((answer) => answer != null)) {
          return answers.cast<String>();
        }
        if (!interactive || interactivePrompt == null) return null;
        onProgress?.call('等待輸入驗證碼…');
        final pending = [
          for (var i = 0; i < request.prompts.length; i++)
            if (answers[i] == null) request.prompts[i],
        ];
        final replies = await interactivePrompt!(
          InteractiveChallenge(
            serverName: profile.name,
            title: request.name.isEmpty ? '需要額外驗證' : request.name,
            instruction: request.instruction,
            prompts: pending,
          ),
        );
        if (replies == null || replies.length != pending.length) return null;
        var cursor = 0;
        return [for (final answer in answers) answer ?? replies[cursor++]];
      },
      agentHandler: profile.agentForwarding && identities != null
          ? SSHKeyPairAgent(identities)
          : null,
      keepAliveInterval: const Duration(seconds: 15),
      handshakeTimeout: const Duration(seconds: 15),
      // 2FA 需要等使用者輸入，給比較長的時間。
      authTimeout: interactive
          ? const Duration(minutes: 3)
          : const Duration(seconds: 20),
    );

    try {
      await client.authenticated;
      return client;
    } catch (_) {
      client.close();
      // 金鑰被拒時 dartssh2 只回報「驗證前連線關閉」，這裡改成明確的原因。
      if (hostKeyRejected) throw HostKeyMismatchException(host, port);
      rethrow;
    }
  }

  Future<bool> _verifyHostKey(
    String host,
    int port,
    String type,
    String fingerprint, {
    required bool interactive,
  }) async {
    await knownHosts.load();
    final known = knownHosts.lookup(host, port);
    if (known == null) {
      await knownHosts.trust(host, port, type, fingerprint);
      return true;
    }
    if (known.fingerprint == fingerprint) return true;
    final prompt = hostKeyPrompt;
    if (!interactive || prompt == null) return false;
    final accepted = await prompt(
      HostKeyChallenge(
        host: host,
        port: port,
        type: type,
        fingerprint: fingerprint,
        previous: known,
      ),
    );
    if (accepted) await knownHosts.trust(host, port, type, fingerprint);
    return accepted;
  }

  // ---------------------------------------------------------------------------
  // 指令執行

  Future<RemoteRunResult> run(
    ServerProfile profile,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? stdin,
    bool interactive = false,
    int maxOutputBytes = 8 * 1024 * 1024,
  }) {
    return withClient(
      profile,
      (client) => _exec(
        client,
        command,
        timeout: timeout,
        stdin: stdin,
        maxOutputBytes: maxOutputBytes,
      ),
      interactive: interactive,
    );
  }

  /// 以 sudo 執行；root 帳號直接執行。密碼經由 stdin 傳給 `sudo -S`，不會
  /// 出現在遠端的程序列表中。
  Future<RemoteRunResult> runPrivileged(
    ServerProfile profile,
    String command, {
    Duration timeout = const Duration(seconds: 60),
    bool interactive = false,
  }) {
    if (profile.isRoot) {
      return run(profile, posixShell(command), timeout: timeout);
    }
    return run(
      profile,
      sudoCommand(command),
      timeout: timeout,
      stdin: '${profile.password}\n',
      interactive: interactive,
    );
  }

  static String sudoCommand(String command) =>
      "sudo -S -p '' ${posixShell(command)}";

  /// 執行多行腳本（優先使用 bash），回傳合併輸出。
  Future<RemoteProcess> startScript(
    ServerProfile profile,
    String script, {
    bool sudo = false,
  }) {
    final inner =
        'if command -v bash >/dev/null 2>&1; then exec bash -c "\$0"; '
        'else exec sh -c "\$0"; fi';
    final command = '${posixShell(inner)} ${shellQuote(script)}';
    if (!sudo || profile.isRoot) return start(profile, command);
    return start(
      profile,
      "sudo -S -p '' $command",
      stdin: '${profile.password}\n',
    );
  }

  /// 啟動長時間指令並即時讀取輸出（例如 `docker pull`、`tail -f`）。
  Future<RemoteProcess> start(
    ServerProfile profile,
    String command, {
    String? stdin,
    bool pty = false,
  }) async {
    final lease = await this.lease(profile, interactive: false);
    try {
      final session = await lease.client.execute(
        command,
        pty: pty ? const SSHPtyConfig(width: 200, height: 50) : null,
      );
      if (stdin != null) {
        session.stdin.add(Uint8List.fromList(utf8.encode(stdin)));
      }
      if (!pty) unawaited(session.stdin.close());
      return RemoteProcess._(session, lease);
    } catch (_) {
      lease.release();
      rethrow;
    }
  }

  Future<RemoteRunResult> _exec(
    SSHClient client,
    String command, {
    required Duration timeout,
    String? stdin,
    required int maxOutputBytes,
  }) async {
    final session = await client.execute(command);
    final stdout = BytesBuilder(copy: false);
    final stderr = BytesBuilder(copy: false);
    var truncated = false;

    void collect(BytesBuilder target, Uint8List data) {
      if (stdout.length + stderr.length >= maxOutputBytes) {
        truncated = true;
        return;
      }
      target.add(data);
    }

    final outDone = session.stdout.listen((data) => collect(stdout, data));
    final errDone = session.stderr.listen((data) => collect(stderr, data));
    if (stdin != null) {
      session.stdin.add(Uint8List.fromList(utf8.encode(stdin)));
    }
    unawaited(session.stdin.close());

    try {
      await Future.wait([outDone.asFuture<void>(), errDone.asFuture<void>()])
          .timeout(timeout);
      await session.done.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      session.close();
      await outDone.cancel();
      await errDone.cancel();
      throw SshException('指令執行逾時（${timeout.inSeconds} 秒）');
    }

    return RemoteRunResult(
      stdout: utf8.decode(stdout.takeBytes(), allowMalformed: true),
      stderr: utf8.decode(stderr.takeBytes(), allowMalformed: true),
      exitCode: session.exitCode,
      truncated: truncated,
    );
  }

  Future<bool> checkServer(ServerProfile profile) async {
    final result = await run(profile, 'uname -s');
    return result.success && result.stdout.trim().isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // 監控

  /// 取得總覽頁需要的系統指標。
  ///
  /// 只讀取 `/proc`、`/sys`、`df` 等標準來源，不需要 root，也不依賴額外套件；
  /// 為避免各發行版格式差異，遠端一律輸出 `KEY=VALUE` 再由
  /// [ServerMetrics.tryParse] 解析。
  Future<ServerMetrics> fetchMetrics(
    ServerProfile profile, {
    bool interactive = false,
  }) async {
    final result = await run(
      profile,
      posixShell(metricsScript),
      timeout: const Duration(seconds: 20),
      interactive: interactive,
    );
    if (!result.success && result.stdout.trim().isEmpty) {
      final stderr = result.stderr.trim();
      throw SshException(stderr.isEmpty ? '無法取得系統資訊' : stderr);
    }
    final metrics = ServerMetrics.tryParse(result.stdout);
    if (metrics == null) {
      throw const SshException('無法解析系統資訊，可能是精簡版 Linux 或缺少 /proc');
    }
    return metrics;
  }

  /// 遠端指標蒐集腳本：輸出固定格式，方便解析。
  ///
  /// - `MEM`：kB（total、available、free、cache）；`SWAP`：kB（total、free）
  /// - `DISK`：根目錄 1K blocks（total、used）；`FS`：所有實體掛載點
  /// - `CPU_*`／`NET_*`／`DISKIO_*`：間隔一秒的兩次取樣，用來換算速率
  /// - `GPU`／`GPUPROC`：`nvidia-smi`；`AMDGPU`：amdgpu sysfs
  static const String metricsScript = r'''
export LC_ALL=C
echo "OS=$( (grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null || grep -m1 '^DISTRIB_DESCRIPTION=' /etc/lsb-release 2>/dev/null || head -n1 /etc/issue 2>/dev/null) | head -n1 | sed 's/^[A-Z_]*=//' | tr -d '"')"
echo "OSID=$(grep -m1 '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
echo "KERNEL=$(uname -r 2>/dev/null)"
echo "ARCH=$(uname -m 2>/dev/null)"
echo "HOST=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null)"
echo "UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
echo "BOOT=$(uptime -s 2>/dev/null | head -n1)"
echo "LOAD=$(cut -d' ' -f1-4 /proc/loadavg 2>/dev/null)"
echo "CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
echo "CPUMODEL=$(grep -m1 -E '^(model name|Hardware|cpu model|Model)' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
echo "MEM=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2} /^SReclaimable:/{s=$2} END{if (a=="") a=f+b+c; print t, a, f, b+c+s}' /proc/meminfo 2>/dev/null)"
echo "SWAP=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{print t, f}' /proc/meminfo 2>/dev/null)"
echo "DISK=$(df -Pk / 2>/dev/null | awk 'NR==2{print $2, $3}')"
echo "IP=$( (hostname -I 2>/dev/null || ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1) | tr '\n' ' ')"
for z in /sys/class/thermal/thermal_zone*; do [ -r "$z/temp" ] && echo "TEMP=$(cat "$z/type" 2>/dev/null)|$(cat "$z/temp" 2>/dev/null)"; done
for h in /sys/class/hwmon/hwmon*; do n=$(cat "$h/name" 2>/dev/null); case "$n" in coretemp|k10temp|zenpower|cpu_thermal|cpu-thermal|soc_thermal) for t in "$h"/temp*_input; do [ -r "$t" ] && echo "TEMP=$n|$(cat "$t")"; done;; esac; done
df -PkT 2>/dev/null | awk 'NR>1 && $2 !~ /^(tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|devpts|cgroup2?|efivarfs|ramfs|autofs|nsfs|tracefs|debugfs|securityfs|pstore|bpf|configfs|mqueue|hugetlbfs|fuse\..*|fusectl|binfmt_misc|rpc_pipefs|nfsd|none)$/ {print "FS="$7"|"$2"|"$3"|"$4"|"$5}'
NV=$(command -v nvidia-smi 2>/dev/null)
for p in /usr/lib/wsl/lib/nvidia-smi /usr/local/nvidia/bin/nvidia-smi; do [ -z "$NV" ] && [ -x "$p" ] && NV="$p"; done
if [ -n "$NV" ]; then
  "$NV" --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>/dev/null | sed 's/^/GPU=/'
  "$NV" --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null | sed 's/^/GPUPROC=/'
fi
for c in /sys/class/drm/card[0-9]; do [ -r "$c/device/gpu_busy_percent" ] && echo "AMDGPU=${c##*/}|$(cat "$c/device/gpu_busy_percent")|$(cat "$c/device/mem_info_vram_used" 2>/dev/null)|$(cat "$c/device/mem_info_vram_total" 2>/dev/null)|$(cat "$c/device/product_name" 2>/dev/null)"; done
sample() {
  echo "T_$1=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
  grep '^cpu' /proc/stat 2>/dev/null | sed "s/^/CPU_$1 /"
  awk -v p="NET_$1" 'NR>2{gsub(":", " "); print p, $1, $2, $10}' /proc/net/dev 2>/dev/null
  for d in /sys/block/*; do n=${d##*/}; case "$n" in loop*|ram*|zram*|sr*|fd*|dm-*|md*|*boot*|*rpmb) continue;; esac; [ -r "$d/stat" ] && echo "DISKIO_$1 $n $(cat "$d/stat")"; done
}
sample A
sleep 1
sample B
''';

  // ---------------------------------------------------------------------------
  // SFTP

  Future<T> withSftp<T>(
    ServerProfile profile,
    Future<T> Function(SftpClient sftp) action,
  ) async {
    final entry = await _acquire(profile, interactive: false);
    try {
      for (var attempt = 0; ; attempt++) {
        final opening = entry.sftp ??= entry.client!.sftp();
        try {
          final sftp = await opening;
          return await action(sftp);
        } on SftpAbortError {
          // SFTP channel 被關掉了，重開一次再試。
          entry.sftp = null;
          if (attempt > 0) rethrow;
        } on SSHChannelOpenError {
          entry.sftp = null;
          throw const SshException('伺服器未開放 SFTP 子系統');
        } catch (_) {
          if (identical(entry.sftp, opening) && !await _sftpUsable(opening)) {
            entry.sftp = null;
          }
          rethrow;
        }
      }
    } finally {
      _release(entry);
    }
  }

  Future<bool> _sftpUsable(Future<SftpClient> opening) async {
    try {
      await opening;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> homeDirectory(ServerProfile profile) =>
      withSftp(profile, (sftp) => sftp.absolute('.'));

  Future<List<RemoteFileEntry>> listDirectory(
    ServerProfile profile,
    String path,
  ) {
    return withSftp(profile, (sftp) async {
      final items = await sftp.listdir(path);
      final entries = <RemoteFileEntry>[];
      for (final item in items) {
        if (item.filename == '.' || item.filename == '..') continue;
        final itemPath = joinRemotePath(path, item.filename);
        var attr = item.attr;
        final isLink = attr.isSymbolicLink;
        if (isLink) {
          // 符號連結要看目標才知道是不是資料夾。
          try {
            attr = await sftp.stat(itemPath);
          } catch (_) {}
        }
        entries.add(
          RemoteFileEntry(
            name: item.filename,
            path: itemPath,
            isDirectory: attr.isDirectory,
            isSymlink: isLink,
            size: attr.size,
            mode: attr.mode == null ? null : attr.mode!.value & 0x1ff,
            modifiedTime: attr.modifyTime == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(attr.modifyTime! * 1000),
          ),
        );
      }
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return entries;
    });
  }

  Future<SftpFileAttrs> stat(ServerProfile profile, String path) =>
      withSftp(profile, (sftp) => sftp.stat(path));

  Future<Uint8List> readFile(
    ServerProfile profile,
    String path, {
    int? length,
    int offset = 0,
  }) {
    return withSftp(profile, (sftp) async {
      final file = await sftp.open(path, mode: SftpFileOpenMode.read);
      try {
        return await file.readBytes(length: length, offset: offset);
      } finally {
        await file.close();
      }
    });
  }

  Future<void> writeFile(ServerProfile profile, String path, Uint8List data) {
    return withSftp(profile, (sftp) async {
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
    });
  }

  /// 串流上傳，不必把整個檔案讀進記憶體。
  Future<void> upload(
    ServerProfile profile,
    String remotePath,
    Stream<List<int>> source,
    int total, {
    void Function(int sent, int total)? onProgress,
  }) {
    return withSftp(profile, (sftp) async {
      final file = await sftp.open(
        remotePath,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        await file
            .write(
              source.map(
                (chunk) =>
                    chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
              ),
              onProgress: (sent) => onProgress?.call(sent, total),
            )
            .done;
      } finally {
        await file.close();
      }
    });
  }

  /// 串流下載到本機路徑。
  Future<void> downloadFile(
    ServerProfile profile,
    String remotePath,
    String localPath, {
    void Function(int received, int total)? onProgress,
  }) {
    return withSftp(profile, (sftp) async {
      final total = (await sftp.stat(remotePath)).size ?? 0;
      final sink = File(localPath).openWrite();
      try {
        await sftp.download(
          remotePath,
          sink,
          onProgress: (received) => onProgress?.call(received, total),
        );
        await sink.flush();
      } finally {
        await sink.close();
      }
    });
  }

  Future<void> createDirectory(ServerProfile profile, String path) =>
      withSftp(profile, (sftp) => sftp.mkdir(path));

  Future<void> rename(ServerProfile profile, String from, String to) =>
      withSftp(profile, (sftp) => sftp.rename(from, to));

  Future<void> chmod(ServerProfile profile, String path, int mode) {
    return withSftp(
      profile,
      (sftp) => sftp.setStat(
        path,
        SftpFileAttrs(mode: SftpFileMode.value(mode & 0xfff)),
      ),
    );
  }

  /// 刪除檔案或整個資料夾（含內容）。
  Future<void> delete(
    ServerProfile profile,
    String path,
    bool directory,
  ) async {
    if (!directory) {
      await withSftp(profile, (sftp) => sftp.remove(path));
      return;
    }
    if (path.trim().isEmpty || path == '/') {
      throw const SshException('拒絕刪除根目錄');
    }
    try {
      final result = await run(profile, 'rm -rf -- ${shellQuote(path)}');
      if (result.success) return;
      throw SshException(result.text.trim().isEmpty ? '刪除失敗' : result.text);
    } on SSHChannelOpenError {
      // 只開放 SFTP 的帳號無法執行指令，改用 SFTP 逐一刪除。
      await withSftp(profile, (sftp) => _removeTree(sftp, path));
    }
  }

  Future<void> _removeTree(SftpClient sftp, String path) async {
    for (final item in await sftp.listdir(path)) {
      if (item.filename == '.' || item.filename == '..') continue;
      final child = joinRemotePath(path, item.filename);
      if (item.attr.isDirectory) {
        await _removeTree(sftp, child);
      } else {
        await sftp.remove(child);
      }
    }
    await sftp.rmdir(path);
  }
}
