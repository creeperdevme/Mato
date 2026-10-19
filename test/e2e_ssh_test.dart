// 對真正的 SSH 伺服器做端對端測試；沒有設定環境變數時整個檔案會略過。
//
//   MATO_E2E_HOST=127.0.0.1 MATO_E2E_PORT=2222 MATO_E2E_USER=me \
//   MATO_E2E_KEY=/path/to/private_key flutter test test/e2e_ssh_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/port_forward.dart';
import 'package:mato/models/process_info.dart';
import 'package:mato/models/server_profile.dart';
import 'package:mato/services/known_hosts_store.dart';
import 'package:mato/services/port_forward_service.dart';
import 'package:mato/services/socks_socket.dart';
import 'package:mato/services/ssh_service.dart';
import 'package:mato/services/terminal_hub.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _env = Platform.environment;
final _host = _env['MATO_E2E_HOST'];
final _skip = _host == null ? '未設定 MATO_E2E_HOST，略過端對端測試' : null;

ServerProfile _profile({String id = 'e2e', ServerProfile? jump}) =>
    ServerProfile(
      id: id,
      name: 'e2e',
      host: _host ?? '127.0.0.1',
      port: int.parse(_env['MATO_E2E_PORT'] ?? '22'),
      username: _env['MATO_E2E_USER'] ?? 'root',
      authMethod: AuthMethod.privateKey,
      privateKey: _host == null
          ? ''
          : File(_env['MATO_E2E_KEY']!).readAsStringSync(),
      createdAt: DateTime(2026),
      jump: jump,
    );

Future<String> _readBanner(Socket socket) => socket
    .cast<List<int>>()
    .transform(const Utf8Decoder(allowMalformed: true))
    .transform(const LineSplitter())
    .first
    .timeout(const Duration(seconds: 5));

Future<int> _freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

