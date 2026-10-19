/// 腳本庫中的一段腳本；可批次在多台伺服器執行，也能在終端機當快捷片段。
class Script {
  const Script({
    required this.id,
    required this.name,
    required this.content,
    this.description = '',
    this.useSudo = false,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Script.fromJson(Map<String, dynamic> json) => Script(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    content: json['content'] as String? ?? '',
    description: json['description'] as String? ?? '',
    useSudo: json['useSudo'] as bool? ?? false,
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
  );

  final String id;
  final String name;
  final String content;
  final String description;

  /// 預設以 sudo 執行（會用已儲存的密碼回應 sudo）。
  final bool useSudo;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 第一行非空白內容，列表預覽用。
  String get preview => content
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'content': content,
    'description': description,
    'useSudo': useSudo,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  Script copyWith({
    String? name,
    String? content,
    String? description,
    bool? useSudo,
    DateTime? updatedAt,
  }) => Script(
    id: id,
    name: name ?? this.name,
    content: content ?? this.content,
    description: description ?? this.description,
    useSudo: useSudo ?? this.useSudo,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

enum ScriptResultState { pending, running, success, failed }

/// 某台伺服器的執行結果。
class ScriptRunResult {
  ScriptRunResult({
    required this.serverId,
    required this.serverName,
    this.state = ScriptResultState.pending,
    this.exitCode,
    this.output = '',
    this.error,
    this.duration,
  });

  factory ScriptRunResult.fromJson(Map<String, dynamic> json) =>
      ScriptRunResult(
        serverId: json['serverId'] as String? ?? '',
        serverName: json['serverName'] as String? ?? '',
        state:
            ScriptResultState.values.asNameMap()[json['state']] ??
            ScriptResultState.failed,
        exitCode: json['exitCode'] as int?,
        output: json['output'] as String? ?? '',
        error: json['error'] as String?,
        duration: json['durationMs'] == null
            ? null
            : Duration(milliseconds: json['durationMs'] as int),
      );

  final String serverId;
  final String serverName;
  ScriptResultState state;
  int? exitCode;

  /// stdout 與 stderr 依時間順序合併的輸出。
  String output;
  String? error;
  Duration? duration;

  bool get finished =>
      state == ScriptResultState.success || state == ScriptResultState.failed;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'serverId': serverId,
    'serverName': serverName,
    // 尚未跑完就被存檔（例如 App 被關掉）時，一律記成失敗。
    'state': finished ? state.name : ScriptResultState.failed.name,
    'exitCode': exitCode,
    'output': output,
    'error': finished ? error : error ?? '執行中斷',
    'durationMs': duration?.inMilliseconds,
  };
}

/// 一次批次執行（同一段腳本、可能多台伺服器）。
class ScriptRun {
  ScriptRun({
    required this.id,
    required this.scriptName,
    required this.content,
    required this.sudo,
    required this.startedAt,
    required this.results,
    this.finishedAt,
  });

  factory ScriptRun.fromJson(Map<String, dynamic> json) => ScriptRun(
    id: json['id'] as String,
    scriptName: json['scriptName'] as String? ?? '',
    content: json['content'] as String? ?? '',
    sudo: json['sudo'] as bool? ?? false,
    startedAt:
        DateTime.tryParse(json['startedAt'] as String? ?? '') ?? DateTime.now(),
    finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
    results: (json['results'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ScriptRunResult.fromJson)
        .toList(),
  );

  final String id;
  final String scriptName;
  final String content;
  final bool sudo;
  final DateTime startedAt;
  DateTime? finishedAt;
  final List<ScriptRunResult> results;

  bool get finished => results.every((result) => result.finished);
  int get successCount => results
      .where((result) => result.state == ScriptResultState.success)
      .length;
  int get failedCount => results
      .where((result) => result.state == ScriptResultState.failed)
      .length;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'scriptName': scriptName,
    'content': content,
    'sudo': sudo,
    'startedAt': startedAt.toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
    'results': results.map((result) => result.toJson()).toList(),
  };
}
