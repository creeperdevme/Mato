/// SSH 金鑰的中繼資料；私鑰本體與密語只存在安全儲存區。
class SshKeyEntry {
  const SshKeyEntry({
    required this.id,
    required this.name,
    required this.type,
    required this.publicKey,
    required this.fingerprint,
    required this.encrypted,
    required this.createdAt,
  });

  factory SshKeyEntry.fromJson(Map<String, dynamic> json) => SshKeyEntry(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    type: json['type'] as String? ?? '',
    publicKey: json['publicKey'] as String? ?? '',
    fingerprint: json['fingerprint'] as String? ?? '',
    encrypted: json['encrypted'] as bool? ?? false,
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
  );

  final String id;
  final String name;

  /// 例：`ssh-ed25519`、`ssh-rsa`。
  final String type;

  /// OpenSSH 單行公鑰（`ssh-ed25519 AAAA... comment`），可直接貼到
  /// `authorized_keys`。
  final String publicKey;

  /// `SHA256:...`。
  final String fingerprint;

  /// 私鑰本身是否以密語加密。
  final bool encrypted;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'type': type,
    'publicKey': publicKey,
    'fingerprint': fingerprint,
    'encrypted': encrypted,
    'createdAt': createdAt.toIso8601String(),
  };

  SshKeyEntry copyWith({String? name}) => SshKeyEntry(
    id: id,
    name: name ?? this.name,
    type: type,
    publicKey: publicKey,
    fingerprint: fingerprint,
    encrypted: encrypted,
    createdAt: createdAt,
  );
}
