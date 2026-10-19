import 'dart:math' as math;

import '../utils/format.dart' as fmt;

/// 單一 CPU 核心在取樣區間內的使用率。
class CpuCoreUsage {
  const CpuCoreUsage({required this.name, required this.percent});

  final String name;
  final double percent;
}

/// `df` 回報的一個掛載點。
class FileSystemUsage {
  const FileSystemUsage({
    required this.mount,
    required this.fsType,
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
  });

  final String mount;
  final String fsType;
  final int totalBytes;
  final int usedBytes;
  final int availableBytes;

  double get percent {
    // 與 df 的 Use% 一致：used / (used + avail)，保留給 root 的空間不算。
    final denominator = usedBytes + availableBytes;
    if (denominator <= 0) return 0;
    return (usedBytes / denominator * 100).clamp(0, 100);
  }
}

/// 一張網路介面的累計流量與目前速率。
class NetInterfaceStat {
  const NetInterfaceStat({
    required this.name,
    required this.rxBytes,
    required this.txBytes,
    required this.rxRate,
    required this.txRate,
  });

  final String name;
  final int rxBytes;
  final int txBytes;

  /// bytes/s。
  final double rxRate;
  final double txRate;

  /// 迴路、容器橋接等虛擬介面不列入總流量，避免重複計算。
  bool get isVirtual {
    const prefixes = [
      'lo',
      'veth',
      'docker',
      'br-',
      'virbr',
      'cni',
      'flannel',
      'cali',
      'vxlan',
      'kube-',
      'tunl',
      'podman',
      'lxc',
    ];
    return prefixes.any(name.startsWith);
  }
}

/// 一顆實體磁碟在取樣區間的 I/O。
class DiskIoStat {
  const DiskIoStat({
    required this.name,
    required this.readRate,
    required this.writeRate,
    required this.readIops,
    required this.writeIops,
    required this.busyPercent,
    required this.totalReadBytes,
    required this.totalWriteBytes,
  });

  final String name;

  /// bytes/s。
  final double readRate;
  final double writeRate;
  final double readIops;
  final double writeIops;

  /// 磁碟忙碌時間比例（`io_ticks`），接近 100% 代表已飽和。
  final double busyPercent;
  final int totalReadBytes;
  final int totalWriteBytes;
}

class GpuProcess {
  const GpuProcess({
    required this.pid,
    required this.name,
    required this.usedMemoryMiB,
  });

  final int pid;
  final String name;
  final double usedMemoryMiB;
}

class GpuInfo {
  const GpuInfo({
    required this.index,
    required this.name,
    required this.utilPercent,
    required this.memUsedMiB,
    required this.memTotalMiB,
    this.temperature,
    this.powerDraw,
    this.powerLimit,
    this.processes = const [],
  });

  final String index;
  final String name;
  final double utilPercent;
  final double memUsedMiB;
  final double memTotalMiB;
  final double? temperature;
  final double? powerDraw;
  final double? powerLimit;
  final List<GpuProcess> processes;

  double get memPercent =>
      memTotalMiB <= 0 ? 0 : (memUsedMiB / memTotalMiB * 100).clamp(0, 100);
}

class TemperatureReading {
  const TemperatureReading({required this.label, required this.celsius});

  final String label;
  final double celsius;
}

