import 'package:flutter_test/flutter_test.dart';

import 'package:mato/models/server_profile.dart';

void main() {
  test('ServerProfile round-trips JSON without persisting the password', () {
    final server = ServerProfile(
      id: 'test-id',
      name: 'My Server',
      host: 'example.com',
      port: 2222,
      username: 'root',
      password: 'secret',
      createdAt: DateTime.utc(2026, 1, 2),
    );

    final restored = ServerProfile.fromJson(
      Map<String, dynamic>.from(server.toJson()),
    );

    expect(restored.id, server.id);
    expect(restored.name, server.name);
    expect(restored.host, server.host);
    expect(restored.port, 2222);
    expect(restored.username, server.username);
    expect(restored.toJson().containsKey('password'), isFalse);
  });
}
