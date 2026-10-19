import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_lock.dart';

/// App 鎖：鎖定時蓋在整個 App 上方，解鎖前看不到任何伺服器資訊。
class AppLockGate extends StatelessWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final locked = context.watch<AppLockService>().locked;
    return Stack(
      children: [
        // 鎖定時把底下的內容排除在無障礙樹與點擊之外。
        ExcludeSemantics(
          excluding: locked,
          child: IgnorePointer(ignoring: locked, child: child),
        ),
        if (locked) const Positioned.fill(child: _LockScreen()),
      ],
    );
  }
}

class _LockScreen extends StatefulWidget {
  const _LockScreen();

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  bool _prompted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 一出現就自動跳出系統驗證，使用者不必再按一次。
    if (!_prompted) {
      _prompted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<AppLockService>().unlock();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lock = context.watch<AppLockService>();

    return Material(
      color: scheme.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Icon(
                    Icons.lock_rounded,
                    size: 42,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Mato 已鎖定',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '請用生物辨識或裝置密碼解鎖',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (lock.lastError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    lock.lastError!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: lock.unlock,
                  icon: const Icon(Icons.fingerprint_rounded),
                  label: const Text('解鎖'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
