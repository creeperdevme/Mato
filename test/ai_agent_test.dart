import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mato/models/server_profile.dart';
import 'package:mato/services/ai_service.dart';
import 'package:mato/services/settings_store.dart';
import 'package:mato/services/ssh_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

class _FakeSsh extends SSHService {
  final List<String> commands = [];

  @override
  Future<RemoteRunResult> run(
    ServerProfile profile,
    String command, {
    Duration timeout = const Duration(seconds: 30),
    String? stdin,
    bool interactive = false,
    int maxOutputBytes = 8 * 1024 * 1024,
  }) async {
    commands.add(command);
    return const RemoteRunResult(
      stdout: 'Filesystem Size Used Avail Use% Mounted on\n/dev/sda1 100G 40G 60G 40% /\n',
      stderr: '',
      exitCode: 0,
    );
  }
}

Map<String, dynamic> _message(
  List<Map<String, dynamic>> content,
  String stop,
) => {
  'id': 'msg_1',
  'type': 'message',
  'role': 'assistant',
  'model': 'claude-opus-5-5',
  'content': content,
  'stop_reason': stop,
  'usage': {'input_tokens': 10, 'output_tokens': 10},
};

void main() {
  late SettingsStore settings;
  late _FakeSsh ssh;
  late List<http.Request> requests;
  late List<Map<String, dynamic>> responses;

  AiAgent buildAgent() => AiAgent(
    serverId: '1',
    ssh: ssh,
    settings: settings,
    resolveProfile: () async => testProfile(),
    latestMetrics: () => null,
    persist: false,
    clientFactory: () => MockClient((request) async {
      requests.add(request);
      return http.Response.bytes(
        utf8.encode(jsonEncode(responses.removeAt(0))),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsStore(storage: FakeSecureStorage());
    await settings.load();
    await settings.setAiApiKey('sk-ant-test');
    settings.aiEffort = 'high';
    ssh = _FakeSsh();
    requests = [];
  });

  test('工具迴圈：執行指令後把結果回傳，且歷史只往後附加', () async {
    settings.aiAutoApproveAll = true;
    final toolUse = {
      'type': 'tool_use',
      'id': 'toolu_1',
      'name': 'run_command',
      'input': {'command': 'df -h /', 'reason': '查看磁碟用量'},
    };
    final thinking = {
      'type': 'thinking',
      'thinking': '',
      'signature': 'sig-abc',
    };
    responses = [
      _message([
        thinking,
        {'type': 'text', 'text': '我先看看磁碟。'},
        toolUse,
      ], 'tool_use'),
      _message([
        {'type': 'text', 'text': '根目錄還有 60G 可用。'},
      ], 'end_turn'),
    ];

    final agent = buildAgent();
    await agent.send('磁碟還剩多少？');

    expect(ssh.commands, ['df -h /']);
    expect(requests, hasLength(2));

    final first = jsonDecode(requests[0].body) as Map<String, dynamic>;
    final second = jsonDecode(requests[1].body) as Map<String, dynamic>;

    expect(requests[0].url.toString(), 'https://api.anthropic.com/v1/messages');
    expect(requests[0].headers['x-api-key'], 'sk-ant-test');
    expect(requests[0].headers['anthropic-version'], '2023-06-01');
    expect(
      requests[0].headers['anthropic-beta'],
      contains('server-side-fallback-2026-07-01'),
    );
    expect(first['model'], defaultAnthropicModel);
    expect(first['fallbacks'], 'default');
    expect(first['output_config'], {'effort': 'high'});
    expect(
      (first['tools'] as List).map((tool) => tool['name']),
      contains('run_command'),
    );
    expect(first['system'], contains('web-01'));

    // system 與 tools 固定；先前的訊息原封不動，只在後面附加。
    expect(second['system'], first['system']);
    expect(second['tools'], first['tools']);
    final messages = second['messages'] as List;
    expect(messages, hasLength(3));
    expect(messages[0], (first['messages'] as List)[0]);
    expect(messages[1]['role'], 'assistant');
    expect(messages[1]['content'][0], thinking);
    expect(messages[1]['content'][2], toolUse);
    final result =
        (messages[2]['content'] as List).single as Map<String, dynamic>;
    expect(result['type'], 'tool_result');
    expect(result['tool_use_id'], 'toolu_1');
    expect(result['content'], contains('exit_code: 0'));
    expect(result.containsKey('is_error'), isFalse);

    final kinds = agent.items.map((item) => item.kind).toList();
    expect(kinds, [
      AiItemKind.user,
      AiItemKind.assistant,
      AiItemKind.tool,
      AiItemKind.assistant,
    ]);
    expect(agent.items[2].toolStatus, AiToolStatus.done);
    expect(agent.busy, isFalse);
  });

  test('使用者拒絕時不會執行，並回傳 is_error 的 tool_result', () async {
    settings.aiAutoApproveAll = false;
    responses = [
      _message([
        {
          'type': 'tool_use',
          'id': 'toolu_9',
          'name': 'run_command',
          'input': {'command': 'rm -rf /tmp/cache', 'reason': '清快取'},
        },
      ], 'tool_use'),
      _message([
        {'type': 'text', 'text': '好的，不執行。'},
      ], 'end_turn'),
    ];

    final agent = buildAgent();
    final approvals = <AiChatItem>[];
    void listener() {
      final pending = agent.pendingApproval;
      if (pending != null && !approvals.contains(pending)) {
        approvals.add(pending);
        scheduleMicrotask(() => agent.resolveApproval(false));
      }
    }

    agent.addListener(listener);
    await agent.send('清一下快取');
    agent.removeListener(listener);

    expect(approvals, hasLength(1));
    expect(ssh.commands, isEmpty);
    final second = jsonDecode(requests[1].body) as Map<String, dynamic>;
    final result = ((second['messages'] as List)[2]['content'] as List).single;
    expect(result['is_error'], isTrue);
    expect(
      agent.items.firstWhere((item) => item.kind == AiItemKind.tool).toolStatus,
      AiToolStatus.denied,
    );
  });

  test('計畫模式不會執行會變更系統的工具', () async {
    settings.aiAutoApproveAll = true;
    responses = [
      _message([
        {
          'type': 'tool_use',
          'id': 'toolu_2',
          'name': 'write_file',
          'input': {'path': '/etc/motd', 'content': 'hi'},
        },
      ], 'tool_use'),
      _message([
        {'type': 'text', 'text': '計畫：1. 修改 /etc/motd'},
      ], 'end_turn'),
    ];
    final agent = buildAgent()..planMode = true;
    await agent.send('幫我改登入訊息');

    final first = jsonDecode(requests[0].body) as Map<String, dynamic>;
    final prompt =
        ((first['messages'] as List)[0]['content'] as List).last['text'];
    expect(prompt, contains('計畫模式'));
    final second = jsonDecode(requests[1].body) as Map<String, dynamic>;
    final result = ((second['messages'] as List)[2]['content'] as List).single;
    expect(result['is_error'], isTrue);
    expect(result['content'], contains('plan mode'));
  });

  test('refusal 會顯示提示且不把空回覆加進歷史', () async {
    responses = [
      {
        ..._message(const [], 'refusal'),
        'stop_details': {'type': 'refusal', 'category': 'cyber'},
      },
      _message([
        {'type': 'text', 'text': '好的。'},
      ], 'end_turn'),
    ];
    final agent = buildAgent();
    await agent.send('第一個問題');

    final notice = agent.items.last;
    expect(notice.kind, AiItemKind.notice);
    expect(notice.isError, isTrue);
    expect(notice.text, contains('cyber'));

    await agent.send('換個問法');
    final second = jsonDecode(requests[1].body) as Map<String, dynamic>;
    final roles = (second['messages'] as List).map(
      (message) => message['role'],
    );
    expect(roles, ['user', 'user']);
  });

  test('OpenAI 相容格式：tool_calls 與 tool 訊息', () async {
    settings
      ..aiProvider = AiProvider.openai
      ..aiAutoApproveAll = true;
    await settings.setAiApiKey('sk-openai');
    responses = [
      {
        'choices': [
          {
            'finish_reason': 'tool_calls',
            'message': {
              'role': 'assistant',
              'content': null,
              'annotations': [],
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'run_command',
                    'arguments': '{"command":"uptime","reason":"查看負載"}',
                  },
                },
              ],
            },
          },
        ],
      },
      {
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'role': 'assistant', 'content': '負載很低。'},
          },
        ],
      },
    ];
    final agent = buildAgent();
    await agent.send('負載如何？');

    expect(
      requests[0].url.toString(),
      'https://api.openai.com/v1/chat/completions',
    );
    expect(requests[0].headers['authorization'], 'Bearer sk-openai');
    final second = jsonDecode(requests[1].body) as Map<String, dynamic>;
    final messages = second['messages'] as List;
    expect(messages.first['role'], 'system');
    final assistant = messages[2] as Map<String, dynamic>;
    expect(assistant.containsKey('annotations'), isFalse);
    expect(assistant['tool_calls'][0]['id'], 'call_1');
    expect(messages[3]['role'], 'tool');
    expect(messages[3]['tool_call_id'], 'call_1');
    expect(ssh.commands, ['uptime']);
    expect(agent.items.last.text, '負載很低。');
  });
}
