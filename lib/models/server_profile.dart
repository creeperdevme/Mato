import 'dart:convert';

enum ServerStatus { unknown, checking, online, offline, authFailed, error }

class ServerProfile {
  ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    this.password = '',
    required this.createdAt,
  });

  factory ServerProfile.fromJson(Map<String, dynamic> json) {
    return ServerProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int? ?? 22,
      username: json['username'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String password;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'createdAt': createdAt.toIso8601String(),
  };

  String encodedJson() => jsonEncode(toJson());

  ServerProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? username,
    String? password,
  }) {
    return ServerProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      createdAt: createdAt,
    );
  }
}
