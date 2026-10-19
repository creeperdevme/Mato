import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/server_profile.dart';

/// 等寬字型清單：各平台常見的程式字型，最後補上繁中字型避免中文變成方框或
/// 簡體字形。
const monoFonts = [
  'Cascadia Mono',
  'Consolas',
  'SF Mono',
  'Menlo',
  'JetBrains Mono',
  'Roboto Mono',
  'Ubuntu Mono',
  'DejaVu Sans Mono',
  'Noto Sans Mono',
  'monospace',
  'Microsoft JhengHei UI',
  'PingFang TC',
  'Noto Sans Mono CJK TC',
  'Noto Sans CJK TC',
];

TextStyle monoStyle({double? fontSize, Color? color, FontWeight? weight}) =>
    TextStyle(
      fontFamily: monoFonts.first,
      fontFamilyFallback: monoFonts.sublist(1),
      fontSize: fontSize,
      color: color,
      fontWeight: weight,
      height: 1.4,
    );

/// 統一樣式的卡片外框（圓角＋淡邊框，避免 M3 預設陰影在深色模式下過重）。
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.onLongPress,
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(20);
    final content = Padding(
      padding: padding ?? const EdgeInsets.all(16),
      child: child,
    );

    return Material(
      color: color ?? scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: borderColor ?? scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null && onLongPress == null
          ? content
          : InkWell(onTap: onTap, onLongPress: onLongPress, child: content),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.caption,
    this.trailing = const [],
    this.padding = EdgeInsets.zero,
  });

  final String title;
  final String? caption;
  final List<Widget> trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          // 標題與說明放在同一個 Expanded 內，避免和右側按鈕爭奪剩餘空間。
          Expanded(
            child: Row(
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (caption != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      caption!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// 空白／錯誤狀態的置中提示。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.error = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color:
                      (error ? scheme.errorContainer : scheme.primaryContainer)
                          .withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 34,
                  color: error ? scheme.error : scheme.primary,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// 把內容限制在可讀寬度內並置中（桌面大視窗用）。
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({super.key, required this.child, this.maxWidth = 860});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

class StatusDot extends StatefulWidget {
  const StatusDot({
    super.key,
    required this.color,
    this.animate = false,
    this.size = 8,
  });

  final Color color;
  final bool animate;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.animate) _start();
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && _controller == null) {
      _start();
    } else if (!widget.animate && _controller != null) {
      _controller!.dispose();
      _controller = null;
    }
  }

  void _start() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    final controller = _controller;
    if (controller == null) return dot;
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.45,
        end: 1,
      ).animate(CurvedAnimation(parent: controller, curve: Curves.easeInOut)),
      child: dot,
    );
  }
}

String statusLabel(ServerStatus status) {
  switch (status) {
    case ServerStatus.online:
      return '線上';
    case ServerStatus.checking:
      return '連線中';
    case ServerStatus.offline:
      return '離線';
    case ServerStatus.authFailed:
      return '驗證失敗';
    case ServerStatus.error:
      return '錯誤';
    case ServerStatus.unknown:
      return '未連線';
  }
}

Color statusColor(ServerStatus status, ThemeData theme) {
  final dark = theme.brightness == Brightness.dark;
  switch (status) {
    case ServerStatus.online:
      return dark ? const Color(0xFF7EE2A8) : const Color(0xFF146C2E);
    case ServerStatus.checking:
      return dark ? const Color(0xFF9EC6FF) : const Color(0xFF11468F);
    case ServerStatus.authFailed:
      return dark ? const Color(0xFFFFC470) : const Color(0xFF8A4B00);
    case ServerStatus.offline:
    case ServerStatus.error:
      return dark ? const Color(0xFFFF9E9E) : const Color(0xFFB3261E);
    case ServerStatus.unknown:
      return theme.colorScheme.onSurfaceVariant;
  }
}

