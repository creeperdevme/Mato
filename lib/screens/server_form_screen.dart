import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/key_store.dart';
import '../services/known_hosts_store.dart';
import '../services/network_tools.dart';
import '../services/server_store.dart';
import '../services/ssh_service.dart';
import '../utils/error_messages.dart';
import '../widgets/common.dart';
import 'keys_screen.dart';

class ServerFormScreen extends StatefulWidget {
  const ServerFormScreen({
    super.key,
    this.server,
    this.prefillHost,
    this.prefillPort,
    this.prefillName,
  });

  final ServerProfile? server;
  final String? prefillHost;
  final int? prefillPort;
  final String? prefillName;

  @override
  State<ServerFormScreen> createState() => _ServerFormScreenState();
}

class _ServerFormScreenState extends State<ServerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  final TextEditingController _password = TextEditingController();
  late final TextEditingController _group;
  late final TextEditingController _alternates;
  late final TextEditingController _proxyHost;
  late final TextEditingController _proxyPort;
  late final TextEditingController _proxyUser;
  final TextEditingController _proxyPassword = TextEditingController();
  late final TextEditingController _startup;
  late final TextEditingController _sessionName;
  late final TextEditingController _mac;
  late final TextEditingController _broadcast;
  late final TextEditingController _wolPort;
  late final TextEditingController _notes;

  late AuthMethod _authMethod;
  String? _keyId;
  String? _jumpId;
  late bool _useProxy;
  late SessionMode _sessionMode;
  late bool _agentForwarding;
  bool _obscurePassword = true;
  bool _hasSavedPassword = false;
  bool _clearPassword = false;
  bool _saving = false;
  bool _testing = false;

  bool get _editing => widget.server != null;

  @override
  void initState() {
    super.initState();
    final server = widget.server;
    _name = TextEditingController(
      text: server?.name ?? widget.prefillName ?? '',
    );
    _host = TextEditingController(
      text: server?.host ?? widget.prefillHost ?? '',
    );
    _port = TextEditingController(
      text: '${server?.port ?? widget.prefillPort ?? 22}',
    );
    _username = TextEditingController(text: server?.username ?? '');
    _group = TextEditingController(text: server?.group ?? '');
    _alternates = TextEditingController(
      text: server?.alternateHosts.join('\n') ?? '',
    );
    _proxyHost = TextEditingController(text: server?.proxy?.host ?? '');
    _proxyPort = TextEditingController(text: '${server?.proxy?.port ?? 1080}');
    _proxyUser = TextEditingController(text: server?.proxy?.username ?? '');
    _startup = TextEditingController(text: server?.startupCommand ?? '');
    _sessionName = TextEditingController(text: server?.sessionName ?? 'mato');
    _mac = TextEditingController(text: server?.macAddress ?? '');
    _broadcast = TextEditingController(text: server?.wolBroadcast ?? '');
    _wolPort = TextEditingController(text: '${server?.wolPort ?? 9}');
    _notes = TextEditingController(text: server?.notes ?? '');
    _authMethod = server?.authMethod ?? AuthMethod.password;
    _keyId = server?.keyId;
    _jumpId = server?.jumpServerId;
    _useProxy = server?.proxy != null;
    _sessionMode = server?.sessionMode ?? SessionMode.shell;
    _agentForwarding = server?.agentForwarding ?? false;
    if (server != null) {
      context.read<ServerStore>().getPassword(server.id).then((value) {
        if (mounted) {
          setState(() => _hasSavedPassword = (value ?? '').isNotEmpty);
        }
      });
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _host,
      _port,
      _username,
      _password,
      _group,
      _alternates,
      _proxyHost,
      _proxyPort,
      _proxyUser,
      _proxyPassword,
      _startup,
      _sessionName,
      _mac,
      _broadcast,
      _wolPort,
      _notes,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 依表單內容組出設定（不含機密）。
  ServerProfile _profileFromForm() {
    final base =
        widget.server ??
        ServerProfile(
          id: '',
          name: '',
          host: '',
          username: '',
          createdAt: DateTime.now(),
        );
    return base.copyWith(
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      username: _username.text.trim(),
      authMethod: _authMethod,
      keyId: _keyId,
      clearKeyId: _authMethod != AuthMethod.privateKey || _keyId == null,
      group: _group.text.trim(),
      jumpServerId: _jumpId,
      clearJumpServer: _jumpId == null,
      proxy: _useProxy
          ? ProxyConfig(
              host: _proxyHost.text.trim(),
              port: int.tryParse(_proxyPort.text.trim()) ?? 1080,
              username: _proxyUser.text.trim(),
            )
          : null,
      clearProxy: !_useProxy,
      alternateHosts: _alternates.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList(),
      startupCommand: _startup.text.trim(),
      sessionMode: _sessionMode,
      sessionName: _sessionName.text.trim().isEmpty
          ? 'mato'
          : _sessionName.text.trim(),
      agentForwarding: _authMethod == AuthMethod.privateKey && _agentForwarding,
      macAddress: _mac.text.trim(),
      wolBroadcast: _broadcast.text.trim(),
      wolPort: int.tryParse(_wolPort.text.trim()) ?? 9,
      notes: _notes.text.trim(),
    );
  }

  ServerSecrets _secretsFromForm() {
    String? password;
    if (_clearPassword) {
      password = '';
    } else if (_password.text.isNotEmpty) {
      password = _password.text;
    }
    return ServerSecrets(
      password: password,
      proxyPassword: _useProxy && _proxyPassword.text.isNotEmpty
          ? _proxyPassword.text
          : null,
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      showMessage(context, '請修正標示紅色的欄位', error: true);
      return;
    }
    setState(() => _saving = true);
    final store = context.read<ServerStore>();
    final ssh = context.read<SSHService>();
    final profile = _profileFromForm();
    try {
      if (_editing) {
        await store.updateServer(profile, secrets: _secretsFromForm());
        // 連線設定可能改了，讓下次操作重新連線。
        ssh.disconnect(profile.id);
      } else {
        await store.addServer(profile, secrets: _secretsFromForm());
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) showMessage(context, '儲存失敗：$error', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _testing = true);
    final store = context.read<ServerStore>();
    final keys = context.read<KeyStore>();
    final ssh = context.read<SSHService>();
    final knownHosts = context.read<KnownHostsStore>();
    try {
      var profile = _profileFromForm();
      final secret = profile.keyId == null
          ? null
          : await keys.secretOf(profile.keyId!);
      final savedPassword = _editing
          ? await store.getPassword(profile.id)
          : null;
      profile = profile.copyWith(
        id: profile.id.isEmpty ? '__test__' : '${profile.id}__test__',
        password: _clearPassword
            ? ''
            : _password.text.isNotEmpty
            ? _password.text
            : savedPassword ?? '',
        privateKey: secret?.pem ?? '',
        passphrase: secret?.passphrase ?? '',
        proxyPassword: _proxyPassword.text.isNotEmpty
            ? _proxyPassword.text
            : _editing
            ? await store.getProxyPassword(profile.id) ?? ''
            : '',
        jump: _jumpId == null ? null : await store.resolve(_jumpId!),
      );
      final client = await ssh.connect(profile, interactive: true);
      String uname;
      try {
        uname = String.fromCharCodes(await client.run('uname -srm')).trim();
      } finally {
        client.close();
      }
      final known = knownHosts.lookup(profile.host, profile.port);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(
            Icons.check_circle_rounded,
            color: Colors.green,
            size: 36,
          ),
          title: const Text('連線成功'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(uname.isEmpty ? '已登入 ${profile.address}' : uname),
              if (known != null) ...[
                const SizedBox(height: 14),
                Text(
                  '主機金鑰（${known.type}）',
                  style: Theme.of(dialogContext).textTheme.labelSmall,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  known.fingerprint,
                  style: monoStyle(fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('好'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) showMessage(context, describeSshError(error), error: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _manageKeys() async {
    final selected = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const KeysScreen(selectable: true)),
    );
    if (selected != null && mounted) setState(() => _keyId = selected);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ServerStore>();
    final keys = context.watch<KeyStore>().keys;
    final jumpCandidates = store.servers
        .where((server) => server.id != widget.server?.id)
        .toList();
    if (_keyId != null && keys.every((key) => key.id != _keyId)) _keyId = null;
    if (_jumpId != null &&
        jumpCandidates.every((server) => server.id != _jumpId)) {
      _jumpId = null;
    }
    final hasAdvanced =
        _jumpId != null ||
        _useProxy ||
        (widget.server?.alternateHosts.isNotEmpty ?? false);

    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? '編輯伺服器' : '新增伺服器'),
        actions: [
          TextButton.icon(
            onPressed: _testing || _saving ? null : _test,
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
      body: SafeArea(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              ReadableWidth(
                maxWidth: 720,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section(
                      title: '基本資料',
                      icon: Icons.dns_outlined,
                      children: [
                        TextFormField(
                          controller: _name,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: '顯示名稱',
                            hintText: '例如：家用 NAS、正式機 web-01',
                          ),
                          validator: (value) =>
                              (value ?? '').trim().isEmpty ? '請輸入顯示名稱' : null,
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: _host,
                                keyboardType: TextInputType.url,
                                autocorrect: false,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: '主機位址 / IP',
                                ),
                                validator: (value) =>
                                    (value ?? '').trim().isEmpty
                                    ? '請輸入主機位址'
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _port,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '連接埠',
                                ),
                                validator: _portValidator,
                              ),
                            ),
                          ],
                        ),
                        TextFormField(
                          controller: _username,
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'SSH 帳號',
                          ),
                          validator: (value) => (value ?? '').trim().isEmpty
                              ? '請輸入 SSH 帳號'
                              : null,
                        ),
                        _GroupField(controller: _group, groups: store.groups),
                      ],
                    ),
                    _Section(
                      title: '驗證方式',
                      icon: Icons.key_rounded,
                      children: [
                        SegmentedButton<AuthMethod>(
                          segments: const [
                            ButtonSegment(
                              value: AuthMethod.password,
                              icon: Icon(Icons.password_rounded),
                              label: Text('密碼'),
                            ),
                            ButtonSegment(
                              value: AuthMethod.privateKey,
                              icon: Icon(Icons.vpn_key_outlined),
                              label: Text('私鑰'),
                            ),
                          ],
                          selected: {_authMethod},
                          onSelectionChanged: (value) =>
                              setState(() => _authMethod = value.first),
                        ),
                        if (_authMethod == AuthMethod.privateKey) ...[
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: _keyId,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: '私鑰',
                                  ),
                                  items: [
                                    for (final key in keys)
                                      DropdownMenuItem(
                                        value: key.id,
                                        child: Text(
                                          '${key.name}（${key.type}）',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) =>
                                      setState(() => _keyId = value),
                                  validator: (value) =>
                                      _authMethod == AuthMethod.privateKey &&
                                          value == null
                                      ? '請選擇或匯入一把私鑰'
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                tooltip: '管理／匯入金鑰',
                                onPressed: _manageKeys,
                                icon: const Icon(
                                  Icons.manage_accounts_outlined,
                                ),
                              ),
                            ],
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _agentForwarding,
                            onChanged: (value) =>
                                setState(() => _agentForwarding = value),
                            title: const Text('SSH Agent 轉發'),
                            subtitle: const Text(
                              '讓伺服器上的 git、ssh 也能使用這把金鑰。只對信任的伺服器開啟。',
                            ),
                          ),
                        ],
                        TextFormField(
                          controller: _password,
                          obscureText: _obscurePassword,
                          enabled: !_clearPassword,
                          decoration: InputDecoration(
                            labelText: _authMethod == AuthMethod.privateKey
                                ? '密碼（選填，用於 sudo）'
                                : _editing && _hasSavedPassword
                                ? '新密碼（留白則不變更）'
                                : 'SSH 密碼',
                            helperText:
                                _authMethod == AuthMethod.password &&
                                    !_hasSavedPassword
                                ? '留白則每次連線時詢問'
                                : null,
                            suffixIcon: IconButton(
                              tooltip: _obscurePassword ? '顯示密碼' : '隱藏密碼',
                              onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                              icon: Icon(
                                _obscurePassword
                                    ? Icons.visibility_rounded
                                    : Icons.visibility_off_rounded,
                              ),
                            ),
                          ),
                        ),
                        if (_editing && _hasSavedPassword)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _clearPassword,
                            onChanged: (value) =>
                                setState(() => _clearPassword = value ?? false),
                            title: const Text('清除已儲存的密碼'),
                          ),
                      ],
                    ),
                    _Section(
                      title: '進階連線',
                      icon: Icons.alt_route_rounded,
                      collapsible: true,
                      initiallyExpanded: hasAdvanced,
                      subtitle: '跳板機、SOCKS5 代理、備援位址',
                      children: [
                        DropdownButtonFormField<String?>(
                          initialValue: _jumpId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '跳板機（ProxyJump）',
                            helperText: '先連上這台，再經由它連到目標伺服器',
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('不使用'),
                            ),
                            for (final server in jumpCandidates)
                              DropdownMenuItem<String?>(
                                value: server.id,
                                child: Text(
                                  '${server.name}（${server.host}）',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) => setState(() {
                            _jumpId = value;
                            if (value != null) _useProxy = false;
                          }),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _useProxy,
                          onChanged: _jumpId != null
                              ? null
                              : (value) => setState(() => _useProxy = value),
                          title: const Text('透過 SOCKS5 代理連線'),
                          subtitle: _jumpId != null
                              ? const Text('使用跳板機時無法同時使用代理')
                              : null,
                        ),
                        if (_useProxy) ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 3,
                                child: TextFormField(
                                  controller: _proxyHost,
                                  decoration: const InputDecoration(
                                    labelText: '代理主機',
                                  ),
                                  validator: (value) =>
                                      _useProxy && (value ?? '').trim().isEmpty
                                      ? '請輸入代理主機'
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  controller: _proxyPort,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: '連接埠',
                                  ),
                                  validator: _useProxy ? _portValidator : null,
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _proxyUser,
                                  decoration: const InputDecoration(
                                    labelText: '代理帳號（選填）',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  controller: _proxyPassword,
                                  obscureText: true,
                                  decoration: InputDecoration(
                                    labelText: _editing
                                        ? '代理密碼（留白不變更）'
                                        : '代理密碼（選填）',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        TextFormField(
                          controller: _alternates,
                          minLines: 2,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            labelText: '備援位址（每行一個）',
                            helperText: '主要位址連不上時依序嘗試，格式 host 或 host:port',
                            alignLabelWithHint: true,
                          ),
                        ),
                      ],
                    ),
                    _Section(
                      title: '終端機',
                      icon: Icons.terminal_rounded,
                      children: [
                        Text(
                          '開新分頁時的工作階段',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        SegmentedButton<SessionMode>(
                          segments: const [
                            ButtonSegment(
                              value: SessionMode.shell,
                              label: Text('Shell'),
                            ),
                            ButtonSegment(
                              value: SessionMode.tmux,
                              label: Text('tmux'),
                            ),
                            ButtonSegment(
                              value: SessionMode.zellij,
                              label: Text('zellij'),
                            ),
                          ],
                          selected: {_sessionMode},
                          onSelectionChanged: (value) =>
                              setState(() => _sessionMode = value.first),
                        ),
                        if (_sessionMode != SessionMode.shell)
                          TextFormField(
                            controller: _sessionName,
                            decoration: const InputDecoration(
                              labelText: '工作階段名稱',
                              helperText: '斷線後重新連上會自動接回同名工作階段',
                            ),
                          ),
                        TextFormField(
                          controller: _startup,
                          minLines: 1,
                          maxLines: 4,
                          style: monoStyle(fontSize: 13),
                          decoration: const InputDecoration(
                            labelText: '初始化指令（選填）',
                            helperText: '連上後自動執行，例如 cd /srv/app && source .env',
                            alignLabelWithHint: true,
                          ),
                        ),
                      ],
                    ),
                    _Section(
                      title: 'Wake-on-LAN',
                      icon: Icons.power_settings_new_rounded,
                      collapsible: true,
                      initiallyExpanded: widget.server?.canWake ?? false,
                      subtitle: '從遠端喚醒關機中的主機',
                      children: [
                        TextFormField(
                          controller: _mac,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'MAC 位址',
                            hintText: 'AA:BB:CC:DD:EE:FF',
                          ),
                          validator: (value) {
                            final text = (value ?? '').trim();
                            if (text.isEmpty) return null;
                            return WakeOnLan.isValidMac(text)
                                ? null
                                : 'MAC 位址格式不正確';
                          },
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: _broadcast,
                                decoration: const InputDecoration(
                                  labelText: '廣播位址（選填）',
                                  hintText: '192.168.1.255',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _wolPort,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: '連接埠',
                                ),
                                validator: _portValidator,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    _Section(
                      title: '備註',
                      icon: Icons.notes_rounded,
                      children: [
                        TextFormField(
                          controller: _notes,
                          minLines: 2,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            hintText: '用途、機房位置、帳號注意事項…',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_rounded),
                      label: Text(_editing ? '儲存變更' : '新增伺服器'),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '密碼與私鑰使用系統安全儲存區（Keychain／Keystore／Credential '
                      'Manager）保存，不會寫入一般設定檔。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _portValidator(String? value) {
    final port = int.tryParse((value ?? '').trim());
    if (port == null || port < 1 || port > 65535) return '需為 1–65535';
    return null;
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.children,
    this.subtitle,
    this.collapsible = false,
    this.initiallyExpanded = true,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final List<Widget> children;
  final bool collapsible;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            children[i],
          ],
        ],
      ),
    );
    final header = Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: SurfaceCard(
        padding: EdgeInsets.zero,
        child: collapsible
            ? Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  initiallyExpanded: initiallyExpanded,
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: header,
                  subtitle: subtitle == null
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(left: 30),
                          child: Text(subtitle!),
                        ),
                  children: [body],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                    child: header,
                  ),
                  body,
                ],
              ),
      ),
    );
  }
}

class _GroupField extends StatefulWidget {
  const _GroupField({required this.controller, required this.groups});

  final TextEditingController controller;
  final List<String> groups;

  @override
  State<_GroupField> createState() => _GroupFieldState();
}

class _GroupFieldState extends State<_GroupField> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: widget.controller,
      focusNode: _focusNode,
      optionsBuilder: (value) => widget.groups.where(
        (group) =>
            group.toLowerCase().contains(value.text.toLowerCase()) &&
            group != value.text,
      ),
      fieldViewBuilder: (context, textController, focusNode, onSubmitted) =>
          TextFormField(
            controller: textController,
            focusNode: focusNode,
            decoration: const InputDecoration(
              labelText: '分組（選填）',
              hintText: '例如：正式環境、家用',
            ),
          ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220, maxWidth: 360),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final option in options)
                  ListTile(
                    dense: true,
                    title: Text(option),
                    onTap: () => onSelected(option),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
