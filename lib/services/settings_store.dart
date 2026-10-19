import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_storage.dart';

enum AiProvider { openai, anthropic }

enum TerminalCursorStyle { block, underline, bar }

/// SFTP 長按選單中的自訂指令；`{path}`、`{name}`、`{dir}` 會換成實際值。
class SftpCommand {
  const SftpCommand({required this.name, required this.command});

  factory SftpCommand.fromJson(Map<String, dynamic> json) => SftpCommand(
    name: json['name'] as String? ?? '',
    command: json['command'] as String? ?? '',
  );

  final String name;
  final String command;

  Map<String, dynamic> toJson() => {'name': name, 'command': command};
}

/// 主題色選項。
const accentColors = <String, Color>{
  '翠綠': Color(0xFF0B6B3A),
  '海藍': Color(0xFF1565C0),
  '靛紫': Color(0xFF5E35B1),
  '琥珀': Color(0xFFE65100),
  '玫紅': Color(0xFFC2185B),
  '青色': Color(0xFF00838F),
  '石墨': Color(0xFF455A64),
};

/// 全 App 的偏好設定。
class SettingsStore extends ChangeNotifier {
  SettingsStore({FlutterSecureStorage? storage})
    : _secureStorage = storage ?? secureStorage;

  static const _key = 'mato.settings.v1';
  static const _aiKeySecret = 'mato.ai.apiKey';

  final FlutterSecureStorage _secureStorage;
  Map<String, dynamic> _values = {};
  String _aiApiKey = '';
  bool _loaded = false;

  bool get loaded => _loaded;

