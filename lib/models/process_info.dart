/// `ps` 列出的一個程序。
class ProcessInfo {
  const ProcessInfo({
    required this.pid,
    required this.ppid,
    required this.user,
    required this.cpu,
    required this.memory,
    required this.rssKb,
    required this.elapsed,
    required this.state,
    required this.args,
  });

  final int pid;
  final int ppid;
  final String user;

  /// %CPU（多核心時可能超過 100）。
  final double cpu;

  /// %MEM。
  final double memory;
  final int rssKb;
  final Duration? elapsed;

  /// `ps` 的 STAT，例如 `Ss`、`R+`、`Z`。
  final String state;

  /// 完整指令列。
  final String args;

  /// 執行檔名稱：取指令列第一段的檔名；核心執行緒保留中括號。
  String get name {
    final trimmed = args.trim();
    if (trimmed.startsWith('[')) return trimmed;
    var first = trimmed.split(RegExp(r'\s+')).first;
    // 許多常駐程式會把程序標題改成 `nginx: worker process` 這種格式。
    if (first.length > 1 && first.endsWith(':')) {
      first = first.substring(0, first.length - 1);
    }
    final slash = first.lastIndexOf('/');
    return slash < 0 ? first : first.substring(slash + 1);
  }

  bool get isKernelThread => args.trim().startsWith('[');
  bool get isZombie => state.startsWith('Z');
  bool get isRunning => state.startsWith('R');

  String get stateLabel {
    switch (state.isEmpty ? '' : state[0]) {
      case 'R':
        return '執行中';
      case 'S':
        return '睡眠';
      case 'D':
        return '不可中斷';
      case 'T':
        return '已停止';
      case 'Z':
        return '殭屍';
      case 'I':
        return '閒置';
      default:
        return state;
    }
  }

  /// procps 的 `ps`；BusyBox 版不支援這些欄位。
  static const command =
      'ps -eo pid=,ppid=,user:24=,pcpu=,pmem=,rss=,etime=,stat=,args= '
      '--sort=-pcpu 2>/dev/null || '
      'ps -eo pid=,ppid=,user=,pcpu=,pmem=,rss=,etime=,stat=,args=';

  static List<ProcessInfo> parse(String output) {
    final result = <ProcessInfo>[];
    final pattern = RegExp(
      r'^\s*(\d+)\s+(\d+)\s+(\S+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(.*)$',
    );
    for (final line in output.split('\n')) {
      final match = pattern.firstMatch(line);
      if (match == null) continue;
      result.add(
        ProcessInfo(
          pid: int.parse(match.group(1)!),
          ppid: int.parse(match.group(2)!),
          user: match.group(3)!,
          cpu: double.tryParse(match.group(4)!) ?? 0,
          memory: double.tryParse(match.group(5)!) ?? 0,
          rssKb: int.tryParse(match.group(6)!) ?? 0,
          elapsed: parseElapsed(match.group(7)!),
          state: match.group(8)!,
          args: match.group(9)!.trim(),
        ),
      );
    }
    return result;
  }

  /// `[[dd-]hh:]mm:ss`。
  static Duration? parseElapsed(String value) {
    var days = 0;
    var rest = value;
    final dash = rest.indexOf('-');
    if (dash > 0) {
      days = int.tryParse(rest.substring(0, dash)) ?? 0;
      rest = rest.substring(dash + 1);
    }
    final parts = rest.split(':').map(int.tryParse).toList();
    if (parts.any((part) => part == null)) return null;
    var hours = 0;
    var minutes = 0;
    var seconds = 0;
    if (parts.length == 3) {
      hours = parts[0]!;
      minutes = parts[1]!;
      seconds = parts[2]!;
    } else if (parts.length == 2) {
      minutes = parts[0]!;
      seconds = parts[1]!;
    } else {
      return null;
    }
    return Duration(
      days: days,
      hours: hours,
      minutes: minutes,
      seconds: seconds,
    );
  }
}

/// 可送出的訊號。
const processSignals = <String, String>{
  'TERM': '結束 (SIGTERM)',
  'KILL': '強制結束 (SIGKILL)',
  'HUP': '重新載入 (SIGHUP)',
  'INT': '中斷 (SIGINT)',
  'STOP': '暫停 (SIGSTOP)',
  'CONT': '繼續 (SIGCONT)',
};
