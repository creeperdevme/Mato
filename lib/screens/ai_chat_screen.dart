import 'dart:convert';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/ai_service.dart';
import '../services/settings_store.dart';
import '../widgets/common.dart';
import 'settings_screen.dart';

/// 伺服器的 AI 助理（使用者自備 API 金鑰）。
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key, required this.profile, this.draft});

  final ServerProfile profile;

  /// 其他分頁（例如終端機）丟過來的草稿。
  final ValueNotifier<String?>? draft;

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final List<AiImage> _images = [];
  late final AiAgent _agent;
  int _lastCount = 0;

  static const _suggestions = [
    '幫我檢查這台伺服器的健康狀況',
    '找出最占磁碟空間的目錄',
    '看看最近有沒有錯誤日誌',
    '列出正在監聽的連接埠與對應服務',
  ];

  @override
  void initState() {
    super.initState();
    _agent = context.read<AiHub>().agentFor(widget.profile.id)
      ..addListener(_onAgentChanged);
    widget.draft?.addListener(_takeDraft);
    _takeDraft();
  }

  @override
  void dispose() {
    _agent.removeListener(_onAgentChanged);
    widget.draft?.removeListener(_takeDraft);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _takeDraft() {
    final value = widget.draft?.value;
    if (value == null) return;
    widget.draft!.value = null;
    _input.text = value;
    _input.selection = TextSelection.collapsed(offset: value.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _onAgentChanged() {
    if (!mounted) return;
    setState(() {});
    if (_agent.items.length != _lastCount) {
      _lastCount = _agent.items.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Future<void> _send([String? text]) async {
    final message = (text ?? _input.text).trim();
    if (message.isEmpty && _images.isEmpty) return;
    final images = List.of(_images);
    _input.clear();
    setState(_images.clear);
    await _agent.send(message, images: images);
  }

  Future<void> _attach() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: '選擇圖片',
      type: FileType.image,
    );
    for (final file in files) {
      final size = await file.length() ?? 0;
      if (size > 4 * 1024 * 1024) {
        if (mounted) {
          showMessage(context, '${file.name} 超過 4 MB，已略過', error: true);
        }
        continue;
      }
      final bytes = await file.readAsBytes();
      final name = file.name.toLowerCase();
      final type = name.endsWith('.png')
          ? 'image/png'
          : name.endsWith('.gif')
          ? 'image/gif'
          : name.endsWith('.webp')
          ? 'image/webp'
          : 'image/jpeg';
      setState(
        () => _images.add(
          AiImage(mediaType: type, base64Data: base64.encode(bytes)),
        ),
      );
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AiSettingsScreen()));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!settings.aiConfigured) {
      return EmptyState(
        icon: Icons.auto_awesome_rounded,
        title: '設定 AI 助理',
        message:
            '使用你自己的 Anthropic（Claude）或 OpenAI 相容 API 金鑰。'
            'AI 可以讀取監控指標、執行指令、讀寫檔案，伺服器端不需安裝任何東西；'
            '會修改系統的操作都要你核准。',
        action: FilledButton.icon(
          onPressed: _openSettings,
          icon: const Icon(Icons.key_rounded),
          label: const Text('前往設定'),
        ),
      );
    }

    final items = _agent.items;
    final model = settings.aiModel.isNotEmpty
        ? settings.aiModel
        : settings.aiProvider == AiProvider.anthropic
        ? defaultAnthropicModel
        : defaultOpenAiModel;

    return Column(
      children: [
        Material(
          color: scheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    model,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                FilterChip(
                  avatar: const Icon(Icons.checklist_rounded, size: 16),
                  label: const Text('計畫模式'),
                  tooltip: '只調查並提出計畫，不執行任何變更',
                  selected: _agent.planMode,
                  onSelected: (value) =>
                      setState(() => _agent.planMode = value),
                ),
                IconButton(
                  tooltip: 'AI 設定',
                  onPressed: _openSettings,
                  icon: const Icon(Icons.tune_rounded),
                ),
                IconButton(
                  tooltip: '清除對話',
                  onPressed: items.isEmpty
                      ? null
                      : () async {
                          final ok = await confirmAction(
                            context,
                            title: '清除對話',
                            message: '會刪除這台伺服器的 AI 對話紀錄。',
                            confirmLabel: '清除',
                          );
                          if (ok) await _agent.clear();
                        },
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? _Welcome(suggestions: _suggestions, onTap: _send)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  itemCount: items.length + (_agent.busy ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == items.length) return const _Thinking();
                    final item = items[index];
                    return ReadableWidth(
                      maxWidth: 900,
                      child: switch (item.kind) {
                        AiItemKind.user => _UserBubble(item: item),
                        AiItemKind.assistant => _AssistantMessage(
                          text: item.text,
                        ),
                        AiItemKind.progress => _ProgressNote(text: item.text),
                        AiItemKind.tool => _ToolCard(
                          item: item,
                          pending: identical(item, _agent.pendingApproval),
                          onApprove: () => _agent.resolveApproval(true),
                          onDeny: () => _agent.resolveApproval(false),
                        ),
                        AiItemKind.notice => _Notice(item: item),
                      },
                    );
                  },
                ),
        ),
        if (_agent.planMode && !_agent.busy && items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: TextButton.icon(
              onPressed: () {
                setState(() => _agent.planMode = false);
                _send('計畫已核准，請依照計畫逐步執行，每個會變更系統的步驟我會在 App 中確認。');
              },
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('核准計畫並開始執行'),
            ),
          ),
        _Composer(
          controller: _input,
          focusNode: _focus,
          images: _images,
          busy: _agent.busy,
          onSend: _send,
          onStop: _agent.stop,
          onAttach: _attach,
          onRemoveImage: (image) => setState(() => _images.remove(image)),
        ),
      ],
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.suggestions, required this.onTap});

  final List<String> suggestions;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                size: 44,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                '有什麼想讓我幫忙的？',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '我會先調查再行動；任何會修改系統的指令都會先請你核准。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  for (final suggestion in suggestions)
                    ActionChip(
                      label: Text(suggestion),
                      onPressed: () => onTap(suggestion),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.item});

  final AiChatItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 48, bottom: 10, top: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(18)
              .copyWith(bottomRight: const Radius.circular(4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (item.images.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final image in item.images)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(
                        image.bytes,
                        width: 120,
                        height: 90,
                        fit: BoxFit.cover,
                      ),
                    ),
                ],
              ),
            if (item.text.isNotEmpty)
              SelectableText(
                item.text,
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
          ],
        ),
      ),
    );
  }
}

