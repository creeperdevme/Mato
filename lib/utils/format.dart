/// 共用的數字、時間格式化工具。
library;

const _byteUnits = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

/// 例：`15.6 GB`。
String formatBytes(num bytes) {
  var value = bytes.toDouble();
  if (value.isNaN || value < 0) value = 0;
  var unit = 0;
  while (value >= 1024 && unit < _byteUnits.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit <= 1 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${_byteUnits[unit]}';
}

/// 例：`19.8 / 31.3 GB`；單位不同時為 `512 MB / 2.0 GB`。
String formatBytesPair(num used, num total) {
  final a = formatBytes(used);
  final b = formatBytes(total);
  final unitA = a.substring(a.lastIndexOf(' ') + 1);
  final unitB = b.substring(b.lastIndexOf(' ') + 1);
  if (unitA != unitB) return '$a / $b';
  return '${a.substring(0, a.lastIndexOf(' '))} / $b';
}

/// 例：`1.2 MB/s`。
String formatRate(double bytesPerSecond) => '${formatBytes(bytesPerSecond)}/s';

/// 例：`12 天 4 小時`、`3 小時 8 分`、`42 秒`。
String formatDuration(Duration value) {
  final days = value.inDays;
  final hours = value.inHours % 24;
  final minutes = value.inMinutes % 60;
  if (days > 0) return '$days 天 $hours 小時';
  if (hours > 0) return '$hours 小時 $minutes 分';
  if (minutes > 0) return '$minutes 分';
  return '${value.inSeconds} 秒';
}

String _two(int value) => value.toString().padLeft(2, '0');

/// 例：`14:05:09`。
String formatClock(DateTime time) =>
    '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

/// 例：`2026-10-19 14:05`。
String formatDateTime(DateTime time) =>
    '${time.year}-${_two(time.month)}-${_two(time.day)} '
    '${_two(time.hour)}:${_two(time.minute)}';

/// 例：`剛剛`、`5 分鐘前`、`3 天前`。
String formatRelative(DateTime time, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(time);
  if (diff.inSeconds < 45) return '剛剛';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分鐘前';
  if (diff.inHours < 24) return '${diff.inHours} 小時前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return formatDateTime(time);
}

/// 百分比，例：`42%`、`3.5%`。
String formatPercent(double value) {
  if (value.isNaN) return '—';
  if (value > 0 && value < 10) return '${value.toStringAsFixed(1)}%';
  return '${value.round()}%';
}
