import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/server_metrics.dart';
import '../models/server_profile.dart';
import '../utils/error_messages.dart';
import '../utils/format.dart';
import 'settings_store.dart';
import 'ssh_service.dart';

/// 預設模型：Anthropic 用目前的 Claude Opus，OpenAI 相容端點由使用者自填。
const defaultAnthropicModel = 'claude-opus-5-5';
const defaultOpenAiModel = 'gpt-4.1';
const _anthropicEndpoint = 'https://api.anthropic.com';
const _openAiEndpoint = 'https://api.openai.com/v1';

/// AI 回覆最多連續呼叫工具幾輪，避免失控。
const _maxToolRounds = 24;
const _maxToolOutputChars = 16000;

class AiImage {
  const AiImage({required this.mediaType, required this.base64Data});

  factory AiImage.fromJson(Map<String, dynamic> json) => AiImage(
    mediaType: json['mediaType'] as String? ?? 'image/png',
    base64Data: json['data'] as String? ?? '',
  );

  final String mediaType;
  final String base64Data;

  Uint8List get bytes => base64.decode(base64Data);

  Map<String, dynamic> toJson() => {'mediaType': mediaType, 'data': base64Data};
}

enum AiItemKind { user, assistant, progress, tool, notice }

enum AiToolStatus { awaitingApproval, running, done, denied, failed }

