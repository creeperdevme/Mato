import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/server_metrics.dart';

void main() {
  group('ServerMetrics.tryParse', () {
    const sample = '''
OS=Ubuntu 24.04.1 LTS
KERNEL=6.8.0-45-generic
HOST=web-01
UPTIME=987654
BOOT=2026-09-08 10:12:33
LOAD=0.42 0.55 0.61
CORES=8
MEM=16304812 5902340
SWAP=2097148 2097148
DISK=104857600 52428800
CPU1=123456 987654
CPU2=123700 987900
''';

    test('解析各項指標', () {
      final metrics = ServerMetrics.tryParse(sample);
      expect(metrics, isNotNull);
      final value = metrics!;

      expect(value.osName, 'Ubuntu 24.04.1 LTS');
      expect(value.kernel, '6.8.0-45-generic');
      expect(value.hostname, 'web-01');
      expect(value.cores, 8);
      expect(value.load1, closeTo(0.42, 0.0001));
      expect(value.load5, closeTo(0.55, 0.0001));
      expect(value.load15, closeTo(0.61, 0.0001));
      expect(value.bootTime, '2026-09-08 10:12:33');

      // (490 - 246) / 490 ≈ 49.8%
      expect(value.cpuPercent, closeTo(49.8, 0.2));

      // 10402472 kB 已用 / 16304812 kB 總量 ≈ 63.8%
      expect(value.memPercent, closeTo(63.8, 0.2));
      expect(value.diskPercent, 50);
      expect(value.hasSwap, isTrue);
      expect(value.uptimeLabel, '11 天 10 小時');
    });

    test('缺少可辨識欄位時回傳 null', () {
      expect(ServerMetrics.tryParse('hello world'), isNull);
      expect(ServerMetrics.tryParse(''), isNull);
    });

    test('沒有 swap 時視為未啟用', () {
      final metrics = ServerMetrics.tryParse('''
OS=Alpine Linux
CORES=2
MEM=2097152 1048576
SWAP=0 0
DISK=20971520 10485760
CPU1=100 200
CPU2=110 210
''');
      expect(metrics, isNotNull);
      expect(metrics!.hasSwap, isFalse);
      expect(metrics.cores, 2);
    });
  });

  group('ServerMetrics.formatBytes', () {
    test('換算單位', () {
      expect(ServerMetrics.formatBytes(0), '0 B');
      expect(ServerMetrics.formatBytes(512), '512 B');
      expect(ServerMetrics.formatBytes(16696127488), '15.5 GB');
      expect(ServerMetrics.formatBytes(1099511627776), '1.0 TB');
    });
  });
}
