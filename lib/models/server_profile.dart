import 'dart:convert';

enum ServerStatus { unknown, checking, online, offline, authFailed, error }

/// 主要登入方式；無論哪一種，伺服器若要求 keyboard-interactive（2FA）都會
/// 再補問使用者。
enum AuthMethod { password, privateKey }

/// 終端機開新分頁時要直接進入的工作階段類型。
enum SessionMode { shell, tmux, zellij }

/// SOCKS5 代理伺服器設定；密碼另存在安全儲存區。
class ProxyConfig {
  const ProxyConfig({
    required this.host,
    required this.port,
    this.username = '',
  });

  factory ProxyConfig.fromJson(Map<String, dynamic> json) => ProxyConfig(
    host: json['host'] as String? ?? '',
    port: json['port'] as int? ?? 1080,
    username: json['username'] as String? ?? '',
  );

  final String host;
  final int port;
  final String username;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'host': host,
    'port': port,
    'username': username,
  };
}

/// 一台伺服器的連線設定。
///
/// [password]、[privateKey]、[passphrase]、[proxyPassword] 與 [jump] 只存在
/// 記憶體中（由 [ServerStore.resolve] 填入），不會寫進 [toJson]。
class ServerProfile {
  ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.authMethod = AuthMethod.password,
    this.keyId,
    this.group = '',
    this.jumpServerId,
    this.proxy,
    this.alternateHosts = const [],
    this.startupCommand = '',
    this.sessionMode = SessionMode.shell,
    this.sessionName = 'mato',
    this.agentForwarding = false,
    this.macAddress = '',
    this.wolBroadcast = '',
    this.wolPort = 9,
    this.notes = '',
    this.iconName = '',
    required this.createdAt,
    this.password = '',
    this.privateKey = '',
    this.passphrase = '',
    this.proxyPassword = '',
    this.jump,
  });

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    return ServerProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int? ?? 22,
      username: json['username'] as String,
      authMethod:
          AuthMethod.values.asNameMap()[json['authMethod']] ??
          AuthMethod.password,
      keyId: json['keyId'] as String?,
      group: json['group'] as String? ?? '',
      jumpServerId: json['jumpServerId'] as String?,
      proxy: json['proxy'] is Map<String, dynamic>
          ? ProxyConfig.fromJson(json['proxy'] as Map<String, dynamic>)
          : null,
      alternateHosts: (json['alternateHosts'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      startupCommand: json['startupCommand'] as String? ?? '',
      sessionMode:
          SessionMode.values.asNameMap()[json['sessionMode']] ??
          SessionMode.shell,
      sessionName: json['sessionName'] as String? ?? 'mato',
      agentForwarding: json['agentForwarding'] as bool? ?? false,
      macAddress: json['macAddress'] as String? ?? '',
      wolBroadcast: json['wolBroadcast'] as String? ?? '',
      wolPort: json['wolPort'] as int? ?? 9,
      notes: json['notes'] as String? ?? '',
      iconName: json['iconName'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;

  /// [AuthMethod.privateKey] 時使用的金鑰（見 [KeyStore]）。
  final String? keyId;

  /// 分組名稱，空字串代表未分組。
  final String group;

  /// 跳板機（ProxyJump）：先連上這台，再經由它連到本機。
  final String? jumpServerId;
  final ProxyConfig? proxy;

  /// 主要位址連不上時依序嘗試的備援位址，格式 `host` 或 `host:port`。
  final List<String> alternateHosts;

  /// 終端機開啟後自動執行的指令（初始化腳本）。
  final String startupCommand;
  final SessionMode sessionMode;

  /// tmux／zellij 的工作階段名稱。
  final String sessionName;
  final bool agentForwarding;

  /// Wake-on-LAN 用的 MAC 位址；空字串代表未設定。
  final String macAddress;
  final String wolBroadcast;
  final int wolPort;
  final String notes;

  /// 自訂圖示的檔名（見 [ServerStore] 的圖示儲存區）；空字串代表用系統圖示。
  final String iconName;

  final DateTime createdAt;

  final String password;
  final String privateKey;
  final String passphrase;
  final String proxyPassword;
  final ServerProfile? jump;

  String get address => '$username@$host:$port';
  bool get canWake => macAddress.trim().isNotEmpty;
  bool get isRoot => username == 'root';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'authMethod': authMethod.name,
    if (keyId != null) 'keyId': keyId,
    'group': group,
    if (jumpServerId != null) 'jumpServerId': jumpServerId,
    if (proxy != null) 'proxy': proxy!.toJson(),
    'alternateHosts': alternateHosts,
    'startupCommand': startupCommand,
    'sessionMode': sessionMode.name,
    'sessionName': sessionName,
    'agentForwarding': agentForwarding,
    'macAddress': macAddress,
    'wolBroadcast': wolBroadcast,
    'wolPort': wolPort,
    'notes': notes,
    if (iconName.isNotEmpty) 'iconName': iconName,
    'createdAt': createdAt.toIso8601String(),
  };

  String encodedJson() => jsonEncode(toJson());

  /// 連線相關設定（含密鑰）的指紋，用來判斷連線池裡的舊連線是否還能沿用。
  String get connectionSignature => Object.hashAll([
    host,
    port,
    username,
    authMethod,
    keyId,
    password,
    privateKey,
    passphrase,
    proxy?.host,
    proxy?.port,
    proxy?.username,
    proxyPassword,
    Object.hashAll(alternateHosts),
    agentForwarding,
    jump?.connectionSignature,
  ]).toString();

  ServerProfile copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    AuthMethod? authMethod,
    String? keyId,
    bool clearKeyId = false,
    String? group,
    String? jumpServerId,
    bool clearJumpServer = false,
    ProxyConfig? proxy,
    bool clearProxy = false,
    List<String>? alternateHosts,
    String? startupCommand,
    SessionMode? sessionMode,
    String? sessionName,
    bool? agentForwarding,
    String? macAddress,
    String? wolBroadcast,
    int? wolPort,
    String? notes,
    String? iconName,
    DateTime? createdAt,
    String? password,
    String? privateKey,
    String? passphrase,
    String? proxyPassword,
    ServerProfile? jump,
  }) {
    return ServerProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      keyId: clearKeyId ? null : keyId ?? this.keyId,
      group: group ?? this.group,
      jumpServerId: clearJumpServer ? null : jumpServerId ?? this.jumpServerId,
      proxy: clearProxy ? null : proxy ?? this.proxy,
      alternateHosts: alternateHosts ?? this.alternateHosts,
      startupCommand: startupCommand ?? this.startupCommand,
      sessionMode: sessionMode ?? this.sessionMode,
      sessionName: sessionName ?? this.sessionName,
      agentForwarding: agentForwarding ?? this.agentForwarding,
      macAddress: macAddress ?? this.macAddress,
      wolBroadcast: wolBroadcast ?? this.wolBroadcast,
      wolPort: wolPort ?? this.wolPort,
      notes: notes ?? this.notes,
      iconName: iconName ?? this.iconName,
      createdAt: createdAt ?? this.createdAt,
      password: password ?? this.password,
      privateKey: privateKey ?? this.privateKey,
      passphrase: passphrase ?? this.passphrase,
      proxyPassword: proxyPassword ?? this.proxyPassword,
      jump: clearJumpServer ? null : jump ?? this.jump,
    );
  }
}

/// 解析 `host` 或 `host:port`（IPv6 請用 `[::1]:22`）。
({String host, int port}) parseHostPort(String value, int defaultPort) {
  final trimmed = value.trim();
  if (trimmed.startsWith('[')) {
    final end = trimmed.indexOf(']');
    if (end > 0) {
      final host = trimmed.substring(1, end);
      final rest = trimmed.substring(end + 1);
      final port = rest.startsWith(':')
          ? int.tryParse(rest.substring(1))
          : null;
      return (host: host, port: port ?? defaultPort);
    }
  }
  final colon = trimmed.lastIndexOf(':');
  if (colon > 0 && trimmed.indexOf(':') == colon) {
    final port = int.tryParse(trimmed.substring(colon + 1));
    if (port != null) {
      return (host: trimmed.substring(0, colon), port: port);
    }
  }
  return (host: trimmed, port: defaultPort);
}