void main() {
  late SSHService ssh;
  late KnownHostsStore knownHosts;
  final profile = _profile();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    knownHosts = KnownHostsStore();
    ssh = SSHService(knownHosts: knownHosts);
  });

  tearDown(() => ssh.disconnectAll());

  test('連線池重用同一條連線，並記錄主機金鑰', () async {
    final first = await ssh.run(profile, 'echo hello');
    expect(first.stdout.trim(), 'hello');
    expect(ssh.isConnected(profile.id), isTrue);
    final second = await ssh.run(profile, 'echo again; exit 3');
    expect(second.stdout.trim(), 'again');
    expect(second.exitCode, 3);
    final known = knownHosts.lookup(profile.host, profile.port);
    expect(known?.fingerprint, startsWith('SHA256:'));
  }, skip: _skip);

  test('主機金鑰改變時拒絕連線', () async {
    await ssh.run(profile, 'true');
    ssh.disconnectAll();
    await knownHosts.trust(
      profile.host,
      profile.port,
      'ssh-ed25519',
      'SHA256:forged',
    );
    await expectLater(
      ssh.run(profile, 'true'),
      throwsA(isA<HostKeyMismatchException>()),
    );
  }, skip: _skip);

  test('監控腳本可在真實 Linux 上解析', () async {
    final metrics = await ssh.fetchMetrics(profile);
    expect(metrics.osName, isNotEmpty);
    expect(metrics.cores, greaterThan(0));
    expect(metrics.perCore, hasLength(metrics.cores));
    expect(metrics.memTotalBytes, greaterThan(0));
    expect(metrics.diskTotalBytes, greaterThan(0));
    expect(metrics.fileSystems, isNotEmpty);
    expect(metrics.netInterfaces, isNotEmpty);
    expect(metrics.totalProcesses, greaterThan(0));
    expect(metrics.cpuPercent, inInclusiveRange(0, 100));
    // ignore: avoid_print
    print(
      '${metrics.osName} · ${metrics.cores} 核 · CPU ${metrics.cpuPercent.toStringAsFixed(1)}% · '
      '磁碟 ${metrics.fileSystems.length} 個掛載點 · 網卡 ${metrics.netInterfaces.map((n) => n.name).join(',')} · '
      'GPU ${metrics.gpus.map((g) => g.name).join(',')} · 溫度 ${metrics.cpuTemperature}',
    );
  }, skip: _skip);

  test('SFTP：寫入、列出、讀取、改名、權限、串流上傳下載與遞迴刪除', () async {
    final home = await ssh.homeDirectory(profile);
    final dir = '$home/.mato-e2e-${DateTime.now().millisecondsSinceEpoch}';
    await ssh.createDirectory(profile, dir);
    await ssh.createDirectory(profile, '$dir/nested');
    await ssh.writeFile(
      profile,
      '$dir/a.txt',
      Uint8List.fromList(utf8.encode('中文 hello\n')),
    );

    final entries = await ssh.listDirectory(profile, dir);
    expect(
      entries.map((entry) => entry.name),
      containsAll(['nested', 'a.txt']),
    );
    expect(entries.first.isDirectory, isTrue);

    expect(
      utf8.decode(await ssh.readFile(profile, '$dir/a.txt')),
      '中文 hello\n',
    );
    await ssh.rename(profile, '$dir/a.txt', '$dir/b.txt');
    await ssh.chmod(profile, '$dir/b.txt', 384); // 0600
    final stat = await ssh.stat(profile, '$dir/b.txt');
    expect(stat.mode!.value & 0x1ff, 384);

    final payload = Uint8List.fromList(List.generate(300000, (i) => i % 251));
    var progress = 0;
    await ssh.upload(
      profile,
      '$dir/nested/blob.bin',
      Stream.fromIterable([
        payload.sublist(0, 100000),
        payload.sublist(100000),
      ]),
      payload.length,
      onProgress: (sent, _) => progress = sent,
    );
    expect(progress, payload.length);
    final local = File('${Directory.systemTemp.path}/mato-e2e-blob.bin');
    await ssh.downloadFile(profile, '$dir/nested/blob.bin', local.path);
    expect(await local.readAsBytes(), payload);
    await local.delete();

    await ssh.delete(profile, dir, true);
    final after = await ssh.listDirectory(profile, home);
    expect(after.map((entry) => entry.path), isNot(contains(dir)));
  }, skip: _skip);

  test('多行腳本與 stdin', () async {
    final process = await ssh.startScript(
      profile,
      'set -e\nname=mato\nfor i in 1 2 3; do echo "line \$i \$name"; done\n'
      '[[ -n "\$BASH_VERSION" ]] && echo bash\nexit 7',
    );
    final output = await process.output.join();
    expect(output, contains('line 3 mato'));
    expect(output, contains('bash'));
    expect(await process.exitCode, 7);

    final echoed = await ssh.run(profile, 'cat', stdin: 'from stdin');
    expect(echoed.stdout, 'from stdin');
  }, skip: _skip);

  test('程序列表可以解析', () async {
    final result = await ssh.run(profile, ProcessInfo.command);
    final processes = ProcessInfo.parse(result.stdout);
    expect(processes, isNotEmpty);
    expect(processes.any((process) => process.args.contains('sshd')), isTrue);
  }, skip: _skip);

  test('本機轉發與 SOCKS5 動態轉發（同時驗證 SOCKS5 用戶端）', () async {
    final forwards = PortForwardService();
    final localPort = await _freePort();
    final local = PortForwardRule(
      id: 'l',
      serverId: profile.id,
      name: 'ssh',
      kind: ForwardKind.local,
      localPort: localPort,
      remoteHost: '127.0.0.1',
      remotePort: profile.port,
    );
    await forwards.start(local, profile, ssh);
    expect(forwards.errorOf('l'), isNull);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      localPort,
    );
    expect(await _readBanner(socket), startsWith('SSH-2.0-'));
    socket.destroy();

    final socksPort = await _freePort();
    final dynamicRule = PortForwardRule(
      id: 'd',
      serverId: profile.id,
      name: 'socks',
      kind: ForwardKind.dynamic,
      localPort: socksPort,
    );
    await forwards.start(dynamicRule, profile, ssh);
    expect(forwards.errorOf('d'), isNull);
    final viaSocks = await SocksSSHSocket.connect(
      proxyHost: '127.0.0.1',
      proxyPort: socksPort,
      targetHost: '127.0.0.1',
      targetPort: profile.port,
    );
    final banner = await viaSocks.stream
        .map((chunk) => utf8.decode(chunk, allowMalformed: true))
        .first
        .timeout(const Duration(seconds: 5));
    expect(banner, startsWith('SSH-2.0-'));
    viaSocks.destroy();

    await forwards.stop('l');
    await forwards.stop('d');
  }, skip: _skip);

  test('經由跳板機與 SOCKS5 代理連線', () async {
    final viaJump = _profile(
      id: 'e2e-via-jump',
      jump: _profile(id: 'e2e-jump'),
    );
    final result = await ssh.run(viaJump, 'echo via-jump');
    expect(result.stdout.trim(), 'via-jump');

    final forwards = PortForwardService();
    final socksPort = await _freePort();
    await forwards.start(
      PortForwardRule(
        id: 's',
        serverId: profile.id,
        name: 'socks',
        kind: ForwardKind.dynamic,
        localPort: socksPort,
      ),
      profile,
      ssh,
    );
    final viaProxy = _profile(id: 'e2e-via-proxy').copyWith(
      proxy: ProxyConfig(host: '127.0.0.1', port: socksPort),
    );
    final proxied = await ssh.run(viaProxy, 'echo via-proxy');
    expect(proxied.stdout.trim(), 'via-proxy');
    await forwards.stop('s');
  }, skip: _skip);

  test('備援位址：主要位址連不上時改用下一個', () async {
    final failover = _profile(id: 'e2e-failover').copyWith(
      host: '127.0.0.1',
      port: await _freePort(),
      alternateHosts: ['${_host ?? '127.0.0.1'}:${profile.port}'],
    );
    final result = await ssh.run(failover, 'echo failover');
    expect(result.stdout.trim(), 'failover');
  }, skip: _skip);

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('等待逾時');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  test('終端機分頁：shell 與 tmux 工作階段', () async {
    final hub = TerminalHub(ssh);
    final shell = hub.open(
      profile.copyWith(startupCommand: 'export MATO_E2E=1'),
    );
    await waitFor(() => shell.connected);
    shell.sendText('echo "marker-\$MATO_E2E"\r');
    await waitFor(() => shell.terminal.buffer.getText().contains('marker-1'));

    final tmux = hub.open(
      profile.copyWith(sessionName: 'mato-e2e'),
      mode: SessionMode.tmux,
    );
    await waitFor(() => tmux.connected);
    final check = await ssh.run(profile, 'sleep 1; tmux ls 2>&1');
    expect(check.stdout, contains('mato-e2e'));
    await ssh.run(profile, 'tmux kill-session -t mato-e2e');
    await waitFor(() => tmux.state == TerminalSessionState.closed);
    hub.closeAll(profile.id);
  }, skip: _skip);
}