/// 對話畫面上的一則項目（與送給 API 的原始訊息分開保存）。
class AiChatItem {
  AiChatItem({
    required this.kind,
    this.text = '',
    this.images = const [],
    this.toolName,
    this.toolInput,
    this.toolStatus,
    this.toolOutput,
    this.isError = false,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  factory AiChatItem.fromJson(Map<String, dynamic> json) => AiChatItem(
    kind: AiItemKind.values.asNameMap()[json['kind']] ?? AiItemKind.notice,
    text: json['text'] as String? ?? '',
    images: (json['images'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AiImage.fromJson)
        .toList(),
    toolName: json['toolName'] as String?,
    toolInput: json['toolInput'] as Map<String, dynamic>?,
    toolStatus: AiToolStatus.values.asNameMap()[json['toolStatus']],
    toolOutput: json['toolOutput'] as String?,
    isError: json['isError'] as bool? ?? false,
    time: DateTime.tryParse(json['time'] as String? ?? ''),
  );

  final AiItemKind kind;
  String text;
  final List<AiImage> images;
  final String? toolName;
  final Map<String, dynamic>? toolInput;
  AiToolStatus? toolStatus;
  String? toolOutput;
  bool isError;
  final DateTime time;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'text': text,
    if (images.isNotEmpty)
      'images': images.map((item) => item.toJson()).toList(),
    'toolName': ?toolName,
    'toolInput': ?toolInput,
    // 等待確認或執行中的狀態不保留，重新開啟時一律視為中斷。
    if (toolStatus != null)
      'toolStatus':
          (toolStatus == AiToolStatus.awaitingApproval ||
              toolStatus == AiToolStatus.running)
          ? AiToolStatus.failed.name
          : toolStatus!.name,
    'toolOutput': ?toolOutput,
    'isError': isError,
    'time': time.toIso8601String(),
  };
}

/// 一段對話。送給 API 的 [apiMessages] 只會往後附加，不會修改先前內容：
/// Claude 的 thinking 區塊綁定整段對話前綴，改動歷史會讓之後的請求失敗。
/// system prompt 也在建立時固定。
class AiConversation {
  AiConversation({
    required this.provider,
    required this.system,
    List<Map<String, dynamic>>? apiMessages,
    List<AiChatItem>? items,
  }) : apiMessages = apiMessages ?? [],
       items = items ?? [];

  factory AiConversation.fromJson(Map<String, dynamic> json) => AiConversation(
    provider:
        AiProvider.values.asNameMap()[json['provider']] ?? AiProvider.anthropic,
    system: json['system'] as String? ?? '',
    apiMessages: (json['apiMessages'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(),
    items: (json['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AiChatItem.fromJson)
        .toList(),
  );

  final AiProvider provider;
  final String system;
  final List<Map<String, dynamic>> apiMessages;
  final List<AiChatItem> items;

  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    'system': system,
    'apiMessages': apiMessages,
    'items': items.map((item) => item.toJson()).toList(),
  };
}

/// 一次工具呼叫：名稱、輸入與對應的 id（Anthropic `tool_use.id`／OpenAI
/// `tool_call.id`）。
class _ToolCall {
  const _ToolCall(this.id, this.name, this.input, {this.parseError});

  final String id;
  final String name;
  final Map<String, dynamic> input;
  final String? parseError;
}

/// 一輪 API 回應整理後的結果。
class _Turn {
  _Turn({
    required this.assistantMessage,
    required this.texts,
    required this.progress,
    required this.toolCalls,
    required this.stop,
    this.stopDetail,
  });

  final Map<String, dynamic>? assistantMessage;
  final List<String> texts;
  final List<String> progress;
  final List<_ToolCall> toolCalls;

  /// `end`、`tool_use`、`max_tokens`、`refusal`、`filtered`。
  final String stop;
  final String? stopDetail;
}

class AiApiException implements Exception {
  const AiApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// 單台伺服器的 AI 助理（不需要在伺服器上安裝任何代理程式）。
///
/// 讀取監控指標、執行指令、讀寫檔案都透過既有的 SSH 連線完成；會修改系統的
/// 操作預設需要使用者逐一核准。
class AiAgent extends ChangeNotifier {
  AiAgent({
    required this.serverId,
    required this._ssh,
    required this._settings,
    required this._resolveProfile,
    required this._latestMetrics,
    http.Client Function()? clientFactory,
    this.persist = true,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  final String serverId;
  final SSHService _ssh;
  final SettingsStore _settings;
  final Future<ServerProfile> Function() _resolveProfile;
  final ServerMetrics? Function() _latestMetrics;
  final http.Client Function() _clientFactory;

  /// 是否把對話寫進檔案（測試時關閉）。
  final bool persist;

  AiConversation? _conversation;
  bool _loaded = false;
  bool busy = false;
  bool _cancelled = false;
  http.Client? _client;

  /// 計畫模式：只調查與提出計畫，不執行變更。
  bool planMode = false;

  /// 目前等待使用者核准的工具呼叫。
  AiChatItem? pendingApproval;
  Completer<bool>? _approval;

  List<AiChatItem> get items => _conversation?.items ?? const [];
  bool get hasConversation => items.isNotEmpty;

  Future<File> _file() async {
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}/ai_chats',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    return File('${directory.path}/$serverId.json');
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (!persist) return;
    try {
      final file = await _file();
      if (await file.exists()) {
        _conversation = AiConversation.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        );
      }
    } catch (error) {
      debugPrint('無法讀取 AI 對話：$error');
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    if (!persist) return;
    try {
      final file = await _file();
      final conversation = _conversation;
      if (conversation == null) {
        if (await file.exists()) await file.delete();
      } else {
        await file.writeAsString(jsonEncode(conversation.toJson()));
      }
    } catch (error) {
      debugPrint('無法儲存 AI 對話：$error');
    }
  }

  Future<void> clear() async {
    if (busy) stop();
    _conversation = null;
    notifyListeners();
    await _persist();
  }

  void stop() {
    _cancelled = true;
    _client?.close();
    resolveApproval(false);
  }

  void resolveApproval(bool approved) {
    final completer = _approval;
    _approval = null;
    pendingApproval = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(approved);
    }
    notifyListeners();
  }

  void _notice(String text, {bool error = false}) {
    _conversation?.items.add(
      AiChatItem(kind: AiItemKind.notice, text: text, isError: error),
    );
  }

  Future<void> send(String text, {List<AiImage> images = const []}) async {
    if (busy || (text.trim().isEmpty && images.isEmpty)) return;
    await load();
    final provider = _settings.aiProvider;
    final profile = await _resolveProfile();

    var conversation = _conversation;
    if (conversation != null && conversation.provider != provider) {
      // 不同供應商的訊息格式不相容，換供應商就開新對話。
      conversation.items.add(
        AiChatItem(kind: AiItemKind.notice, text: '已切換 AI 供應商，開始新的對話'),
      );
      conversation = null;
    }
    conversation ??= _conversation = AiConversation(
      provider: provider,
      system: _systemPrompt(profile),
      items: _conversation?.items ?? [],
    );

    busy = true;
    _cancelled = false;
    final plan = planMode;
    conversation.items.add(
      AiChatItem(kind: AiItemKind.user, text: text.trim(), images: images),
    );
    final prompt = plan
        ? '${text.trim()}\n\n（計畫模式：請先用唯讀工具調查，再列出編號步驟的執行計畫。'
              '不要執行任何會修改系統的指令或寫入檔案，等我確認後再動手。）'
        : text.trim();
    conversation.apiMessages.add(_userMessage(provider, prompt, images));
    notifyListeners();

    try {
      for (var round = 0; round < _maxToolRounds; round++) {
        if (_cancelled) break;
        final turn = await _request(conversation);
        if (_cancelled) break;

        if (turn.stop == 'refusal' || turn.stop == 'filtered') {
          _notice(
            turn.stopDetail == null
                ? '模型拒絕了這個請求。'
                : '模型拒絕了這個請求（類別：${turn.stopDetail}）。',
            error: true,
          );
          break;
        }

        final assistant = turn.assistantMessage;
        if (assistant != null) conversation.apiMessages.add(assistant);
        for (final note in turn.progress) {
          conversation.items.add(
            AiChatItem(kind: AiItemKind.progress, text: note),
          );
        }
        for (final reply in turn.texts) {
          conversation.items.add(
            AiChatItem(kind: AiItemKind.assistant, text: reply),
          );
        }
        notifyListeners();

        if (turn.toolCalls.isEmpty) {
          if (turn.stop == 'max_tokens') {
            _notice('回覆超過長度上限而被截斷。', error: true);
          }
          break;
        }

        final truncated = turn.stop == 'max_tokens';
        final results = <(String, String, bool)>[];
        for (final call in turn.toolCalls) {
          if (_cancelled || truncated || call.parseError != null) {
            results.add((
              call.id,
              _cancelled
                  ? '使用者已停止。'
                  : truncated
                  ? '回覆被截斷，工具參數可能不完整，未執行。'
                  : '工具參數不是有效的 JSON：${call.parseError}',
              true,
            ));
            continue;
          }
          results.add(await _runTool(call, profile, plan));
        }
        conversation.apiMessages.addAll(_toolResultMessages(provider, results));
        notifyListeners();
        if (_cancelled || truncated) break;
      }
    } on AiApiException catch (error) {
      _notice(error.message, error: true);
    } on http.ClientException catch (error) {
      if (!_cancelled) _notice('無法連到 AI 服務：${error.message}', error: true);
    } on SocketException catch (error) {
      _notice('無法連到 AI 服務：${error.message}', error: true);
    } catch (error) {
      if (!_cancelled) _notice('AI 助理發生錯誤：$error', error: true);
    } finally {
      if (_cancelled) _notice('已停止。');
      busy = false;
      _client?.close();
      _client = null;
      pendingApproval = null;
      notifyListeners();
      await _persist();
    }
  }

  String _systemPrompt(ServerProfile profile) {
    final metrics = _latestMetrics();
    final os = metrics == null || metrics.osName.isEmpty
        ? 'unknown (call get_server_metrics to find out)'
        : '${metrics.osName}, kernel ${metrics.kernel}';
    return '''
You are Mato's server assistant, operating one Linux server for the user over SSH. You act through the tools provided; nothing is installed on the server.

Server: "${profile.name}" (${profile.username}@${profile.host}, port ${profile.port}).
Operating system: $os.
Login user: ${profile.username}${profile.isRoot ? ' (root)' : ' (not root; use sudo: true in run_command for privileged commands)'}.

How to work:
- Investigate before changing anything: read metrics, logs, configs and command output first, then explain what you found.
- Prefer read-only commands. Before a command that changes the system (installs, restarts, deletes, edits configs), say in one sentence what it will do and why. The user approves every such command in the app, and may decline.
- Commands run non-interactively with no TTY and a timeout, so never start editors, pagers or anything that waits for input; pass flags such as -y, --no-pager and -b where needed.
- Keep command output small (use head, tail, grep, --lines) so it fits in your context.
- If the user asked only for a plan, do not run commands that change the system.
- Reply in the user's language; default to Traditional Chinese (zh-TW). Be concise and use Markdown code blocks for commands and file contents.''';
  }

  // ---------------------------------------------------------------------------
  // 工具

  static const _readOnlyTools = {
    'get_server_metrics',
    'read_file',
    'list_directory',
  };

  static final List<Map<String, dynamic>> _tools = [
    {
      'name': 'get_server_metrics',
      'description':
          'Get a live snapshot of the server: OS, uptime, load, CPU usage per '
          'core, temperature, memory, swap, disk usage per mount, disk I/O, '
          'network throughput and GPUs. Call this first whenever the user asks '
          'about health, performance, slowness or resource usage.',
      'input_schema': {'type': 'object', 'properties': <String, dynamic>{}},
    },
    {
      'name': 'run_command',
      'description':
          'Run a shell command on the server over SSH and return its exit code, '
          'stdout and stderr. Non-interactive, no TTY, 120 second timeout. Use it '
          'to inspect state (ps, ss, journalctl --no-pager, systemctl status, '
          'docker ps, df) and to make changes the user asked for. The user '
          'approves commands in the app before they run.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': 'The command line to run.',
          },
          'reason': {
            'type': 'string',
            'description':
                'One short sentence telling the user what this command does.',
          },
          'sudo': {
            'type': 'boolean',
            'description': 'Run with sudo using the saved password. Only when root is needed.',
          },
        },
        'required': ['command', 'reason'],
      },
    },
    {
      'name': 'read_file',
      'description':
          'Read a text file on the server (configs, logs, scripts). Returns up to '
          'max_bytes; set tail to true to read the end of a log instead of the '
          'beginning.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Absolute path.'},
          'max_bytes': {
            'type': 'integer',
            'description':
                'Maximum bytes to return (default 32768, max 65536).',
          },
          'tail': {
            'type': 'boolean',
            'description': 'Read the last max_bytes of the file.',
          },
        },
        'required': ['path'],
      },
    },
    {
      'name': 'list_directory',
      'description':
          'List a directory on the server with type, permissions, size and '
          'modification time of each entry.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Absolute path.'},
        },
        'required': ['path'],
      },
    },
    {
      'name': 'write_file',
      'description':
          'Create or overwrite a text file on the server with the given content. '
          'Read the file first when editing an existing one, and write the '
          'complete new content. The user approves the write in the app.',
      'input_schema': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': 'Absolute path.'},
          'content': {
            'type': 'string',
            'description': 'Full new file content.',
          },
        },
        'required': ['path', 'content'],
      },
    },
  ];

  Future<(String, String, bool)> _runTool(
    _ToolCall call,
    ServerProfile profile,
    bool plan,
  ) async {
    final conversation = _conversation!;
    final item = AiChatItem(
      kind: AiItemKind.tool,
      toolName: call.name,
      toolInput: call.input,
      toolStatus: AiToolStatus.running,
    );
    conversation.items.add(item);

    final readOnly = _readOnlyTools.contains(call.name);
    if (plan && !readOnly) {
      item
        ..toolStatus = AiToolStatus.denied
        ..toolOutput = '計畫模式：未執行';
      notifyListeners();
      return (
        call.id,
        'Not executed: plan mode is on. Present the plan and wait for the '
            'user to approve it.',
        true,
      );
    }

    final needsApproval = readOnly
        ? !_settings.aiAutoApproveReads
        : !_settings.aiAutoApproveAll;
    if (needsApproval) {
      item.toolStatus = AiToolStatus.awaitingApproval;
      pendingApproval = item;
      final completer = _approval = Completer<bool>();
      notifyListeners();
      final approved = await completer.future;
      if (!approved) {
        item
          ..toolStatus = AiToolStatus.denied
          ..toolOutput = '使用者拒絕';
        notifyListeners();
        return (call.id, 'The user declined to run this.', true);
      }
      item.toolStatus = AiToolStatus.running;
      notifyListeners();
    } else {
      notifyListeners();
    }

    try {
      final output = await _executeTool(call, profile);
      item
        ..toolStatus = AiToolStatus.done
        ..toolOutput = output.$1;
      notifyListeners();
      return (call.id, _clip(output.$1), output.$2);
    } catch (error) {
      final message = describeSshError(error);
      item
        ..toolStatus = AiToolStatus.failed
        ..toolOutput = message;
      notifyListeners();
      return (call.id, 'Error: $message', true);
    }
  }

  /// 回傳（輸出, 是否為錯誤）。
  Future<(String, bool)> _executeTool(
    _ToolCall call,
    ServerProfile profile,
  ) async {
    final input = call.input;
    switch (call.name) {
      case 'get_server_metrics':
        final metrics = await _ssh.fetchMetrics(profile);
        return (
          const JsonEncoder.withIndent(' ').convert(_metricsJson(metrics)),
          false,
        );

      case 'run_command':
        final command = input['command'];
        if (command is! String || command.trim().isEmpty) {
          return ('Missing "command".', true);
        }
        final result = input['sudo'] == true
            ? await _ssh.runPrivileged(
                profile,
                command,
                timeout: const Duration(seconds: 120),
              )
            : await _ssh.run(
                profile,
                command,
                timeout: const Duration(seconds: 120),
              );
        final buffer = StringBuffer('exit_code: ${result.exitCode}\n');
        if (result.stdout.isNotEmpty) {
          buffer.write('stdout:\n${result.stdout}\n');
        }
        if (result.stderr.isNotEmpty) {
          buffer.write('stderr:\n${result.stderr}\n');
        }
        if (result.truncated) buffer.write('(output truncated)\n');
        return (buffer.toString(), false);

      case 'read_file':
        final path = input['path'];
        if (path is! String || path.isEmpty) return ('Missing "path".', true);
        final limit = ((input['max_bytes'] as num?)?.toInt() ?? 32768).clamp(
          1,
          65536,
        );
        final size = (await _ssh.stat(profile, path)).size ?? 0;
        final offset = input['tail'] == true && size > limit ? size - limit : 0;
        final bytes = await _ssh.readFile(
          profile,
          path,
          length: limit,
          offset: offset,
        );
        if (bytes.contains(0)) {
          return (
            'This looks like a binary file ($size bytes); not shown.',
            true,
          );
        }
        final text = utf8.decode(bytes, allowMalformed: true);
        final end = offset + bytes.length;
        final range = offset > 0 || end < size
            ? '(bytes $offset-$end of $size)\n'
            : '';
        return ('$range$text', false);

      case 'list_directory':
        final path = input['path'];
        if (path is! String || path.isEmpty) return ('Missing "path".', true);
        final entries = await _ssh.listDirectory(profile, path);
        final lines = entries.take(300).map((entry) {
          final type = entry.isDirectory
              ? 'd'
              : entry.isSymlink
              ? 'l'
              : '-';
          final size = entry.isDirectory ? '-' : formatBytes(entry.size ?? 0);
          final time = entry.modifiedTime == null
              ? ''
              : formatDateTime(entry.modifiedTime!);
          return '$type${entry.permissions} ${size.padLeft(9)} $time ${entry.name}';
        });
        final more = entries.length > 300
            ? '\n… ${entries.length - 300} more entries'
            : '';
        return (
          entries.isEmpty ? '(empty directory)' : '${lines.join('\n')}$more',
          false,
        );

      case 'write_file':
        final path = input['path'];
        final content = input['content'];
        if (path is! String || path.isEmpty || content is! String) {
          return ('Missing "path" or "content".', true);
        }
        final data = Uint8List.fromList(utf8.encode(content));
        await _ssh.writeFile(profile, path, data);
        return ('Wrote ${data.length} bytes to $path.', false);
    }
    return ('Unknown tool "${call.name}".', true);
  }

  static Map<String, dynamic> _metricsJson(ServerMetrics metrics) => {
    'os': metrics.osName,
    'kernel': metrics.kernel,
    'hostname': metrics.hostname,
    'uptime': metrics.uptimeLabel,
    'load_average': [metrics.load1, metrics.load5, metrics.load15],
    'cpu': {
      'model': metrics.cpuModel,
      'cores': metrics.cores,
      'usage_percent': metrics.cpuPercent.toStringAsFixed(1),
      'iowait_percent': metrics.iowaitPercent.toStringAsFixed(1),
      'temperature_c': metrics.cpuTemperature?.toStringAsFixed(1),
    },
    'memory': {
      'used': formatBytes(metrics.memUsedBytes),
      'total': formatBytes(metrics.memTotalBytes),
      'cache': formatBytes(metrics.memCacheBytes),
      'swap_used': formatBytes(metrics.swapUsedBytes),
      'swap_total': formatBytes(metrics.swapTotalBytes),
    },
    'filesystems': [
      for (final fs in metrics.fileSystems)
        {
          'mount': fs.mount,
          'type': fs.fsType,
          'used': formatBytes(fs.usedBytes),
          'size': formatBytes(fs.totalBytes),
          'use_percent': fs.percent.round(),
        },
    ],
    'disk_io': {
      'read_per_s': formatRate(metrics.diskReadRate),
      'write_per_s': formatRate(metrics.diskWriteRate),
      'iops': metrics.diskIops.round(),
    },
    'network': {
      'rx_per_s': formatRate(metrics.netRxRate),
      'tx_per_s': formatRate(metrics.netTxRate),
      'interfaces': [for (final item in metrics.netInterfaces) item.name],
    },
    'processes': metrics.totalProcesses,
    if (metrics.gpus.isNotEmpty)
      'gpus': [
        for (final gpu in metrics.gpus)
          {
            'name': gpu.name,
            'util_percent': gpu.utilPercent.round(),
            'memory_mib':
                '${gpu.memUsedMiB.round()}/${gpu.memTotalMiB.round()}',
            'temperature_c': gpu.temperature,
          },
      ],
  };

  static String _clip(String text) {
    if (text.length <= _maxToolOutputChars) return text;
    const head = 6000;
    final tail = _maxToolOutputChars - head;
    return '${text.substring(0, head)}\n…（省略 ${text.length - _maxToolOutputChars} 字元）…\n'
        '${text.substring(text.length - tail)}';
  }

  // ---------------------------------------------------------------------------
  // 供應商格式

  Map<String, dynamic> _userMessage(
    AiProvider provider,
    String text,
    List<AiImage> images,
  ) {
    if (provider == AiProvider.anthropic) {
      return {
        'role': 'user',
        'content': [
          for (final image in images)
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': image.mediaType,
                'data': image.base64Data,
              },
            },
          {'type': 'text', 'text': text.isEmpty ? '（請看圖片）' : text},
        ],
      };
    }
    return {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text.isEmpty ? '（請看圖片）' : text},
        for (final image in images)
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:${image.mediaType};base64,${image.base64Data}',
            },
          },
      ],
    };
  }

  /// 同一輪的所有工具結果：Anthropic 放在同一則 user 訊息；OpenAI 每個結果
  /// 一則 `tool` 訊息。
  List<Map<String, dynamic>> _toolResultMessages(
    AiProvider provider,
    List<(String, String, bool)> results,
  ) {
    if (provider == AiProvider.anthropic) {
      return [
        {
          'role': 'user',
          'content': [
            for (final (id, output, isError) in results)
              {
                'type': 'tool_result',
                'tool_use_id': id,
                'content': output,
                if (isError) 'is_error': true,
              },
          ],
        },
      ];
    }
    return [
      for (final (id, output, isError) in results)
        {
          'role': 'tool',
          'tool_call_id': id,
          'content': isError ? 'Error: $output' : output,
        },
    ];
  }

  Future<_Turn> _request(AiConversation conversation) {
    _client?.close();
    _client = _clientFactory();
    return conversation.provider == AiProvider.anthropic
        ? _requestAnthropic(conversation, _client!)
        : _requestOpenAi(conversation, _client!);
  }

  Future<_Turn> _requestAnthropic(
    AiConversation conversation,
    http.Client client,
  ) async {
    final apiKey = _settings.aiApiKey;
    final custom = _settings.aiBaseUrl.isNotEmpty;
    if (apiKey.isEmpty && !custom) {
      throw const AiApiException('尚未設定 Anthropic API 金鑰，請到「設定 › AI 助理」填寫。');
    }
    final base = (custom ? _settings.aiBaseUrl : _anthropicEndpoint)
        .replaceFirst(RegExp(r'/+$'), '');
    final url = base.endsWith('/v1') ? '$base/messages' : '$base/v1/messages';
    final model = _settings.aiModel.isEmpty
        ? defaultAnthropicModel
        : _settings.aiModel;

    final betas = <String>[];
    final body = <String, dynamic>{
      'model': model,
      'max_tokens': 16000,
      'system': conversation.system,
      'tools': _tools,
      'messages': conversation.apiMessages,
    };
    if (_supportsEffort(model)) {
      body['output_config'] = {'effort': _settings.aiEffort};
    }
    // 這些 beta 只在官方端點使用：自架代理常會拒絕不認得的欄位。
    if (!custom) {
      if (_supportsProgressUpdates(model)) {
        betas.add('thinking-display-updates-2026-08-18');
        body['thinking'] = {'type': 'adaptive', 'display': 'updates'};
      }
      if (_supportsDefaultFallbacks(model)) {
        // 安全分類器誤判時，由 Anthropic 建議的模型接手，而不是直接拒絕。
        betas.add('server-side-fallback-2026-07-01');
        body['fallbacks'] = 'default';
      }
    }

    final response = await client.post(
      Uri.parse(url),
      headers: {
        'content-type': 'application/json',
        'anthropic-version': '2023-06-01',
        if (apiKey.isNotEmpty) 'x-api-key': apiKey,
        if (betas.isNotEmpty) 'anthropic-beta': betas.join(','),
      },
      body: jsonEncode(body),
    );
    final json = _decode(response);

    final stopReason = json['stop_reason'] as String? ?? 'end_turn';
    if (stopReason == 'refusal') {
      final details = json['stop_details'];
      return _Turn(
        assistantMessage: null,
        texts: const [],
        progress: const [],
        toolCalls: const [],
        stop: 'refusal',
        stopDetail: details is Map ? details['category'] as String? : null,
      );
    }

    final content = (json['content'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final texts = <String>[];
    final progress = <String>[];
    final calls = <_ToolCall>[];
    for (final block in content) {
      switch (block['type']) {
        case 'text':
          final text = (block['text'] as String? ?? '').trim();
          if (text.isNotEmpty) texts.add(text);
        case 'thinking':
          final note = (block['thinking'] as String? ?? '').trim();
          if (note.isNotEmpty) progress.add(note);
        case 'tool_use':
          final input = block['input'];
          calls.add(
            _ToolCall(
              block['id'] as String,
              block['name'] as String? ?? '',
              input is Map<String, dynamic> ? input : const {},
              parseError: input is Map<String, dynamic> ? null : '$input',
            ),
          );
      }
    }
    return _Turn(
      // 原封不動回傳整段 content（含 thinking 區塊與簽章）。
      assistantMessage: content.isEmpty
          ? null
          : {'role': 'assistant', 'content': content},
      texts: texts,
      progress: progress,
      toolCalls: calls,
      stop: switch (stopReason) {
        'tool_use' => 'tool_use',
        'max_tokens' => 'max_tokens',
        _ => 'end',
      },
    );
  }

  Future<_Turn> _requestOpenAi(
    AiConversation conversation,
    http.Client client,
  ) async {
    final apiKey = _settings.aiApiKey;
    final base =
        (_settings.aiBaseUrl.isEmpty ? _openAiEndpoint : _settings.aiBaseUrl)
            .replaceFirst(RegExp(r'/+$'), '');
    final model = _settings.aiModel.isEmpty
        ? defaultOpenAiModel
        : _settings.aiModel;
    final body = {
      'model': model,
      'messages': [
        {'role': 'system', 'content': conversation.system},
        ...conversation.apiMessages,
      ],
      'tools': [
        for (final tool in _tools)
          {
            'type': 'function',
            'function': {
              'name': tool['name'],
              'description': tool['description'],
              'parameters': tool['input_schema'],
            },
          },
      ],
    };
    final response = await client.post(
      Uri.parse('$base/chat/completions'),
      headers: {
        'content-type': 'application/json',
        if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
      },
      body: jsonEncode(body),
    );
    final json = _decode(response);
    final choices = json['choices'] as List<dynamic>? ?? const [];
    if (choices.isEmpty) throw const AiApiException('AI 服務沒有回傳任何內容');
    final choice = choices.first as Map<String, dynamic>;
    final message = Map<String, dynamic>.from(
      choice['message'] as Map? ?? const {},
    );
    final finish = choice['finish_reason'] as String? ?? 'stop';

    final calls = <_ToolCall>[];
    for (final raw in (message['tool_calls'] as List<dynamic>? ?? const [])) {
      final call = raw as Map<String, dynamic>;
      final function = call['function'] as Map<String, dynamic>? ?? const {};
      final arguments = function['arguments'] as String? ?? '{}';
      Map<String, dynamic> input = const {};
      String? parseError;
      try {
        final decoded = jsonDecode(arguments.isEmpty ? '{}' : arguments);
        if (decoded is Map<String, dynamic>) input = decoded;
      } catch (_) {
        parseError = arguments;
      }
      calls.add(
        _ToolCall(
          call['id'] as String? ?? '',
          function['name'] as String? ?? '',
          input,
          parseError: parseError,
        ),
      );
    }
    final rawContent = message['content'];
    final text = (rawContent is String ? rawContent : '').trim();
    final toolCalls = message['tool_calls'] as List<dynamic>?;
    // 只回傳標準欄位：部分相容伺服器會拒絕 annotations、reasoning 等額外欄位。
    final assistant = <String, dynamic>{
      'role': 'assistant',
      'content': text,
      if (toolCalls != null && toolCalls.isNotEmpty)
        'tool_calls': [
          for (final raw in toolCalls.whereType<Map<String, dynamic>>())
            {
              'id': raw['id'],
              'type': 'function',
              'function': {
                'name': (raw['function'] as Map?)?['name'],
                'arguments': (raw['function'] as Map?)?['arguments'] ?? '{}',
              },
            },
        ],
    };
    return _Turn(
      assistantMessage: assistant,
      texts: text.isEmpty ? const [] : [text],
      progress: const [],
      toolCalls: calls,
      stop: switch (finish) {
        'tool_calls' => 'tool_use',
        'length' => 'max_tokens',
        'content_filter' => 'filtered',
        _ => calls.isNotEmpty ? 'tool_use' : 'end',
      },
    );
  }

  Map<String, dynamic> _decode(http.Response response) {
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {}
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        json != null) {
      return json;
    }
    final error = json?['error'];
    final detail = error is Map ? error['message'] as String? : null;
    final message = switch (response.statusCode) {
      401 || 403 => 'API 金鑰無效或沒有權限',
      404 => '找不到端點或模型，請確認 Base URL 與模型名稱',
      429 => '請求太頻繁或額度不足，請稍後再試',
      413 => '對話內容太長，請清除對話後再試',
      >= 500 => 'AI 服務暫時無法使用（${response.statusCode}）',
      _ => 'AI 服務回傳錯誤（${response.statusCode}）',
    };
    throw AiApiException(
      detail == null ? message : '$message：$detail',
      statusCode: response.statusCode,
    );
  }

  static const _effortModels = [
    'claude-fable-5',
    'claude-mythos-5',
    'claude-opus-5',
    'claude-sonnet-5',
    'claude-opus-4-8',
    'claude-opus-4-7',
    'claude-opus-4-6',
    'claude-sonnet-4-6',
  ];

  static bool _supportsEffort(String model) =>
      _effortModels.any(model.startsWith);

  static bool _supportsProgressUpdates(String model) => const [
    'claude-fable-5',
    'claude-mythos-5',
    'claude-opus-5-5',
    'claude-sonnet-5-5',
  ].any(model.startsWith);

  static bool _supportsDefaultFallbacks(String model) => const [
    'claude-fable-5-1',
    'claude-opus-5-5',
    'claude-opus-5',
    'claude-sonnet-5-5',
  ].contains(model);
}

/// 各伺服器的 AI 助理。
class AiHub {
  AiHub({
    required this._ssh,
    required this._settings,
    required this._resolve,
    required this._latestMetrics,
    this.clientFactory,
    this.persist = true,
  });

  final SSHService _ssh;
  final SettingsStore _settings;
  final Future<ServerProfile> Function(String id) _resolve;
  final ServerMetrics? Function(String id) _latestMetrics;
  final http.Client Function()? clientFactory;
  final bool persist;
  final Map<String, AiAgent> _agents = {};

  AiAgent agentFor(String serverId) => _agents.putIfAbsent(
    serverId,
    () => AiAgent(
      serverId: serverId,
      ssh: _ssh,
      settings: _settings,
      resolveProfile: () => _resolve(serverId),
      latestMetrics: () => _latestMetrics(serverId),
      clientFactory: clientFactory,
      persist: persist,
    )..load(),
  );

  Future<void> forget(String serverId) async {
    final agent = _agents.remove(serverId);
    if (agent != null) {
      await agent.clear();
      agent.dispose();
    }
  }
}
