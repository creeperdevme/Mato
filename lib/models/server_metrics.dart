import 'dart:math' as math;

/// 從遠端主機 `/proc`、`df` 等來源蒐集到的系統指標。
///
/// 由 [SSHService.fetchMetrics] 取得，畫面端只負責呈現。來源是純文字
/// `KEY=VALUE` 清單，缺少關鍵欄位時 [tryParse] 會回傳 `null`，讓 UI 退回
/// 顯示原始輸出。
class ServerMetrics {
  const ServerMetrics({
    required this.osName,
    required this.kernel,
    required this.hostname,
    required this.uptime,
    required this.bootTime,
    required this.load1,
    required this.load5,
    required this.load15,
    required this.cores,
    required this.cpuPercent,
    required this.memTotalBytes,
    required this.memAvailableBytes,
    required this.swapTotalBytes,
    required this.swapFreeBytes,
    required this.diskTotalBytes,
    required this.diskUsedBytes,
    required this.raw,
  });

  /// 作業系統的 PRETTY_NAME，例如 `Ubuntu 24.04.1 LTS`。
  final String osName;
  final String kernel;
  final String hostname;
  final Duration? uptime;

  /// `uptime -s` 的原始字串，例如 `2026-10-19 08:12:33`。
  final String? bootTime;

  /// 1／5／15 分鐘平均負載。
  final double load1;
  final double load5;
  final double load15;

  /// CPU 核心數，用來把負載換算成合理比例。
  final int cores;

  /// 取樣區間內的 CPU 使用率（0–100）。
  final double cpuPercent;

  final int memTotalBytes;
  final int memAvailableBytes;
  final int swapTotalBytes;
  final int swapFreeBytes;
  final int diskTotalBytes;
  final int diskUsedBytes;

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

  /// 解析遠端指令輸出；缺少關鍵欄位時回傳 `null`。
  static ServerMetrics? tryParse(String raw) {
    final values = <String, String>{};
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      final separator = trimmed.indexOf('=');
      if (separator <= 0) continue;
      final key = trimmed.substring(0, separator).trim();
      if (key.isEmpty) continue;
      values[key] = trimmed.substring(separator + 1).trim();
    }

    final mem = _numbers(values['MEM']);
    final disk = _numbers(values['DISK']);
    final swap = _numbers(values['SWAP']);
    final load = _numbers(values['LOAD']);
    final cores = int.tryParse(values['CORES'] ?? '') ?? 0;
    final uptimeSeconds = int.tryParse(values['UPTIME'] ?? '');

    final diskTotalKb = _at(disk, 0) ?? 0;
    final diskUsedKb = _at(disk, 1) ?? 0;
    final cpuPercent = _cpuPercent(values['CPU1'], values['CPU2']);
    if (diskTotalKb <= 0 && cpuPercent == null) return null;

    return ServerMetrics(
      osName: (values['OS'] ?? '').replaceAll('"', '').trim(),
      kernel: (values['KERNEL'] ?? '').trim(),
      hostname: (values['HOST'] ?? '').trim(),
      uptime: uptimeSeconds == null
          ? null
          : Duration(seconds: math.max(0, uptimeSeconds)),
      bootTime: (values['BOOT'] ?? '').trim().isEmpty
          ? null
          : values['BOOT']!.trim(),
      load1: _at(load, 0) ?? 0,
      load5: _at(load, 1) ?? 0,
      load15: _at(load, 2) ?? 0,
      cores: cores > 0 ? cores : 1,
      cpuPercent: cpuPercent ?? 0,
      memTotalBytes: ((_at(mem, 0) ?? 0) * 1024).round(),
      memAvailableBytes: ((_at(mem, 1) ?? 0) * 1024).round(),
      swapTotalBytes: ((_at(swap, 0) ?? 0) * 1024).round(),
      swapFreeBytes: ((_at(swap, 1) ?? 0) * 1024).round(),
      diskTotalBytes: (diskTotalKb * 1024).round(),
      diskUsedBytes: (diskUsedKb * 1024).round(),
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
  static String formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = unit <= 1 || value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

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

  /// 兩次 `/proc/stat` 取樣換算 CPU 使用率。
  static double? _cpuPercent(String? first, String? second) {
    final a = _numbers(first);
    final b = _numbers(second);
    if (a.length < 2 || b.length < 2) return null;
    final totalA = a[0] + a[1];
    final totalB = b[0] + b[1];
    final totalDelta = totalB - totalA;
    final idleDelta = b[1] - a[1];
    if (totalDelta <= 0) return null;
    return ((totalDelta - idleDelta) / totalDelta * 100).clamp(0, 100);
  }
}
