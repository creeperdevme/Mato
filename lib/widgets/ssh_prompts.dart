import 'package:flutter/material.dart';

import '../services/ssh_service.dart';
import '../utils/format.dart';
import 'common.dart';

/// 主機金鑰與上次記錄不同：讓使用者決定是否信任新的金鑰。
Future<bool> showHostKeyDialog(
  BuildContext context,
  HostKeyChallenge challenge,
) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final scheme = theme.colorScheme;
      return AlertDialog(
        icon: Icon(Icons.gpp_maybe_rounded, color: scheme.error, size: 32),
        title: const Text('主機金鑰已變更'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${challenge.host}:${challenge.port} 提供的主機金鑰與上次記錄不同。'
                '如果伺服器沒有重灌或更換金鑰，這可能是中間人攻擊。',
              ),
              const SizedBox(height: 16),
              _Fingerprint(
                label: '先前（${formatDateTime(challenge.previous.addedAt)} 記錄）',
                type: challenge.previous.type,
                value: challenge.previous.fingerprint,
              ),
              const SizedBox(height: 10),
              _Fingerprint(
                label: '這次',
                type: challenge.type,
                value: challenge.fingerprint,
                highlight: true,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('中止連線'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('信任新金鑰'),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

class _Fingerprint extends StatelessWidget {
  const _Fingerprint({
    required this.label,
    required this.type,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String type;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: highlight
            ? scheme.errorContainer.withValues(alpha: 0.4)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label · $type', style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          SelectableText(value, style: monoStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

/// keyboard-interactive（例如 2FA 驗證碼、未儲存的密碼）。
Future<List<String>?> showInteractiveAuthDialog(
  BuildContext context,
  InteractiveChallenge challenge,
) {
  return showDialog<List<String>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _InteractiveAuthDialog(challenge: challenge),
  );
}

class _InteractiveAuthDialog extends StatefulWidget {
  const _InteractiveAuthDialog({required this.challenge});

  final InteractiveChallenge challenge;

  @override
  State<_InteractiveAuthDialog> createState() => _InteractiveAuthDialogState();
}

class _InteractiveAuthDialogState extends State<_InteractiveAuthDialog> {
  late final List<TextEditingController> _controllers = [
    for (final _ in widget.challenge.prompts) TextEditingController(),
  ];

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    Navigator.pop(context, [
      for (final controller in _controllers) controller.text,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final challenge = widget.challenge;
    final theme = Theme.of(context);
    return AlertDialog(
      icon: const Icon(Icons.verified_user_outlined, size: 30),
      title: Text(challenge.title),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              challenge.serverName,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (challenge.instruction.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(challenge.instruction.trim()),
            ],
            const SizedBox(height: 14),
            for (var i = 0; i < challenge.prompts.length; i++) ...[
              if (i > 0) const SizedBox(height: 12),
              TextField(
                controller: _controllers[i],
                autofocus: i == 0,
                obscureText: !challenge.prompts[i].echo,
                decoration: InputDecoration(
                  labelText: challenge.prompts[i].promptText.trim().replaceAll(
                    RegExp(r':\s*$'),
                    '',
                  ),
                ),
                onSubmitted: (_) {
                  if (i == challenge.prompts.length - 1) _submit();
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('送出')),
      ],
    );
  }
}
