import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/server_metrics.dart';

void main() {
  group('ServerMetrics.tryParse', () {
    const sample = '''
OS=Ubuntu 24.04.1 LTS
OSID=ubuntu
KERNEL=6.8.0-45-generic
ARCH=x86_64
HOST=web-01
UPTIME=987654
BOOT=2026-09-08 10:12:33
LOAD=0.42 0.55 0.61 2/345
CORES=2
CPUMODEL=Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz
MEM=16304812 5902340 1200000 3000000
SWAP=2097148 2097148
DISK=104857600 52428800
IP=10.0.0.5 172.17.0.1
TEMP=x86_pkg_temp|54000
TEMP=acpitz|27800
TEMP=bogus|0
FS=/|ext4|104857600|52428800|47185920
FS=/boot|ext4|1000000|200000|700000
GPU=0, GPU-abc, NVIDIA GeForce RTX 4090, 37, 8192, 24564, 61, 120.5, 450.00
GPUPROC=GPU-abc, 4242, python3, 8000
T_A=987654.10
CPU_A cpu 1000 0 500 8000 500 0 0 0 0 0
CPU_A cpu0 500 0 250 4000 250 0 0 0 0 0
CPU_A cpu1 500 0 250 4000 250 0 0 0 0 0
NET_A lo 1000 1000
NET_A eth0 100000 50000
NET_A docker0 999 999
DISKIO_A sda 100 0 2000 0 50 0 1000 0 0 100 0
T_B=987655.10
CPU_B cpu 1100 0 550 8300 550 0 0 0 0 0
CPU_B cpu0 600 0 300 4100 260 0 0 0 0 0
CPU_B cpu1 500 0 250 4200 290 0 0 0 0 0
NET_B lo 2000 2000
NET_B eth0 1148576 74000
NET_B docker0 5999 5999
DISKIO_B sda 110 0 4048 0 60 0 3048 0 0 600 0
''';

    late ServerMetrics metrics;

    setUp(() {
      final parsed = ServerMetrics.tryParse(sample);
      expect(parsed, isNotNull);
      metrics = parsed!;
    });

    test('系統資訊與負載', () {
      expect(metrics.osName, 'Ubuntu 24.04.1 LTS');
      expect(metrics.osId, 'ubuntu');
      expect(metrics.kernel, '6.8.0-45-generic');
      expect(metrics.arch, 'x86_64');
      expect(metrics.hostname, 'web-01');
      expect(metrics.cores, 2);
      expect(metrics.cpuModel, contains('Xeon'));
      expect(metrics.load1, closeTo(0.42, 0.0001));
      expect(metrics.load15, closeTo(0.61, 0.0001));
      expect(metrics.runningProcesses, 2);
      expect(metrics.totalProcesses, 345);
      expect(metrics.bootTime, '2026-09-08 10:12:33');
      expect(metrics.uptimeLabel, '11 天 10 小時');
      expect(metrics.ipAddresses, ['10.0.0.5', '172.17.0.1']);
    });

    test('CPU 整體、各核心與 I/O 等待', () {
      // (500 - 350) / 500 = 30%；iowait 50 / 500 = 10%。
      expect(metrics.cpuPercent, closeTo(30, 0.01));
      expect(metrics.iowaitPercent, closeTo(10, 0.01));
      expect(metrics.perCore.map((core) => core.name), ['cpu0', 'cpu1']);
      expect(metrics.perCore[0].percent, closeTo(150 / 260 * 100, 0.01));
      expect(metrics.perCore[1].percent, closeTo(0, 0.01));
    });

    test('記憶體、交換空間與磁碟', () {
      expect(metrics.memPercent, closeTo(63.8, 0.1));
      expect(metrics.memCacheBytes, 3000000 * 1024);
      expect(metrics.hasSwap, isTrue);
      expect(metrics.swapPercent, 0);
      expect(metrics.diskPercent, 50);
      expect(metrics.fileSystems.map((fs) => fs.mount), ['/', '/boot']);
      // 與 df 一致：used / (used + avail)。
      expect(metrics.fileSystems.first.percent, closeTo(52.63, 0.01));
    });

    test('網路速率排除虛擬介面', () {
      expect(metrics.netInterfaces.map((item) => item.name).first, 'eth0');
      expect(metrics.netRxRate, closeTo(1048576, 0.5));
      expect(metrics.netTxRate, closeTo(24000, 0.5));
      final docker = metrics.netInterfaces.firstWhere(
        (item) => item.name == 'docker0',
      );
      expect(docker.isVirtual, isTrue);
    });

    test('磁碟 I/O', () {
      final disk = metrics.disks.single;
      expect(disk.name, 'sda');
      expect(disk.readIops, closeTo(10, 0.001));
      expect(disk.readRate, closeTo(1048576, 0.5));
      expect(disk.writeRate, closeTo(1048576, 0.5));
      expect(disk.busyPercent, closeTo(50, 0.001));
      expect(metrics.diskIops, closeTo(20, 0.001));
    });

    test('溫度與 GPU', () {
      expect(metrics.cpuTemperature, closeTo(54, 0.001));
      expect(metrics.temperatures, hasLength(2));
      final gpu = metrics.gpus.single;
      expect(gpu.name, 'NVIDIA GeForce RTX 4090');
      expect(gpu.utilPercent, 37);
      expect(gpu.memPercent, closeTo(8192 / 24564 * 100, 0.01));
      expect(gpu.temperature, 61);
      expect(gpu.powerDraw, closeTo(120.5, 0.01));
      expect(gpu.processes.single.pid, 4242);
      expect(gpu.processes.single.name, 'python3');
    });

    test('真實 nvidia-smi 輸出：功耗上限為 [N/A]', () {
      final parsed = ServerMetrics.tryParse('''
DISK=1000 500
GPU=0, GPU-593fcdc4-93ad-359d-efc2-c74af842023f, NVIDIA GeForce RTX 4060 Laptop GPU, 43, 4872, 8188, 52, 5.20, [N/A]
''');
      final gpu = parsed!.gpus.single;
      expect(gpu.name, 'NVIDIA GeForce RTX 4060 Laptop GPU');
      expect(gpu.utilPercent, 43);
      expect(gpu.memTotalMiB, 8188);
      expect(gpu.temperature, 52);
      expect(gpu.powerDraw, closeTo(5.2, 0.001));
      expect(gpu.powerLimit, isNull);
      expect(gpu.processes, isEmpty);
    });

    test('缺少可辨識欄位時回傳 null', () {
      expect(ServerMetrics.tryParse('hello world'), isNull);
      expect(ServerMetrics.tryParse(''), isNull);
    });

    test('只有第一次取樣時速率為 0，且沒有 swap 時視為未啟用', () {
      final partial = ServerMetrics.tryParse('''
OS=Alpine Linux
CORES=2
MEM=2097152 1048576
SWAP=0 0
DISK=20971520 10485760
NET_A eth0 100 100
''');
      expect(partial, isNotNull);
      expect(partial!.hasSwap, isFalse);
      expect(partial.cores, 2);
      expect(partial.netRxRate, 0);
      expect(partial.cpuPercent, 0);
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
