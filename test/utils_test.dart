import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/process_info.dart';
import 'package:mato/models/server_profile.dart';
import 'package:mato/services/docker_service.dart';
import 'package:mato/services/network_tools.dart';
import 'package:mato/utils/format.dart';
import 'package:mato/utils/shell.dart';

void main() {
  group('shell', () {
    test('shellQuote 可安全包住單引號', () {
      expect(shellQuote("it's"), "'it'\\''s'");
      expect(shellQuote('a b'), "'a b'");
    });

    test('路徑工具', () {
      expect(parentRemotePath('/'), isNull);
      expect(parentRemotePath('/home'), '/');
      expect(parentRemotePath('/home/deploy/'), '/home');
      expect(remoteBaseName('/var/log/syslog'), 'syslog');
      expect(joinRemotePath('/', 'etc'), '/etc');
      expect(joinRemotePath('/home', 'a'), '/home/a');
      expect(remotePathSegments('/home/deploy'), [
        '/',
        '/home',
        '/home/deploy',
      ]);
      expect(remotePathSegments('/'), ['/']);
    });

    test('權限字串', () {
      expect(permissionString(493), 'rwxr-xr-x'); // 0755
      expect(permissionString(420), 'rw-r--r--'); // 0644
      expect(permissionString(0), '---------');
    });
  });

  group('format', () {
    test('速率、時間與百分比', () {
      expect(formatRate(1048576), '1.0 MB/s');
      expect(formatDuration(const Duration(days: 2, hours: 3)), '2 天 3 小時');
      expect(formatDuration(const Duration(seconds: 42)), '42 秒');
      expect(formatPercent(3.456), '3.5%');
      expect(formatPercent(42.4), '42%');
      final now = DateTime(2026, 10, 19, 12);
      expect(
        formatRelative(now.subtract(const Duration(minutes: 5)), now: now),
        '5 分鐘前',
      );
    });
  });

  group('parseHostPort', () {
    test('解析 host、host:port 與 IPv6', () {
      expect(parseHostPort('example.com', 22), (host: 'example.com', port: 22));
      expect(parseHostPort('example.com:2200', 22), (
        host: 'example.com',
        port: 2200,
      ));
      expect(parseHostPort('[::1]:2222', 22), (host: '::1', port: 2222));
      expect(parseHostPort('fe80::1', 22), (host: 'fe80::1', port: 22));
    });
  });

  group('WakeOnLan', () {
    test('魔術封包為 6 個 0xFF 加上 16 次 MAC', () {
      final packet = WakeOnLan.magicPacket('AA:BB:CC:DD:EE:FF');
      expect(packet.length, 102);
      expect(packet.take(6), everyElement(0xff));
      expect(packet.sublist(6, 12), [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]);
      expect(packet.sublist(96, 102), [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]);
    });

    test('MAC 格式檢查', () {
      expect(WakeOnLan.isValidMac('aa-bb-cc-dd-ee-ff'), isTrue);
      expect(WakeOnLan.isValidMac('aabb.ccdd.eeff'), isTrue);
      expect(WakeOnLan.isValidMac('aa:bb:cc'), isFalse);
      expect(() => WakeOnLan.magicPacket('zz'), throwsFormatException);
    });
  });

  group('ProcessInfo', () {
    const output = '''
    1     0 root          0.0  0.1 11880 12-03:04:05 Ss   /sbin/init splash
  842     1 www-data     12.5  3.2 524288  01:02:03 Sl   /usr/sbin/nginx -g daemon off;
    2     0 root          0.0  0.0     0  05:10 S    [kthreadd]
  999     1 app           1.0  0.5  2048  00:01 Z    [node] <defunct>
 1500     1 deploy        0.0  0.1  8000  00:10 Ss   sshd: deploy@pts/0
''';

    test('解析 ps 輸出', () {
      final processes = ProcessInfo.parse(output);
      expect(processes, hasLength(5));
      expect(processes[0].pid, 1);
      expect(
        processes[0].elapsed,
        const Duration(days: 12, hours: 3, minutes: 4, seconds: 5),
      );
      expect(processes[1].name, 'nginx');
      expect(processes[1].user, 'www-data');
      expect(processes[1].cpu, 12.5);
      expect(processes[1].rssKb, 524288);
      expect(processes[1].args, '/usr/sbin/nginx -g daemon off;');
      expect(processes[2].isKernelThread, isTrue);
      expect(processes[2].elapsed, const Duration(minutes: 5, seconds: 10));
      expect(processes[3].isZombie, isTrue);
      // 程序標題被改成 `sshd: user@pts/0` 時，名稱不含冒號。
      expect(processes[4].name, 'sshd');
    });
  });

  group('DockerService.runArgs', () {
    test('組出 docker run 參數並加上引號', () {
      final args = DockerService.runArgs(
        image: 'nginx:latest',
        name: 'web',
        ports: ['8080:80', ''],
        env: ["GREETING=it's ok"],
        volumes: ['/srv/www:/usr/share/nginx/html'],
        restart: 'unless-stopped',
      );
      expect(
        args,
        "run -d --name 'web' -p '8080:80' -e 'GREETING=it'\\''s ok' "
        "-v '/srv/www:/usr/share/nginx/html' --restart 'unless-stopped' 'nginx:latest'",
      );
    });
  });
}