/// 各項指標固定使用的顏色（首頁卡片與總覽頁一致，不隨主題色變動）。
abstract final class MetricColors {
  static const cpu = Color(0xFF10B981);
  static const memory = Color(0xFF3B82F6);
  static const disk = Color(0xFFA855F7);
  static const gpu = Color(0xFFEC4899);
  static const rx = Color(0xFF10B981);
  static const tx = Color(0xFFF59E0B);
}

/// 使用率的警示色：一般／偏高（≥75%）／過高（≥90%）。
Color usageColor(double percent, Color base) {
  if (percent >= 90) return const Color(0xFFE53935);
  if (percent >= 75) return const Color(0xFFF57C00);
  return base;
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status, this.message = ''});

  final ServerStatus status;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = statusColor(status, theme);
    return Tooltip(
      message: message.isEmpty ? statusLabel(status) : message,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(color: color, animate: status == ServerStatus.online),
            const SizedBox(width: 6),
            Text(
              statusLabel(status),
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 小型標籤（例如「tmux」「sudo」）。
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, this.icon, this.color});

  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: tone),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: tone,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

void showMessage(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? scheme.error : null,
      ),
    );
}

Future<void> copyText(
  BuildContext context,
  String text, {
  String? label,
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showMessage(context, '已複製${label ?? ''}');
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  String confirmLabel = '確定',
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: content ?? (message == null ? null : Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 輸入一行（或多行）文字的對話框；取消時回傳 null。
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? label,
  String initial = '',
  String? hint,
  String confirmLabel = '確定',
  bool obscure = false,
  bool multiline = false,
  bool monospace = false,
  TextInputType? keyboardType,
  String? Function(String value)? validator,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => _PromptDialog(
      title: title,
      label: label,
      initial: initial,
      hint: hint,
      confirmLabel: confirmLabel,
      obscure: obscure,
      multiline: multiline,
      monospace: monospace,
      keyboardType: keyboardType,
      validator: validator,
    ),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.hint,
    required this.confirmLabel,
    required this.obscure,
    required this.multiline,
    required this.monospace,
    required this.keyboardType,
    required this.validator,
  });

  final String title;
  final String? label;
  final String initial;
  final String? hint;
  final String confirmLabel;
  final bool obscure;
  final bool multiline;
  final bool monospace;
  final TextInputType? keyboardType;
  final String? Function(String value)? validator;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.initial.length,
        );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text;
    final error = widget.validator?.call(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: widget.multiline ? 560 : 400,
        child: TextField(
          controller: _controller,
          autofocus: true,
          obscureText: widget.obscure,
          keyboardType:
              widget.keyboardType ??
              (widget.multiline ? TextInputType.multiline : null),
          minLines: widget.multiline ? 4 : 1,
          maxLines: widget.multiline ? 12 : 1,
          style: widget.monospace ? monoStyle(fontSize: 13) : null,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            errorText: _error,
          ),
          onSubmitted: widget.multiline ? null : (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// 進度對話框：執行 [task] 期間顯示，完成後自動關閉並回傳結果。
Future<T> runWithProgress<T>(
  BuildContext context,
  String message,
  Future<T> Function() task,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 18),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  );
  try {
    return await task();
  } finally {
    navigator.pop();
  }
}

/// 顯示一段（可能很長的）文字輸出，例如指令結果、日誌。
Future<void> showTextOutput(
  BuildContext context, {
  required String title,
  required String text,
  List<Widget> actions = const [],
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        content: SizedBox(
          width: 720,
          height: 460,
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Scrollbar(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  text.isEmpty ? '（沒有輸出）' : text,
                  style: monoStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        ),
        actions: [
          ...actions,
          TextButton(
            onPressed: () => copyText(dialogContext, text, label: '輸出'),
            child: const Text('複製'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('關閉'),
          ),
        ],
      );
    },
  );
}

/// 寬螢幕判斷（平板橫向、桌面）。
bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 900;
