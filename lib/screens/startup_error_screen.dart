import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app_theme.dart';
import '../build_info.dart';
import '../services/settings_store.dart';
import '../widgets/common.dart';

/// 啟動時讀不到本機資料（外掛例外或逾時）改顯示這個 App，而不是一直停在
/// 啟動畫面。設定也還沒讀到，所以一律使用預設主題色。
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({
    super.key,
    required this.error,
    required this.stackTrace,
    required this.onRetry,
  });

  final Object error;
  final StackTrace stackTrace;

  /// 重新啟動；成功時整個 App 會被換掉，失敗則換上新的錯誤內容。
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mato',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(defaultAccentColor, Brightness.light),
      darkTheme: buildTheme(defaultAccentColor, Brightness.dark),
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: _StartupErrorScreen(
        error: error,
        stackTrace: stackTrace,
        onRetry: onRetry,
      ),
    );
  }
}

class _StartupErrorScreen extends StatefulWidget {
  const _StartupErrorScreen({
    required this.error,
    required this.stackTrace,
    required this.onRetry,
  });

  final Object error;
  final StackTrace stackTrace;
  final Future<void> Function() onRetry;

  @override
  State<_StartupErrorScreen> createState() => _StartupErrorScreenState();
}

class _StartupErrorScreenState extends State<_StartupErrorScreen> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: EmptyState(
          icon: Icons.error_outline_rounded,
          error: true,
          title: 'Mato 無法啟動',
          message: '讀取本機資料時發生錯誤。可以先重試；如果一直發生，請複製錯誤訊息回報。',
          action: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _retrying ? null : _retry,
                    icon: _retrying
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    label: const Text('重試'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => copyText(
                      context,
                      'Mato ${BuildInfo.describe}\n'
                      '${widget.error}\n\n${widget.stackTrace}',
                      label: '錯誤訊息',
                    ),
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('複製錯誤訊息'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // 外掛的例外常夾帶整段 Java 堆疊，這裡只列開頭；完整內容用複製取得。
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${widget.error}',
                  maxLines: 10,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
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
