import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../build_info.dart';
import '../models/server_profile.dart';
import '../services/ai_service.dart';
import '../services/app_lock.dart';
import '../services/backup_service.dart';
import '../services/home_widget_service.dart';
import '../services/known_hosts_store.dart';
import '../services/server_store.dart';
import '../services/settings_store.dart';
import '../utils/format.dart';
import '../widgets/common.dart';
import '../widgets/mato_logo.dart';
import '../widgets/terminal_themes.dart';
import 'keys_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          ReadableWidth(
            maxWidth: 760,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Group('外觀'),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('主題', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 8),
                      SegmentedButton<ThemeMode>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('跟隨系統'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text('淺色'),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text('深色'),
                          ),
                        ],
                        selected: {settings.themeMode},
                        onSelectionChanged: (value) =>
                            settings.themeMode = value.first,
                      ),
                      const SizedBox(height: 16),
                      Text('主題色', style: theme.textTheme.labelLarge),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          for (final entry in accentColors.entries)
                            Tooltip(
                              message: entry.key,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => settings.accentColor = entry.value,
                                child: Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: entry.value,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      width: 3,
                                      color:
                                          settings.accentColor.toARGB32() ==
                                              entry.value.toARGB32()
                                          ? theme.colorScheme.onSurface
                                          : Colors.transparent,
                                    ),
                                  ),
                                  child:
                                      settings.accentColor.toARGB32() ==
                                          entry.value.toARGB32()
                                      ? const Icon(
                                          Icons.check_rounded,
                                          color: Colors.white,
                                          size: 20,
                                        )
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const _Group('終端機'),
                const _TerminalSettings(),
                const _Group('監控'),
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.timer_outlined),
                        title: const Text('更新間隔'),
                        trailing: DropdownButton<int>(
                          value: settings.monitorInterval,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (final value in const [2, 3, 5, 10, 30])
                              DropdownMenuItem(
                                value: value,
                                child: Text('$value 秒'),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) settings.monitorInterval = value;
                          },
                        ),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.dashboard_outlined),
                        value: settings.dashboardLive,
                        onChanged: (value) => settings.dashboardLive = value,
                        title: const Text('首頁即時監控'),
                        subtitle: const Text('在伺服器清單上持續更新 CPU、記憶體與網路'),
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.thermostat_rounded),
                        value: settings.showTemperature,
                        onChanged: (value) => settings.showTemperature = value,
                        title: const Text('顯示溫度'),
                      ),
                    ],
                  ),
                ),
                if (context.read<HomeWidgetService?>()?.supported ?? false) ...[
                  const _Group('主畫面小工具'),
                  const _HomeWidgetSettings(),
                ],
                const _Group('安全'),
                const _SecuritySettings(),
                const _Group('AI 助理'),
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.auto_awesome_rounded),
                    title: const Text('AI 供應商與金鑰'),
                    subtitle: Text(
                      settings.aiConfigured
                          ? '${settings.aiProvider == AiProvider.anthropic ? 'Anthropic' : 'OpenAI 相容'} · '
                                '${settings.aiModel.isEmpty ? (settings.aiProvider == AiProvider.anthropic ? defaultAnthropicModel : defaultOpenAiModel) : settings.aiModel}'
                          : '尚未設定',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AiSettingsScreen(),
                      ),
                    ),
                  ),
                ),
                const _Group('檔案管理'),
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.playlist_add_check_rounded),
                    title: const Text('長按自訂指令'),
                    subtitle: Text('${settings.sftpCommands.length} 個指令'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SftpCommandsScreen(),
                      ),
                    ),
                  ),
                ),
                const _Group('備份與還原'),
                const _BackupSettings(),
                const _Group('關於'),
                SurfaceCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const MatoLogo(size: 36),
                        title: const Text('Mato'),
                        subtitle: Text(BuildInfo.describe),
                        onTap: () => copyText(
                          context,
                          BuildInfo.describe,
                          label: '版本資訊',
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: const Text('開放原始碼授權'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => showLicensePage(
                          context: context,
                          applicationName: 'Mato',
                          applicationVersion: BuildInfo.describe,
                          applicationIcon: const Padding(
                            padding: EdgeInsets.all(8),
                            child: MatoLogo(size: 56),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TerminalSettings extends StatelessWidget {
  const _TerminalSettings();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final palette = paletteById(settings.terminalTheme);
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(14),
            width: double.infinity,
            decoration: BoxDecoration(
              color: palette.theme.background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text.rich(
              TextSpan(
                style: monoStyle(
                  fontSize: settings.terminalFontSize,
                  color: palette.theme.foreground,
                ),
                children: [
                  TextSpan(
                    text: 'mato@server',
                    style: TextStyle(color: palette.theme.green),
                  ),
                  const TextSpan(text: ':'),
                  TextSpan(
                    text: '~/app',
                    style: TextStyle(color: palette.theme.blue),
                  ),
                  const TextSpan(text: r'$ ls --color'),
                  const TextSpan(text: '\n'),
                  TextSpan(
                    text: 'src  ',
                    style: TextStyle(color: palette.theme.blue),
                  ),
                  TextSpan(
                    text: 'deploy.sh  ',
                    style: TextStyle(color: palette.theme.green),
                  ),
                  TextSpan(
                    text: 'error.log  ',
                    style: TextStyle(color: palette.theme.red),
                  ),
                  TextSpan(
                    text: '中文 README.md',
                    style: TextStyle(color: palette.theme.yellow),
                  ),
                ],
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('配色'),
            trailing: DropdownButton<String>(
              value: palette.id,
              underline: const SizedBox.shrink(),
              items: [
                for (final item in terminalPalettes)
                  DropdownMenuItem(value: item.id, child: Text(item.name)),
              ],
              onChanged: (value) {
                if (value != null) settings.terminalTheme = value;
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.format_size_rounded),
            title: Text('字級 ${settings.terminalFontSize.round()}'),
            subtitle: Slider(
              value: settings.terminalFontSize,
              min: 9,
              max: 24,
              divisions: 15,
              label: '${settings.terminalFontSize.round()}',
              onChanged: (value) => settings.terminalFontSize = value,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.font_download_outlined),
            title: const Text('字型'),
            subtitle: Text(
              settings.terminalFontFamily.isEmpty
                  ? '系統等寬字型'
                  : settings.terminalFontFamily,
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () async {
              final value = await promptText(
                context,
                title: '終端機字型',
                label: '字型名稱',
                initial: settings.terminalFontFamily,
                hint: '例如 JetBrains Mono、Fira Code；留白使用系統字型',
              );
              if (value != null) settings.terminalFontFamily = value;
            },
          ),
          ListTile(
            leading: const Icon(Icons.text_fields_rounded),
            title: const Text('游標'),
            trailing: SegmentedButton<TerminalCursorStyle>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: TerminalCursorStyle.block,
                  label: Text('方塊'),
                ),
                ButtonSegment(
                  value: TerminalCursorStyle.underline,
                  label: Text('底線'),
                ),
                ButtonSegment(
                  value: TerminalCursorStyle.bar,
                  label: Text('直線'),
                ),
              ],
              selected: {settings.terminalCursor},
              onSelectionChanged: (value) =>
                  settings.terminalCursor = value.first,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.keyboard_alt_outlined),
            title: const Text('特殊鍵列'),
            trailing: DropdownButton<bool?>(
              value: settings.extraKeysOverride,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: null, child: Text('自動')),
                DropdownMenuItem(value: true, child: Text('顯示')),
                DropdownMenuItem(value: false, child: Text('隱藏')),
              ],
              onChanged: (value) => settings.extraKeysOverride = value,
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.vibration_rounded),
            value: settings.keyHaptics,
            onChanged: (value) => settings.keyHaptics = value,
            title: const Text('按鍵震動回饋'),
          ),
          ListTile(
            leading: const Icon(Icons.history_rounded),
            title: const Text('回捲行數'),
            trailing: DropdownButton<int>(
              value: settings.terminalScrollback,
              underline: const SizedBox.shrink(),
              items: [
                for (final value in const [1000, 5000, 10000, 50000])
                  DropdownMenuItem(value: value, child: Text('$value 行')),
              ],
              onChanged: (value) {
                if (value != null) settings.terminalScrollback = value;
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Android 主畫面小工具：從 App 直接加到桌面，以及沒開 App 時的更新頻率。
class _HomeWidgetSettings extends StatelessWidget {
  const _HomeWidgetSettings();

  Future<void> _addServerWidget(BuildContext context) async {
    final servers = context.read<ServerStore>().servers;
    if (servers.isEmpty) {
      showMessage(context, '還沒有伺服器', error: true);
      return;
    }
    final target = servers.length == 1
        ? servers.first
        : await showDialog<ServerProfile>(
            context: context,
            builder: (dialogContext) => SimpleDialog(
              title: const Text('要顯示哪台伺服器？'),
              children: [
                for (final server in servers)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialogContext, server),
                    child: ListTile(
                      title: Text(server.name),
                      subtitle: Text(server.address),
                    ),
                  ),
              ],
            ),
          );
    if (target == null || !context.mounted) return;
    await _pin(context, HomeWidgetKind.server, serverId: target.id);
  }

  Future<void> _pin(
    BuildContext context,
    HomeWidgetKind kind, {
    String? serverId,
  }) async {
    final accepted = await context.read<HomeWidgetService>().requestPin(
      kind,
      serverId: serverId,
    );
    if (!accepted && context.mounted) {
      showMessage(context, '這個桌面不支援從 App 加入，請長按主畫面空白處，在「小工具」裡找到 Mato。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.view_agenda_outlined),
            title: const Text('伺服器總覽'),
            subtitle: const Text('列出每台伺服器的狀態與用量'),
            trailing: const Icon(Icons.add_to_home_screen_rounded),
            onTap: () => _pin(context, HomeWidgetKind.overview),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('伺服器狀態'),
            subtitle: const Text('單台伺服器的 CPU、記憶體、磁碟與網路'),
            trailing: const Icon(Icons.add_to_home_screen_rounded),
            onTap: () => _addServerWidget(context),
          ),
          ListTile(
            leading: const Icon(Icons.update_rounded),
            title: const Text('背景更新'),
            subtitle: const Text('沒開 App 時多久連線更新一次'),
            trailing: DropdownButton<int>(
              value: settings.widgetRefreshMinutes,
              underline: const SizedBox.shrink(),
              items: const [
                DropdownMenuItem(value: 0, child: Text('不更新')),
                DropdownMenuItem(value: 15, child: Text('15 分鐘')),
                DropdownMenuItem(value: 30, child: Text('30 分鐘')),
                DropdownMenuItem(value: 60, child: Text('1 小時')),
                DropdownMenuItem(value: 180, child: Text('3 小時')),
              ],
              onChanged: (value) {
                if (value != null) settings.widgetRefreshMinutes = value;
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SecuritySettings extends StatefulWidget {
  const _SecuritySettings();

  @override
  State<_SecuritySettings> createState() => _SecuritySettingsState();
}

class _SecuritySettingsState extends State<_SecuritySettings> {
  bool? _supported;

  @override
  void initState() {
    super.initState();
    context.read<AppLockService>().isSupported().then((value) {
      if (mounted) setState(() => _supported = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final knownHosts = context.watch<KnownHostsStore>().hosts.length;
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint_rounded),
            value: settings.appLock,
            onChanged: _supported == true
                ? (value) async {
                    final lock = context.read<AppLockService>();
                    // 開啟前先驗證一次，確認這台裝置真的能解鎖。
                    final ok = await lock.authenticate(
                      reason: value ? '確認啟用 App 鎖' : '確認關閉 App 鎖',
                    );
                    if (ok) {
                      settings.appLock = value;
                    } else if (context.mounted) {
                      showMessage(
                        context,
                        lock.lastError ?? '驗證未通過',
                        error: true,
                      );
                    }
                  }
                : null,
            title: const Text('App 鎖'),
            subtitle: Text(
              _supported == false
                  ? '這台裝置不支援生物辨識或系統驗證'
                  : '開啟 App 時需要 Face ID／指紋／Windows Hello 或裝置密碼',
            ),
          ),
          if (settings.appLock)
            ListTile(
              leading: const Icon(Icons.lock_clock_outlined),
              title: const Text('離開後多久重新上鎖'),
              trailing: DropdownButton<int>(
                value: settings.appLockDelay,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('立即')),
                  DropdownMenuItem(value: 60, child: Text('1 分鐘')),
                  DropdownMenuItem(value: 300, child: Text('5 分鐘')),
                  DropdownMenuItem(value: 900, child: Text('15 分鐘')),
                ],
                onChanged: (value) {
                  if (value != null) settings.appLockDelay = value;
                },
              ),
            ),
          ListTile(
            leading: const Icon(Icons.vpn_key_outlined),
            title: const Text('SSH 金鑰'),
            subtitle: const Text('匯入、產生、部署公鑰到伺服器'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const KeysScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('已知主機'),
            subtitle: Text('$knownHosts 筆主機金鑰指紋'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const KnownHostsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

class _BackupSettings extends StatelessWidget {
  const _BackupSettings();

  Future<void> _export(BuildContext context) async {
    final options = await showDialog<(bool, String)>(
      context: context,
      builder: (_) => const _ExportDialog(),
    );
    if (options == null || !context.mounted) return;
    final backup = context.read<BackupService>();
    try {
      final content = await runWithProgress(
        context,
        options.$1 ? '正在加密備份…' : '正在匯出…',
        () => backup.export(includeSecrets: options.$1, password: options.$2),
      );
      final now = DateTime.now();
      final name =
          'mato-backup-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.json';
      final saved = await FilePicker.saveFile(
        fileName: name,
        bytes: Uint8List.fromList(utf8.encode(content)),
        mimeType: 'application/json',
      );
      if (context.mounted && saved != null) showMessage(context, '已匯出 $name');
    } catch (error) {
      if (context.mounted) showMessage(context, '匯出失敗：$error', error: true);
    }
  }

  Future<void> _import(BuildContext context) async {
    final file = await FilePicker.pickFile(
      dialogTitle: '選擇 Mato 備份檔',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null || !context.mounted) return;
    final backup = context.read<BackupService>();
    try {
      final content = utf8.decode(await file.xFile.readAsBytes());
      String? password;
      if (BackupService.isEncrypted(content)) {
        if (!context.mounted) return;
        password = await promptText(
          context,
          title: '輸入備份密碼',
          label: '備份密碼',
          obscure: true,
        );
        if (password == null) return;
      }
      if (!context.mounted) return;
      final summary = await runWithProgress(
        context,
        '正在還原…',
        () => backup.import(content, password: password),
      );
      if (context.mounted) showMessage(context, '已還原 $summary');
    } catch (error) {
      if (context.mounted) showMessage(context, '還原失敗：$error', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.upload_file_rounded),
            title: const Text('匯出備份'),
            subtitle: const Text('伺服器、金鑰、腳本、轉發規則與設定'),
            onTap: () => _export(context),
          ),
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: const Text('從備份還原'),
            subtitle: const Text('相同的項目會被覆蓋'),
            onTap: () => _import(context),
          ),
        ],
      ),
    );
  }
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog();

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  bool _secrets = true;
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('匯出備份'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _secrets,
              onChanged: (value) => setState(() => _secrets = value),
              title: const Text('包含密碼與私鑰'),
              subtitle: const Text('會以你設定的密碼加密（AES-256-GCM）'),
            ),
            if (_secrets) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '備份密碼'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _confirm,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '再輸入一次',
                  errorText: _error,
                ),
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
        FilledButton(
          onPressed: () {
            if (_secrets) {
              if (_password.text.length < 6) {
                setState(() => _error = '密碼至少 6 個字元');
                return;
              }
              if (_password.text != _confirm.text) {
                setState(() => _error = '兩次輸入的密碼不同');
                return;
              }
            }
            Navigator.pop(context, (_secrets, _password.text));
          },
          child: const Text('匯出'),
        ),
      ],
    );
  }
}

/// AI 助理設定：供應商、金鑰、端點、模型與核准方式。
class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  late final SettingsStore _settings = context.read<SettingsStore>();
  late final _key = TextEditingController(text: _settings.aiApiKey);
  late final _baseUrl = TextEditingController(text: _settings.aiBaseUrl);
  late final _model = TextEditingController(text: _settings.aiModel);
  bool _obscure = true;
  bool _testing = false;

  @override
  void dispose() {
    _key.dispose();
    _baseUrl.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    _settings
      ..aiBaseUrl = _baseUrl.text
      ..aiModel = _model.text;
    await _settings.setAiApiKey(_key.text);
  }

  /// 用免費的 models 端點確認金鑰與網路可用。
  Future<void> _test() async {
    await _save();
    setState(() => _testing = true);
    try {
      final anthropic = _settings.aiProvider == AiProvider.anthropic;
      final base =
          (_settings.aiBaseUrl.isEmpty
                  ? (anthropic
                        ? 'https://api.anthropic.com'
                        : 'https://api.openai.com/v1')
                  : _settings.aiBaseUrl)
              .replaceFirst(RegExp(r'/+$'), '');
      final url = anthropic && !base.endsWith('/v1')
          ? '$base/v1/models'
          : '$base/models';
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              if (anthropic) ...{
                'anthropic-version': '2023-06-01',
                if (_settings.aiApiKey.isNotEmpty)
                  'x-api-key': _settings.aiApiKey,
              } else if (_settings.aiApiKey.isNotEmpty)
                'authorization': 'Bearer ${_settings.aiApiKey}',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (response.statusCode == 200) {
        showMessage(context, '連線成功，金鑰有效');
      } else {
        showMessage(
          context,
          '連線失敗（HTTP ${response.statusCode}）：${utf8.decode(response.bodyBytes, allowMalformed: true).characters.take(160)}',
          error: true,
        );
      }
    } catch (error) {
      if (mounted) showMessage(context, '連線失敗：$error', error: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final anthropic = settings.aiProvider == AiProvider.anthropic;
    final suggestions = anthropic
        ? const ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-4-5']
        : const ['gpt-4.1', 'gpt-4.1-mini', 'deepseek-chat', 'qwen2.5:14b'];

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _save();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('AI 助理'),
          actions: [
            TextButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check_rounded),
              label: const Text('測試連線'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ReadableWidth(
              maxWidth: 720,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<AiProvider>(
                    segments: const [
                      ButtonSegment(
                        value: AiProvider.anthropic,
                        label: Text('Anthropic (Claude)'),
                      ),
                      ButtonSegment(
                        value: AiProvider.openai,
                        label: Text('OpenAI 相容'),
                      ),
                    ],
                    selected: {settings.aiProvider},
                    onSelectionChanged: (value) {
                      settings.aiProvider = value.first;
                      _model.clear();
                      settings.aiModel = '';
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _key,
                    obscureText: _obscure,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'API 金鑰',
                      helperText: '只存在這台裝置的安全儲存區，直接送往你設定的 AI 服務',
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                        ),
                      ),
                    ),
                    onChanged: (_) => _save(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _baseUrl,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: 'Base URL（選填）',
                      hintText: anthropic ? 'https://api.anthropic.com' : 'https://api.openai.com/v1、http://localhost:11434/v1',
                      helperText: anthropic
                          ? '留白使用官方端點；也可填自架代理'
                          : '可用於 OpenAI、OpenRouter、DeepSeek、Ollama 等相容服務',
                    ),
                    onChanged: (_) => _save(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _model,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: '模型',
                      hintText: anthropic
                          ? defaultAnthropicModel
                          : defaultOpenAiModel,
                      helperText: '留白使用預設模型',
                    ),
                    onChanged: (_) => _save(),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final model in suggestions)
                        ActionChip(
                          label: Text(model),
                          onPressed: () {
                            _model.text = model;
                            _save();
                          },
                        ),
                    ],
                  ),
                  if (anthropic) ...[
                    const SizedBox(height: 18),
                    Text(
                      '思考深度（effort）',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'low', label: Text('低')),
                        ButtonSegment(value: 'medium', label: Text('中')),
                        ButtonSegment(value: 'high', label: Text('高')),
                        ButtonSegment(value: 'xhigh', label: Text('極高')),
                      ],
                      selected: {settings.aiEffort},
                      onSelectionChanged: (value) =>
                          settings.aiEffort = value.first,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '越高越仔細，但回覆較慢、花費較多。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 18),
                  SurfaceCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        SwitchListTile(
                          value: settings.aiAutoApproveReads,
                          onChanged: (value) =>
                              settings.aiAutoApproveReads = value,
                          title: const Text('自動允許唯讀操作'),
                          subtitle: const Text('讀取指標、列目錄、讀檔不必逐一確認'),
                        ),
                        SwitchListTile(
                          value: settings.aiAutoApproveAll,
                          onChanged: (value) async {
                            if (value) {
                              final ok = await confirmAction(
                                context,
                                title: '自動允許所有操作',
                                message:
                                    'AI 將可以不經確認就執行任何指令、覆寫檔案。'
                                    '請只在測試環境使用。',
                                confirmLabel: '我了解，開啟',
                                destructive: true,
                              );
                              if (!ok) return;
                            }
                            settings.aiAutoApproveAll = value;
                          },
                          title: const Text('自動允許執行指令與寫檔'),
                          subtitle: const Text('風險較高，預設關閉'),
                        ),
                      ],
                    ),
                  ),
                  if (anthropic && settings.aiBaseUrl.isEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      '使用官方端點時，若 Claude 的安全分類器誤判拒絕請求，'
                      '會自動改由 Anthropic 建議的模型接手（server-side fallbacks）。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 已信任的主機金鑰列表。
class KnownHostsScreen extends StatelessWidget {
  const KnownHostsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<KnownHostsStore>();
    final hosts = store.hosts;
    return Scaffold(
      appBar: AppBar(title: const Text('已知主機')),
      body: hosts.isEmpty
          ? const EmptyState(
              icon: Icons.verified_user_outlined,
              title: '還沒有記錄任何主機',
              message: '第一次連線時會記下主機金鑰指紋；之後若金鑰改變，Mato 會先警告你。',
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: hosts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final host = hosts[index];
                return ReadableWidth(
                  child: SurfaceCard(
                    padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                host.endpoint,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                '${host.type} · ${formatDateTime(host.addedAt)}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                host.fingerprint,
                                style: monoStyle(fontSize: 11.5),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '移除',
                          onPressed: () async {
                            final ok = await confirmAction(
                              context,
                              title: '移除已知主機',
                              message: '下次連到 ${host.endpoint} 時會重新記錄它的金鑰。',
                              confirmLabel: '移除',
                            );
                            if (ok) await store.remove(host.endpoint);
                          },
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// SFTP 長按選單的自訂指令。
class SftpCommandsScreen extends StatelessWidget {
  const SftpCommandsScreen({super.key});

  Future<void> _edit(
    BuildContext context,
    List<SftpCommand> commands, [
    int? index,
  ]) async {
    final existing = index == null ? null : commands[index];
    final name = await promptText(
      context,
      title: existing == null ? '新增指令' : '編輯指令',
      label: '名稱',
      initial: existing?.name ?? '',
      validator: (value) => value.trim().isEmpty ? '請輸入名稱' : null,
    );
    if (name == null || !context.mounted) return;
    final command = await promptText(
      context,
      title: '指令內容',
      label: '指令',
      initial: existing?.command ?? '',
      hint: '可用 {path}、{name}、{dir}（已自動加引號）',
      monospace: true,
      multiline: true,
      validator: (value) => value.trim().isEmpty ? '請輸入指令' : null,
    );
    if (command == null || !context.mounted) return;
    final updated = List.of(commands);
    final item = SftpCommand(name: name.trim(), command: command.trim());
    if (index == null) {
      updated.add(item);
    } else {
      updated[index] = item;
    }
    context.read<SettingsStore>().sftpCommands = updated;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final commands = settings.sftpCommands;
    return Scaffold(
      appBar: AppBar(
        title: const Text('長按自訂指令'),
        actions: [
          TextButton(
            onPressed: () =>
                settings.sftpCommands = SettingsStore.defaultSftpCommands,
            child: const Text('還原預設'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '新增指令',
        onPressed: () => _edit(context, commands),
        child: const Icon(Icons.add_rounded),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          ReadableWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '在檔案管理長按檔案或資料夾時會出現這些指令。{path} 是完整路徑、'
                  '{name} 是檔名、{dir} 是所在資料夾。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < commands.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: SurfaceCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        title: Text(commands[i].name),
                        subtitle: Text(
                          commands[i].command,
                          style: monoStyle(fontSize: 12),
                        ),
                        onTap: () => _edit(context, commands, i),
                        trailing: IconButton(
                          tooltip: '刪除',
                          onPressed: () {
                            final updated = List.of(commands)..removeAt(i);
                            settings.sftpCommands = updated;
                          },
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