  Future<void> load() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_key);
    if (raw != null) {
      try {
        _values = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        _values = {};
      }
    }
    try {
      _aiApiKey = await _secureStorage.read(key: _aiKeySecret) ?? '';
    } catch (error) {
      // 例如 Linux 沒有可用的金鑰圈：AI 金鑰讀不到，但 App 仍要能開啟。
      debugPrint('無法讀取安全儲存區：$error');
    }
    _loaded = true;
    notifyListeners();
  }

  Map<String, dynamic> exportValues() => Map.of(_values);

  Future<void> importValues(Map<String, dynamic> values) async {
    _values = {..._values, ...values};
    await _persist();
  }

  T _get<T>(String key, T fallback) {
    final value = _values[key];
    return value is T ? value : fallback;
  }

  Future<void> _set(String key, Object? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    await _persist();
  }

  Future<void> _persist() async {
    notifyListeners();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key, jsonEncode(_values));
  }

  // 外觀 ----------------------------------------------------------------------

  ThemeMode get themeMode =>
      ThemeMode.values.asNameMap()[_get('themeMode', 'system')] ??
      ThemeMode.system;
  set themeMode(ThemeMode value) => _set('themeMode', value.name);

  Color get accentColor => Color(_get('accent', 0xFF0B6B3A));
  set accentColor(Color value) => _set('accent', value.toARGB32());

  // 終端機 --------------------------------------------------------------------

  double get terminalFontSize => _get<num>('termFontSize', 14).toDouble();
  set terminalFontSize(double value) =>
      _set('termFontSize', value.clamp(8, 32));

  /// 空字串代表使用系統等寬字型。
  String get terminalFontFamily => _get('termFont', '');
  set terminalFontFamily(String value) => _set('termFont', value.trim());

  String get terminalTheme => _get('termTheme', 'mato');
  set terminalTheme(String value) => _set('termTheme', value);

  TerminalCursorStyle get terminalCursor =>
      TerminalCursorStyle.values.asNameMap()[_get('termCursor', 'block')] ??
      TerminalCursorStyle.block;
  set terminalCursor(TerminalCursorStyle value) =>
      _set('termCursor', value.name);

  /// `null` 代表自動（行動裝置顯示、桌面隱藏）。
  bool? get extraKeysOverride => _values['extraKeys'] as bool?;
  set extraKeysOverride(bool? value) => _set('extraKeys', value);

  int get terminalScrollback => _get('termScrollback', 5000);
  set terminalScrollback(int value) => _set('termScrollback', value);

  /// 按下特殊鍵列時給予觸覺回饋（震動）。
  bool get keyHaptics => _get('keyHaptics', true);
  set keyHaptics(bool value) => _set('keyHaptics', value);

  // 監控 ----------------------------------------------------------------------

  int get monitorInterval => _get('monitorInterval', 3);
  set monitorInterval(int value) => _set('monitorInterval', value.clamp(2, 60));

  bool get dashboardLive => _get('dashboardLive', true);
  set dashboardLive(bool value) => _set('dashboardLive', value);

  bool get showTemperature => _get('showTemperature', true);
  set showTemperature(bool value) => _set('showTemperature', value);

  // 安全 ----------------------------------------------------------------------

  bool get appLock => _get('appLock', false);
  set appLock(bool value) => _set('appLock', value);

  /// 回到前景時超過幾秒才需要重新解鎖。
  int get appLockDelay => _get('appLockDelay', 0);
  set appLockDelay(int value) => _set('appLockDelay', value);

  // SFTP ----------------------------------------------------------------------

  bool get sftpShowHidden => _get('sftpHidden', false);
  set sftpShowHidden(bool value) => _set('sftpHidden', value);

  String get sftpSort => _get('sftpSort', 'name');
  set sftpSort(String value) => _set('sftpSort', value);

  bool get sftpSortDescending => _get('sftpSortDesc', false);
  set sftpSortDescending(bool value) => _set('sftpSortDesc', value);

  List<SftpCommand> get sftpCommands {
    final raw = _values['sftpCommands'];
    if (raw is! List) return defaultSftpCommands;
    return raw
        .whereType<Map>()
        .map((item) => SftpCommand.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  set sftpCommands(List<SftpCommand> value) =>
      _set('sftpCommands', value.map((item) => item.toJson()).toList());

  static const defaultSftpCommands = [
    SftpCommand(name: '解壓縮 (tar)', command: 'cd {dir} && tar -xf {name}'),
    SftpCommand(name: '解壓縮 (zip)', command: 'cd {dir} && unzip -o {name}'),
    SftpCommand(name: '查看最後 100 行', command: 'tail -n 100 {path}'),
    SftpCommand(name: '計算資料夾大小', command: 'du -sh {path}'),
  ];

  // AI 助理 -------------------------------------------------------------------

  AiProvider get aiProvider =>
      AiProvider.values.asNameMap()[_get('aiProvider', 'anthropic')] ??
      AiProvider.anthropic;
  set aiProvider(AiProvider value) => _set('aiProvider', value.name);

  /// 空字串代表該供應商的官方端點。
  String get aiBaseUrl => _get('aiBaseUrl', '');
  set aiBaseUrl(String value) => _set('aiBaseUrl', value.trim());

  String get aiModel => _get('aiModel', '');
  set aiModel(String value) => _set('aiModel', value.trim());

  String get aiApiKey => _aiApiKey;
  Future<void> setAiApiKey(String value) async {
    _aiApiKey = value.trim();
    if (_aiApiKey.isEmpty) {
      await _secureStorage.delete(key: _aiKeySecret);
    } else {
      await _secureStorage.write(key: _aiKeySecret, value: _aiApiKey);
    }
    notifyListeners();
  }

  /// Claude 的思考深度（`output_config.effort`）：low／medium／high／xhigh。
  String get aiEffort => _get('aiEffort', 'medium');
  set aiEffort(String value) => _set('aiEffort', value);

  /// 唯讀工具（讀檔、列目錄、查指標）不必逐一確認。
  bool get aiAutoApproveReads => _get('aiAutoReads', true);
  set aiAutoApproveReads(bool value) => _set('aiAutoReads', value);

  /// 執行指令／寫檔也不必確認（風險較高）。
  bool get aiAutoApproveAll => _get('aiAutoAll', false);
  set aiAutoApproveAll(bool value) => _set('aiAutoAll', value);

  bool get aiConfigured => _aiApiKey.isNotEmpty || aiBaseUrl.isNotEmpty;

  // 其他 ----------------------------------------------------------------------

  /// 是否已經放過範例腳本（只放一次，使用者刪掉就不再出現）。
  bool get seededScripts => _get('seededScripts', false);
  set seededScripts(bool value) => _set('seededScripts', value);
}
