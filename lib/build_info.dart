/// 建置資訊，由 CI 以 `--dart-define` 帶入（本機開發時為預設值）。
abstract final class BuildInfo {
  static const version = String.fromEnvironment(
    'MATO_VERSION',
    defaultValue: '1.0.0',
  );
  static const channel = String.fromEnvironment(
    'MATO_CHANNEL',
    defaultValue: 'dev',
  );
  static const commit = String.fromEnvironment('MATO_COMMIT');
  static const date = String.fromEnvironment('MATO_BUILD_DATE');

  /// 例：`1.0.0 nightly · a1b2c3d · 2026-10-19`。
  static String get describe {
    final parts = <String>['$version $channel'];
    if (commit.isNotEmpty) {
      parts.add(commit.length > 7 ? commit.substring(0, 7) : commit);
    }
    if (date.isNotEmpty) parts.add(date);
    return parts.join(' · ');
  }
}
