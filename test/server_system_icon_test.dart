import 'package:flutter_test/flutter_test.dart';
import 'package:mato/widgets/server_system_icon.dart';

void main() {
  test('os-release ID takes priority over release names and normalizes aliases', () {
    expect(
      ServerSystem.resolve(osId: '  RHEL  ', osName: 'Ubuntu 24.04 LTS'),
      ServerSystem.redHat,
    );
    expect(
      ServerSystem.resolve(osId: 'opensuse-tumbleweed'),
      ServerSystem.opensuse,
    );
    expect(ServerSystem.resolve(osId: 'raspios'), ServerSystem.raspberryPi);
    expect(ServerSystem.resolve(osId: 'archlinux'), ServerSystem.arch);
    // Do not misidentify a custom distribution by a parent's name in its title.
    expect(
      ServerSystem.resolve(osId: 'custom', osName: 'Ubuntu-based Custom Linux'),
      ServerSystem.linux,
    );
  });

  test('hosts without an ID use versioned release names', () {
    expect(
      ServerSystem.resolve(osName: 'Ubuntu 24.04.1 LTS'),
      ServerSystem.ubuntu,
    );
    expect(
      ServerSystem.resolve(osName: ' Debian GNU/Linux 13 (trixie) '),
      ServerSystem.debian,
    );
    expect(
      ServerSystem.resolve(osName: 'Raspberry Pi OS Lite'),
      ServerSystem.raspberryPi,
    );
    expect(ServerSystem.resolve(osName: 'Linux Mint 22'), ServerSystem.mint);
    expect(
      ServerSystem.resolve(osName: 'openSUSE Leap 16.0'),
      ServerSystem.opensuse,
    );
  });

  test(
    'distinguishes unknown Linux releases from servers not yet connected',
    () {
      expect(ServerSystem.resolve(), ServerSystem.unknown);
      expect(
        ServerSystem.resolve(osId: ' ', osName: '  '),
        ServerSystem.unknown,
      );
      expect(ServerSystem.resolve(osId: 'amzn'), ServerSystem.linux);
      expect(
        ServerSystem.resolve(osName: 'Custom Server Linux'),
        ServerSystem.linux,
      );
      expect(
        ServerSystem.resolve(osName: 'Not Ubuntu 24.04'),
        ServerSystem.linux,
      );
    },
  );
}
