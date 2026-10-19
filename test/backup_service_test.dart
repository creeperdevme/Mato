import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/server_profile.dart';
import 'package:mato/services/backup_service.dart';
import 'package:mato/services/key_store.dart';
import 'package:mato/services/port_forward_service.dart';
import 'package:mato/services/script_store.dart';
import 'package:mato/services/server_store.dart';
import 'package:mato/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

class _Stores {
  _Stores() {
    keys = KeyStore(storage: storage);
    servers = ServerStore(storage: storage, keys: keys);
    scripts = ScriptStore();
    settings = SettingsStore(storage: storage);
    forwards = PortForwardService();
    backup = BackupService(
      servers: servers,
      keys: keys,
      scripts: scripts,
      settings: settings,
      forwards: forwards,
    );
  }

  final storage = FakeSecureStorage();
  late final KeyStore keys;
  late final ServerStore servers;
  late final ScriptStore scripts;
  late final SettingsStore settings;
  late final PortForwardService forwards;
  late final BackupService backup;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('加密備份可以完整還原密碼與私鑰', () async {
    final source = _Stores();
    final key = await source.keys.generateEd25519(name: 'laptop');
    final added = await source.servers.addServer(
      ServerProfile(
        id: '',
        name: 'web-01',
        host: '10.0.0.5',
        username: 'deploy',
        authMethod: AuthMethod.privateKey,
        keyId: key.id,
        createdAt: DateTime.now(),
      ),
      secrets: const ServerSecrets(password: 'sudo-pass'),
    );
    await source.scripts.seedExamples();

    final exported = await source.backup.export(
      includeSecrets: true,
      password: 'correct horse',
    );
    expect(BackupService.isEncrypted(exported), isTrue);
    expect(exported, isNot(contains('sudo-pass')));
    expect(exported, isNot(contains('PRIVATE KEY')));

    SharedPreferences.setMockInitialValues({});
    final target = _Stores();
    await expectLater(
      target.backup.import(exported, password: 'wrong password'),
      throwsA(isA<BackupPasswordException>()),
    );

    final summary = await target.backup.import(
      exported,
      password: 'correct horse',
    );
    expect(summary.servers, 1);
    expect(summary.keys, 1);
    expect(summary.scripts, source.scripts.scripts.length);

    final resolved = await target.servers.resolve(added.id);
    expect(resolved.password, 'sudo-pass');
    expect(resolved.authMethod, AuthMethod.privateKey);
    expect(resolved.privateKey, contains('BEGIN OPENSSH PRIVATE KEY'));
    expect(target.keys.byId(key.id)?.fingerprint, key.fingerprint);
  });

  test('不含機密的備份是明文，且不包含密碼', () async {
    final source = _Stores();
    await source.servers.addServer(
      ServerProfile(
        id: '',
        name: 'nas',
        host: 'nas.local',
        username: 'admin',
        createdAt: DateTime.now(),
      ),
      secrets: const ServerSecrets(password: 'hunter2'),
    );
    final exported = await source.backup.export();
    expect(BackupService.isEncrypted(exported), isFalse);
    expect(exported, contains('nas.local'));
    expect(exported, isNot(contains('hunter2')));
  });

  test('產生的 Ed25519 公鑰可用於 authorized_keys', () async {
    final stores = _Stores();
    final key = await stores.keys.generateEd25519(name: 'my key');
    expect(key.type, 'ssh-ed25519');
    expect(key.publicKey, startsWith('ssh-ed25519 AAAA'));
    expect(key.publicKey, endsWith(' my-key'));
    expect(key.fingerprint, startsWith('SHA256:'));
    expect(
      KeyStore.authorizeCommand(key.publicKey),
      contains('authorized_keys'),
    );
  });
}