/// 從遠端主機 `/proc`、`/sys`、`df` 等來源蒐集到的系統指標。
///
/// 由 [SSHService.fetchMetrics] 取得，畫面端只負責呈現。遠端輸出是純文字
/// `KEY=VALUE` 與帶 `_A`／`_B` 後綴的兩次取樣；缺少關鍵欄位時 [tryParse]
/// 會回傳 `null`，讓 UI 退回顯示原始輸出。
class ServerMetrics {
  const ServerMetrics({
    required this.osName,
    this.osId = '',
    required this.kernel,
    this.arch = '',
    required this.hostname,
    required this.uptime,
    required this.bootTime,
    required this.load1,
    required this.load5,
    required this.load15,
    this.runningProcesses,
    this.totalProcesses,
    required this.cores,
    this.cpuModel = '',
    required this.cpuPercent,
    this.iowaitPercent = 0,
    this.perCore = const [],
    required this.memTotalBytes,
    required this.memAvailableBytes,
    this.memFreeBytes = 0,
    this.memCacheBytes = 0,
    required this.swapTotalBytes,
    required this.swapFreeBytes,
    required this.diskTotalBytes,
    required this.diskUsedBytes,
    this.fileSystems = const [],
    this.netInterfaces = const [],
    this.disks = const [],
    this.gpus = const [],
    this.temperatures = const [],
    this.ipAddresses = const [],
    required this.raw,
  });

  /// 作業系統的 PRETTY_NAME，例如 `Ubuntu 24.04.1 LTS`。
  final String osName;

  /// `/etc/os-release` 的 ID，例如 `ubuntu`、`debian`。
  final String osId;
  final String kernel;
  final String arch;
  final String hostname;
  final Duration? uptime;

  /// `uptime -s` 的原始字串，例如 `2026-10-19 08:12:33`。
  final String? bootTime;

  /// 1／5／15 分鐘平均負載。
  final double load1;
  final double load5;
  final double load15;
  final int? runningProcesses;
  final int? totalProcesses;

  /// CPU 核心數，用來把負載換算成合理比例。
  final int cores;
  final String cpuModel;

  /// 取樣區間內的 CPU 使用率（0–100）。
  final double cpuPercent;

  /// 取樣區間內等待 I/O 的時間比例（0–100）。
  final double iowaitPercent;
  final List<CpuCoreUsage> perCore;

  final int memTotalBytes;
  final int memAvailableBytes;
  final int memFreeBytes;

  /// buffers + cached + SReclaimable。
  final int memCacheBytes;
  final int swapTotalBytes;
  final int swapFreeBytes;

  /// 根目錄 `/` 的容量。
  final int diskTotalBytes;
  final int diskUsedBytes;
  final List<FileSystemUsage> fileSystems;
  final List<NetInterfaceStat> netInterfaces;
  final List<DiskIoStat> disks;
  final List<GpuInfo> gpus;
  final List<TemperatureReading> temperatures;
  final List<String> ipAddresses;

  /// 遠端回傳的原始輸出，供「原始輸出」區塊備援顯示。
  final String raw;

  int get memUsedBytes => math.max(0, memTotalBytes - memAvailableBytes);
  int get swapUsedBytes => math.max(0, swapTotalBytes - swapFreeBytes);
  int get diskFreeBytes => math.max(0, diskTotalBytes - diskUsedBytes);

  double get memPercent => _percent(memUsedBytes, memTotalBytes);
  double get diskPercent => _percent(diskUsedBytes, diskTotalBytes);
  double get swapPercent => _percent(swapUsedBytes, swapTotalBytes);

  /// 1 分鐘負載除以核心數；1.0 代表剛好滿載。
  double get loadPerCore => cores <= 0 ? load1 : load1 / cores;

  bool get hasSwap => swapTotalBytes > 0;

  Iterable<NetInterfaceStat> get physicalInterfaces =>
      netInterfaces.where((item) => !item.isVirtual);

  double get netRxRate =>
      physicalInterfaces.fold(0, (sum, item) => sum + item.rxRate);
  double get netTxRate =>
      physicalInterfaces.fold(0, (sum, item) => sum + item.txRate);
  int get netRxTotal =>
      physicalInterfaces.fold(0, (sum, item) => sum + item.rxBytes);
  int get netTxTotal =>
      physicalInterfaces.fold(0, (sum, item) => sum + item.txBytes);

