import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/server_profile.dart';

void main() {
  test('ServerProfile round-trips JSON without persisting secrets', () {
    final server = ServerProfile(
      id: 'test-id',
      name: 'My Server',
      host: 'example.com',
      port: 2222,
      username: 'root',
      authMethod: AuthMethod.privateKey,
      keyId: 'key-1',
      group: '正式環境',
      jumpServerId: 'bastion',
      proxy: const ProxyConfig(host: 'proxy.local', port: 1080, username: 'u'),
      alternateHosts: const ['10.0.0.2', 'backup.example.com:22'],
      startupCommand: 'cd /srv',
      sessionMode: SessionMode.tmux,
      sessionName: 'work',
      agentForwarding: true,
      macAddress: 'AA:BB:CC:DD:EE:FF',
      password: 'secret',
      privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----',
      proxyPassword: 'proxy-secret',
      createdAt: DateTime.utc(2026, 1, 2),
    );

    final json = server.toJson();
    final restored = ServerProfile.fromJson(Map<String, dynamic>.from(json));

    expect(restored.id, server.id);
    expect(restored.port, 2222);
    expect(restored.authMethod, AuthMethod.privateKey);
    expect(restored.keyId, 'key-1');
    expect(restored.group, '正式環境');
    expect(restored.jumpServerId, 'bastion');
    expect(restored.proxy?.host, 'proxy.local');
    expect(restored.alternateHosts, ['10.0.0.2', 'backup.example.com:22']);
    expect(restored.sessionMode, SessionMode.tmux);
    expect(restored.sessionName, 'work');
    expect(restored.agentForwarding, isTrue);
    expect(restored.canWake, isTrue);
    for (final secret in ['secret', 'proxy-secret', 'PRIVATE KEY']) {
      expect(json.toString(), isNot(contains(secret)));
    }
    expect(restored.password, isEmpty);
  });

  test('舊版只有基本欄位的資料仍可讀取', () {
    final restored = ServerProfile.fromJson({
      'id': 'legacy',
      'name': 'Legacy',
      'host': '192.168.1.2',
      'port': 22,
      'username': 'pi',
      'createdAt': '2026-10-01T00:00:00.000',
    });
    expect(restored.authMethod, AuthMethod.password);
    expect(restored.sessionMode, SessionMode.shell);
    expect(restored.alternateHosts, isEmpty);
    expect(restored.proxy, isNull);
  });

  test('連線設定或密碼改變時 connectionSignature 也會改變', () {
    final base = ServerProfile(
      id: 'a',
      name: 'n',
      host: 'h',
      username: 'u',
      password: 'p1',
      createdAt: DateTime(2026),
    );
    expect(base.connectionSignature, base.copyWith().connectionSignature);
    expect(
      base.connectionSignature,
      isNot(base.copyWith(password: 'p2').connectionSignature),
    );
    expect(
      base.connectionSignature,
      isNot(base.copyWith(port: 2222).connectionSignature),
    );
    // 名稱等顯示欄位不影響連線。
    expect(
      base.connectionSignature,
      base.copyWith(name: 'x').connectionSignature,
    );
  });
}
