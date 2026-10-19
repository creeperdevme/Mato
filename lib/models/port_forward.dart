enum ForwardKind {
  /// `ssh -L`：本機連接埠 → 遠端主機:連接埠。
  local,

  /// `ssh -D`：本機 SOCKS5 代理，所有連線經由伺服器送出。
  dynamic,
}

class PortForwardRule {
  const PortForwardRule({
    required this.id,
    required this.serverId,
    required this.name,
    required this.kind,
    required this.localPort,
    this.bindAddress = '127.0.0.1',
    this.remoteHost = '127.0.0.1',
    this.remotePort = 0,
    this.autoStart = false,
  });

  factory PortForwardRule.fromJson(Map<String, dynamic> json) =>
      PortForwardRule(
        id: json['id'] as String,
        serverId: json['serverId'] as String,
        name: json['name'] as String? ?? '',
        kind: ForwardKind.values.asNameMap()[json['kind']] ?? ForwardKind.local,
        localPort: json['localPort'] as int? ?? 0,
        bindAddress: json['bindAddress'] as String? ?? '127.0.0.1',
        remoteHost: json['remoteHost'] as String? ?? '127.0.0.1',
        remotePort: json['remotePort'] as int? ?? 0,
        autoStart: json['autoStart'] as bool? ?? false,
      );

  final String id;
  final String serverId;
  final String name;
  final ForwardKind kind;
  final int localPort;
  final String bindAddress;
  final String remoteHost;
  final int remotePort;

  /// 進入伺服器頁面時自動啟動。
  final bool autoStart;

  String get summary => kind == ForwardKind.dynamic
      ? 'SOCKS5 $bindAddress:$localPort'
      : '$bindAddress:$localPort → $remoteHost:$remotePort';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'serverId': serverId,
    'name': name,
    'kind': kind.name,
    'localPort': localPort,
    'bindAddress': bindAddress,
    'remoteHost': remoteHost,
    'remotePort': remotePort,
    'autoStart': autoStart,
  };
}