  double get diskReadRate => disks.fold(0, (sum, item) => sum + item.readRate);
  double get diskWriteRate =>
      disks.fold(0, (sum, item) => sum + item.writeRate);
  double get diskIops =>
      disks.fold(0, (sum, item) => sum + item.readIops + item.writeIops);

  /// 最能代表 CPU 的溫度：優先挑 CPU／封裝感測器，否則取最高值。
  double? get cpuTemperature {
    if (temperatures.isEmpty) return null;
    const preferred = [
      'x86_pkg_temp',
      'coretemp',
      'k10temp',
      'zenpower',
      'cpu',
      'soc',
      'package',
    ];
    final cpuReadings = temperatures.where((reading) {
      final label = reading.label.toLowerCase();
      return preferred.any(label.contains);
    }).toList();
    final source = cpuReadings.isEmpty ? temperatures : cpuReadings;
    return source.map((reading) => reading.celsius).reduce(math.max);
  }

  /// 解析遠端指令輸出；缺少關鍵欄位時回傳 `null`。
  static ServerMetrics? tryParse(String raw) {
    final values = <String, String>{};
    final multi = <String, List<String>>{};
    final samples = <String, List<String>>{};

    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final sampleMatch = _samplePattern.firstMatch(trimmed);
      if (sampleMatch != null) {
        samples
            .putIfAbsent(sampleMatch.group(1)!, () => [])
            .add(sampleMatch.group(2)!.trim());
        continue;
      }
      final separator = trimmed.indexOf('=');
      if (separator <= 0) continue;
      final key = trimmed.substring(0, separator).trim();
      if (!_keyPattern.hasMatch(key)) continue;
      final value = trimmed.substring(separator + 1).trim();
      if (_multiKeys.contains(key)) {
        multi.putIfAbsent(key, () => []).add(value);
      } else {
        values[key] = value;
      }
    }

    final mem = _numbers(values['MEM']);
    final disk = _numbers(values['DISK']);
    final swap = _numbers(values['SWAP']);
    final load = (values['LOAD'] ?? '').split(RegExp(r'\s+'));
    final cores = int.tryParse(values['CORES'] ?? '') ?? 0;
    final uptimeSeconds = int.tryParse(values['UPTIME'] ?? '');

    final interval = _interval(values['T_A'], values['T_B']);
    final cpu = _parseCpu(samples['CPU_A'], samples['CPU_B']);
    final diskTotalKb = _at(disk, 0) ?? 0;
    final diskUsedKb = _at(disk, 1) ?? 0;
    if (diskTotalKb <= 0 && cpu == null) return null;

    final procs = load.length > 3 ? load[3].split('/') : const <String>[];

