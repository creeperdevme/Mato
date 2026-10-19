import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class KnownHost {
  const KnownHost({
    required this.endpoint,
    required this.type,
    required this.fingerprint,
    required this.addedAt,
  });

  factory KnownHost.fromJson(String endpoint, Map<String, dynamic> json) =>
      KnownHost(
        endpoint: endpoint,
        type: json['type'] as String? ?? '',
        fingerprint: json['fingerprint'] as String? ?? '',
        addedAt:
            DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.now(),
      );

  /// `host:port`。
  final String endpoint;
  final String type;

  /// OpenSSH 風格的 `SHA256:...`。
  final String fingerprint;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type,
    'fingerprint': fingerprint,
    'addedAt': addedAt.toIso8601String(),
  };
}

/// 已信任的主機金鑰（TOFU：第一次連線時記下，之後若改變就警告）。
class KnownHostsStore extends ChangeNotifier {
  static const _key = 'mato.knownHosts.v1';

  final Map<String, KnownHost> _hosts = {};
  bool _loaded = false;

  List<KnownHost> get hosts =>
      _hosts.values.toList()..sort((a, b) => a.endpoint.compareTo(b.endpoint));

  static String endpointOf(String host, int port) =>
      host.contains(':') ? '[$host]:$port' : '$host:$port';

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_key);
    if (raw == null) return;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      map.forEach((endpoint, value) {
        if (value is Map<String, dynamic>) {
          _hosts[endpoint] = KnownHost.fromJson(endpoint, value);
        }
      });
    } catch (_) {
      // 損毀的資料直接忽略，下次連線會重新記錄。
    }
    notifyListeners();
  }

  KnownHost? lookup(String host, int port) => _hosts[endpointOf(host, port)];

  Future<void> trust(
    String host,
    int port,
    String type,
    String fingerprint,
  ) async {
    final endpoint = endpointOf(host, port);
    _hosts[endpoint] = KnownHost(
      endpoint: endpoint,
      type: type,
      fingerprint: fingerprint,
      addedAt: DateTime.now(),
    );
    await _save();
    notifyListeners();
  }

  Future<void> remove(String endpoint) async {
    _hosts.remove(endpoint);
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key,
      jsonEncode(_hosts.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }
}