/// 助理回覆：把 ``` 程式碼區塊另外框起來並提供複製。
class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final parts = <Widget>[];
    final pattern = RegExp(r'```([\w+-]*)\n?([\s\S]*?)```');
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      final before = text.substring(cursor, match.start).trim();
      if (before.isNotEmpty) parts.add(_Prose(text: before));
      parts.add(
        _CodeBlock(language: match.group(1) ?? '', code: match.group(2) ?? ''),
      );
      cursor = match.end;
    }
    final rest = text.substring(cursor).trim();
    if (rest.isNotEmpty) parts.add(_Prose(text: rest));

    return Padding(
      padding: const EdgeInsets.only(bottom: 10, right: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: scheme.tertiaryContainer,
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 15,
              color: scheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < parts.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  parts[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Prose extends StatelessWidget {
  const _Prose({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 簡單處理 Markdown：行內 `code` 用等寬字型，**粗體** 加粗。
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'(`[^`\n]+`|\*\*[^*\n]+\*\*)');
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('`')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: monoStyle(fontSize: 13, color: theme.colorScheme.primary),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      }
      cursor = match.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return SelectableText.rich(
      TextSpan(
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
        children: spans,
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.language, required this.code});

  final String language;
  final String code;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF101614),
        borderRadius: BorderRadius.circular(12),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                Text(
                  language.isEmpty ? 'code' : language,
                  style: monoStyle(
                    fontSize: 11,
                    color: const Color(0xFF8FA39A),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '複製',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  color: const Color(0xFF8FA39A),
                  onPressed: () =>
                      copyText(context, code.trimRight(), label: '程式碼'),
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SelectableText(
              code.trimRight(),
              style: monoStyle(fontSize: 12.5, color: const Color(0xFFD8E3DC)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressNote extends StatelessWidget {
  const _ProgressNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 38, bottom: 8, right: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.subdirectory_arrow_right_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.item,
    required this.pending,
    required this.onApprove,
    required this.onDeny,
  });

  final AiChatItem item;
  final bool pending;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final input = item.toolInput ?? const {};
    final (icon, title, detail) = switch (item.toolName) {
      'run_command' => (
        Icons.terminal_rounded,
        input['sudo'] == true ? '執行指令（sudo）' : '執行指令',
        '${input['command'] ?? ''}',
      ),
      'read_file' => (
        Icons.description_outlined,
        '讀取檔案',
        '${input['path'] ?? ''}',
      ),
      'write_file' => (Icons.edit_document, '寫入檔案', '${input['path'] ?? ''}'),
      'list_directory' => (
        Icons.folder_open_outlined,
        '列出目錄',
        '${input['path'] ?? ''}',
      ),
      'get_server_metrics' => (Icons.insights_rounded, '讀取系統指標', ''),
      _ => (Icons.build_outlined, item.toolName ?? '工具', jsonEncode(input)),
    };
    final status = item.toolStatus;
    final (statusLabel, statusColor) = switch (status) {
      AiToolStatus.awaitingApproval => ('等待核准', const Color(0xFFF9A825)),
      AiToolStatus.running => ('執行中', scheme.primary),
      AiToolStatus.done => ('完成', const Color(0xFF2E7D32)),
      AiToolStatus.denied => ('未執行', scheme.outline),
      AiToolStatus.failed => ('失敗', scheme.error),
      null => ('', scheme.outline),
    };
    final reason = input['reason'];
    final content = item.toolName == 'write_file'
        ? input['content'] as String?
        : null;

    return Padding(
      padding: const EdgeInsets.only(left: 38, bottom: 10, right: 8),
      child: SurfaceCard(
        padding: EdgeInsets.zero,
        borderColor: pending ? const Color(0xFFF9A825) : null,
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: pending,
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: const EdgeInsets.symmetric(horizontal: 14),
            leading: Icon(icon, size: 20, color: scheme.primary),
            title: Row(
              children: [
                Text(title, style: theme.textTheme.labelLarge),
                const SizedBox(width: 8),
                if (status == AiToolStatus.running)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                else if (statusLabel.isNotEmpty)
                  TagChip(label: statusLabel, color: statusColor),
              ],
            ),
            subtitle: detail.isEmpty
                ? null
                : Text(
                    detail,
                    maxLines: pending ? 8 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(fontSize: 12),
                  ),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (reason is String && reason.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(reason, style: theme.textTheme.bodySmall),
                ),
              if (content != null)
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      content,
                      style: monoStyle(fontSize: 12),
                    ),
                  ),
                ),
              if (pending)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(onPressed: onDeny, child: const Text('拒絕')),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: onApprove,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('允許執行'),
                    ),
                  ],
                ),
              if (item.toolOutput != null && item.toolOutput!.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 280),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101614),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      item.toolOutput!,
                      style: monoStyle(
                        fontSize: 11.5,
                        color: const Color(0xFFD8E3DC),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.item});

  final AiChatItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = item.isError
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            item.isError
                ? Icons.error_outline_rounded
                : Icons.info_outline_rounded,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              item.text,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 38, top: 4, bottom: 12),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            '思考中…',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.images,
    required this.busy,
    required this.onSend,
    required this.onStop,
    required this.onAttach,
    required this.onRemoveImage,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<AiImage> images;
  final bool busy;
  final Future<void> Function([String? text]) onSend;
  final VoidCallback onStop;
  final VoidCallback onAttach;
  final ValueChanged<AiImage> onRemoveImage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: ReadableWidth(
            maxWidth: 900,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (images.isNotEmpty)
                  SizedBox(
                    height: 64,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final image in images)
                          Padding(
                            padding: const EdgeInsets.only(right: 8, bottom: 6),
                            child: Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(
                                    image.bytes,
                                    width: 72,
                                    height: 58,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                Positioned(
                                  top: 0,
                                  right: 0,
                                  child: InkWell(
                                    onTap: () => onRemoveImage(image),
                                    child: const CircleAvatar(
                                      radius: 10,
                                      child: Icon(
                                        Icons.close_rounded,
                                        size: 14,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: '附加圖片',
                      onPressed: busy ? null : onAttach,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                    ),
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(
                            LogicalKeyboardKey.enter,
                            control: true,
                          ): () =>
                              onSend(),
                          const SingleActivator(
                            LogicalKeyboardKey.enter,
                            meta: true,
                          ): () =>
                              onSend(),
                        },
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          minLines: 1,
                          maxLines: 6,
                          textInputAction: TextInputAction.newline,
                          decoration: InputDecoration(
                            hintText:
                                Platform.isWindows ||
                                    Platform.isLinux ||
                                    Platform.isMacOS
                                ? '描述你想做的事（Ctrl+Enter 送出）'
                                : '描述你想做的事',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (busy)
                      IconButton.filledTonal(
                        tooltip: '停止',
                        onPressed: onStop,
                        icon: const Icon(Icons.stop_rounded),
                      )
                    else
                      IconButton.filled(
                        tooltip: '送出',
                        onPressed: () => onSend(),
                        icon: const Icon(Icons.arrow_upward_rounded),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