    return ServerMetrics(
      osName: (values['OS'] ?? '').replaceAll('"', '').trim(),
      osId: (values['OSID'] ?? '').replaceAll('"', '').trim(),
      kernel: (values['KERNEL'] ?? '').trim(),
      arch: (values['ARCH'] ?? '').trim(),
      hostname: (values['HOST'] ?? '').trim(),
      uptime: uptimeSeconds == null
          ? null
          : Duration(seconds: math.max(0, uptimeSeconds)),
      bootTime: (values['BOOT'] ?? '').trim().isEmpty
          ? null
          : values['BOOT']!.trim(),
      load1: double.tryParse(load.isNotEmpty ? load[0] : '') ?? 0,
      load5: double.tryParse(load.length > 1 ? load[1] : '') ?? 0,
      load15: double.tryParse(load.length > 2 ? load[2] : '') ?? 0,
      runningProcesses: procs.length == 2 ? int.tryParse(procs[0]) : null,
      totalProcesses: procs.length == 2 ? int.tryParse(procs[1]) : null,
      cores: cores > 0 ? cores : math.max(1, cpu?.cores.length ?? 1),
      cpuModel: (values['CPUMODEL'] ?? '').trim(),
      cpuPercent: cpu?.total ?? 0,
      iowaitPercent: cpu?.iowait ?? 0,
      perCore: cpu?.cores ?? const [],
      memTotalBytes: ((_at(mem, 0) ?? 0) * 1024).round(),
      memAvailableBytes: ((_at(mem, 1) ?? 0) * 1024).round(),
      memFreeBytes: ((_at(mem, 2) ?? 0) * 1024).round(),
      memCacheBytes: ((_at(mem, 3) ?? 0) * 1024).round(),
      swapTotalBytes: ((_at(swap, 0) ?? 0) * 1024).round(),
      swapFreeBytes: ((_at(swap, 1) ?? 0) * 1024).round(),
      diskTotalBytes: (diskTotalKb * 1024).round(),
      diskUsedBytes: (diskUsedKb * 1024).round(),
      fileSystems: _parseFileSystems(multi['FS']),
      netInterfaces: _parseNet(samples['NET_A'], samples['NET_B'], interval),
      disks: _parseDiskIo(samples['DISKIO_A'], samples['DISKIO_B'], interval),
      gpus: _parseGpus(multi['GPU'], multi['GPUPROC'], multi['AMDGPU']),
      temperatures: _parseTemperatures(multi['TEMP']),
      ipAddresses: (values['IP'] ?? '')
          .split(RegExp(r'\s+'))
          .where((item) => item.isNotEmpty)
          .toList(growable: false),
      raw: raw,
    );
  }

  /// 例：`12 天 4 小時`、`3 小時 8 分`。
  String? get uptimeLabel {
    final value = uptime;
    if (value == null) return null;
    final days = value.inDays;
    final hours = value.inHours % 24;
    final minutes = value.inMinutes % 60;
    if (days > 0) return '$days 天 $hours 小時';
    if (hours > 0) return '$hours 小時 $minutes 分';
    return '$minutes 分';
  }

  /// 例：`15.6 GB`。
  static String formatBytes(int bytes) => fmt.formatBytes(bytes);

  static final _samplePattern = RegExp(r'^((?:CPU|NET|DISKIO)_[AB])\s+(.*)$');
  static final _keyPattern = RegExp(r'^[A-Z][A-Z0-9_]*$');
  static const _multiKeys = {'FS', 'GPU', 'GPUPROC', 'AMDGPU', 'TEMP'};

  static double _percent(int used, int total) {
    if (total <= 0) return 0;
    return (used / total * 100).clamp(0, 100);
  }

  static double? _at(List<double> values, int index) {
    if (index >= values.length) return null;
    return values[index];
  }

  static List<double> _numbers(String? source) {
    if (source == null || source.isEmpty) return const <double>[];
    return source
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .map(double.tryParse)
        .whereType<double>()
        .toList(growable: false);
  }

  /// 兩次取樣的間隔（秒），來源是 `/proc/uptime`；缺值時假設 1 秒。
  static double _interval(String? first, String? second) {
    final a = double.tryParse(first ?? '');
    final b = double.tryParse(second ?? '');
    if (a == null || b == null || b <= a) return 1;
    return b - a;
  }

  /// 兩次 `/proc/stat` 取樣換算整體與各核心使用率。
  static ({double total, double iowait, List<CpuCoreUsage> cores})? _parseCpu(
    List<String>? first,
    List<String>? second,
  ) {
    if (first == null || second == null) return null;
    final before = <String, List<double>>{};
    for (final line in first) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 5) continue;
      before[parts.first] = parts
          .skip(1)
          .map(double.tryParse)
          .nonNulls
          .toList();
    }

    double? total;
    var iowait = 0.0;
    final cores = <CpuCoreUsage>[];
    for (final line in second) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 5) continue;
      final name = parts.first;
      final now = parts.skip(1).map(double.tryParse).nonNulls.toList();
      final previous = before[name];
      if (previous == null || previous.length < 4 || now.length < 4) continue;

      double sum(List<double> fields) =>
          fields.take(8).fold(0.0, (acc, value) => acc + value);
      double idle(List<double> fields) =>
          fields[3] + (fields.length > 4 ? fields[4] : 0);

      final totalDelta = sum(now) - sum(previous);
      final idleDelta = idle(now) - idle(previous);
      if (totalDelta <= 0) continue;
      final usage = ((totalDelta - idleDelta) / totalDelta * 100).clamp(
        0.0,
        100.0,
      );

      if (name == 'cpu') {
        total = usage;
        if (now.length > 4 && previous.length > 4) {
          iowait = ((now[4] - previous[4]) / totalDelta * 100).clamp(
            0.0,
            100.0,
          );
        }
      } else {
        cores.add(CpuCoreUsage(name: name, percent: usage));
      }
    }
    if (total == null && cores.isEmpty) return null;
    total ??=
        cores.fold<double>(0, (sum, core) => sum + core.percent) / cores.length;
    cores.sort((a, b) => _coreIndex(a.name).compareTo(_coreIndex(b.name)));
    return (total: total, iowait: iowait, cores: cores);
  }

  static int _coreIndex(String name) =>
      int.tryParse(name.replaceFirst('cpu', '')) ?? 0;

  static List<FileSystemUsage> _parseFileSystems(List<String>? lines) {
    if (lines == null) return const [];
    final seen = <String>{};
    final result = <FileSystemUsage>[];
    for (final line in lines) {
      final parts = line.split('|');
      if (parts.length < 5) continue;
      final mount = parts[0];
      if (!seen.add(mount)) continue;
      final total = int.tryParse(parts[2]) ?? 0;
      if (total <= 0) continue;
      result.add(
        FileSystemUsage(
          mount: mount,
          fsType: parts[1],
          totalBytes: total * 1024,
          usedBytes: (int.tryParse(parts[3]) ?? 0) * 1024,
          availableBytes: (int.tryParse(parts[4]) ?? 0) * 1024,
        ),
      );
    }
    result.sort((a, b) {
      if (a.mount == '/') return -1;
      if (b.mount == '/') return 1;
      return a.mount.compareTo(b.mount);
    });
    return result;
  }

  static List<NetInterfaceStat> _parseNet(
    List<String>? first,
    List<String>? second,
    double interval,
  ) {
    Map<String, (int, int)> parse(List<String>? lines) {
      final map = <String, (int, int)>{};
      for (final line in lines ?? const <String>[]) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length < 3) continue;
        map[parts[0]] = (
          int.tryParse(parts[1]) ?? 0,
          int.tryParse(parts[2]) ?? 0,
        );
      }
      return map;
    }

    final before = parse(first);
    final after = parse(second);
    final source = after.isEmpty ? before : after;
    final result = <NetInterfaceStat>[];
    source.forEach((name, value) {
      final previous = before[name];
      double rate(int now, int? old) {
        if (old == null || now < old || after.isEmpty) return 0;
        return (now - old) / interval;
      }

      result.add(
        NetInterfaceStat(
          name: name,
          rxBytes: value.$1,
          txBytes: value.$2,
          rxRate: rate(value.$1, previous?.$1),
          txRate: rate(value.$2, previous?.$2),
        ),
      );
    });
    result.sort((a, b) {
      if (a.isVirtual != b.isVirtual) return a.isVirtual ? 1 : -1;
      return a.name.compareTo(b.name);
    });
    return result;
  }

  /// `/sys/block/<dev>/stat`：讀取次數、合併、讀取磁區、讀取耗時、寫入次數、
  /// 合併、寫入磁區、寫入耗時、進行中、io_ticks……（磁區固定 512 bytes）。
  static List<DiskIoStat> _parseDiskIo(
    List<String>? first,
    List<String>? second,
    double interval,
  ) {
    Map<String, List<int>> parse(List<String>? lines) {
      final map = <String, List<int>>{};
      for (final line in lines ?? const <String>[]) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length < 11) continue;
        map[parts[0]] = parts.skip(1).map(int.tryParse).nonNulls.toList();
      }
      return map;
    }

    final before = parse(first);
    final after = parse(second);
    final result = <DiskIoStat>[];
    after.forEach((name, now) {
      final previous = before[name];
      if (now.length < 10) return;
      double delta(int index) {
        if (previous == null || previous.length <= index) return 0;
        return math.max(0, now[index] - previous[index]) / interval;
      }

      result.add(
        DiskIoStat(
          name: name,
          readIops: delta(0),
          readRate: delta(2) * 512,
          writeIops: delta(4),
          writeRate: delta(6) * 512,
          busyPercent: (delta(9) / 10).clamp(0, 100),
          totalReadBytes: now[2] * 512,
          totalWriteBytes: now[6] * 512,
        ),
      );
    });
    // 從沒讀寫過的裝置（例如空的光碟機）不顯示。
    result.removeWhere(
      (disk) => disk.totalReadBytes == 0 && disk.totalWriteBytes == 0,
    );
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  static List<GpuInfo> _parseGpus(
    List<String>? nvidia,
    List<String>? processes,
    List<String>? amd,
  ) {
    final procsByGpu = <String, List<GpuProcess>>{};
    for (final line in processes ?? const <String>[]) {
      final parts = line.split(',').map((part) => part.trim()).toList();
      if (parts.length < 4) continue;
      procsByGpu
          .putIfAbsent(parts[0], () => [])
          .add(
            GpuProcess(
              pid: int.tryParse(parts[1]) ?? 0,
              name: parts[2],
              usedMemoryMiB: double.tryParse(parts[3]) ?? 0,
            ),
          );
    }

    final result = <GpuInfo>[];
    for (final line in nvidia ?? const <String>[]) {
      // index, uuid, name, util, mem.used, mem.total, temp, power.draw, power.limit
      final parts = line.split(',').map((part) => part.trim()).toList();
      if (parts.length < 6) continue;
      result.add(
        GpuInfo(
          index: parts[0],
          name: parts[2],
          utilPercent: double.tryParse(parts[3]) ?? 0,
          memUsedMiB: double.tryParse(parts[4]) ?? 0,
          memTotalMiB: double.tryParse(parts[5]) ?? 0,
          temperature: parts.length > 6 ? double.tryParse(parts[6]) : null,
          powerDraw: parts.length > 7 ? double.tryParse(parts[7]) : null,
          powerLimit: parts.length > 8 ? double.tryParse(parts[8]) : null,
          processes: procsByGpu[parts[1]] ?? const [],
        ),
      );
    }
    for (final line in amd ?? const <String>[]) {
      // card|busy%|vram_used(bytes)|vram_total(bytes)|name
      final parts = line.split('|');
      if (parts.length < 2) continue;
      double mib(int index) =>
          (double.tryParse(parts.length > index ? parts[index] : '') ?? 0) /
          (1024 * 1024);
      result.add(
        GpuInfo(
          index: parts[0],
          name: parts.length > 4 && parts[4].trim().isNotEmpty
              ? parts[4].trim()
              : 'AMD GPU (${parts[0]})',
          utilPercent: double.tryParse(parts[1]) ?? 0,
          memUsedMiB: mib(2),
          memTotalMiB: mib(3),
        ),
      );
    }
    return result;
  }

  static List<TemperatureReading> _parseTemperatures(List<String>? lines) {
    final result = <TemperatureReading>[];
    for (final line in lines ?? const <String>[]) {
      final parts = line.split('|');
      if (parts.length < 2) continue;
      final milli = double.tryParse(parts[1].trim());
      if (milli == null) continue;
      final celsius = milli.abs() > 1000 ? milli / 1000 : milli;
      // 未接感測器常回報 0 或離譜數值。
      if (celsius <= 0 || celsius > 150) continue;
      result.add(TemperatureReading(label: parts[0].trim(), celsius: celsius));
    }
    return result;
  }
}
