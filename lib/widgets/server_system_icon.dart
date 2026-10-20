import 'package:flutter/material.dart';

/// Bundled Font Logos glyphs; keep IconData constant for release tree shaking.
enum ServerSystem {
  unknown('伺服器', Icons.dns_rounded),
  linux('Linux', IconData(0xf31a, fontFamily: 'ServerSystems')),
  ubuntu(
    'Ubuntu',
    IconData(0xf31b, fontFamily: 'ServerSystems'),
    Color(0xFFE95420),
  ),
  debian(
    'Debian',
    IconData(0xf306, fontFamily: 'ServerSystems'),
    Color(0xFFA80030),
  ),
  fedora(
    'Fedora',
    IconData(0xf30a, fontFamily: 'ServerSystems'),
    Color(0xFF51A2DA),
  ),
  centos(
    'CentOS',
    IconData(0xf304, fontFamily: 'ServerSystems'),
    Color(0xFF932279),
  ),
  redHat(
    'Red Hat Enterprise Linux',
    IconData(0xf316, fontFamily: 'ServerSystems'),
    Color(0xFFEE0000),
  ),
  rocky(
    'Rocky Linux',
    IconData(0xf32b, fontFamily: 'ServerSystems'),
    Color(0xFF10B981),
  ),
  alma(
    'AlmaLinux',
    IconData(0xf31d, fontFamily: 'ServerSystems'),
    Color(0xFF0F4266),
  ),
  alpine(
    'Alpine Linux',
    IconData(0xf300, fontFamily: 'ServerSystems'),
    Color(0xFF0D597F),
  ),
  arch(
    'Arch Linux',
    IconData(0xf303, fontFamily: 'ServerSystems'),
    Color(0xFF1793D1),
  ),
  manjaro(
    'Manjaro',
    IconData(0xf312, fontFamily: 'ServerSystems'),
    Color(0xFF35BF5C),
  ),
  opensuse(
    'openSUSE',
    IconData(0xf314, fontFamily: 'ServerSystems'),
    Color(0xFF73BA25),
  ),
  raspberryPi(
    'Raspberry Pi OS',
    IconData(0xf315, fontFamily: 'ServerSystems'),
    Color(0xFFC51A4A),
  ),
  mint(
    'Linux Mint',
    IconData(0xf30e, fontFamily: 'ServerSystems'),
    Color(0xFF87CF3E),
  ),
  gentoo(
    'Gentoo',
    IconData(0xf30d, fontFamily: 'ServerSystems'),
    Color(0xFF9784C7),
  ),
  nixos(
    'NixOS',
    IconData(0xf313, fontFamily: 'ServerSystems'),
    Color(0xFF7EBAE4),
  ),
  kali(
    'Kali Linux',
    IconData(0xf327, fontFamily: 'ServerSystems'),
    Color(0xFF557C94),
  ),
  freebsd(
    'FreeBSD',
    IconData(0xf30c, fontFamily: 'ServerSystems'),
    Color(0xFFAB2B28),
  ),
  macos('macOS', IconData(0xf302, fontFamily: 'ServerSystems')),
  windows('Windows', Icons.window_rounded, Color(0xFF0078D4));

  const ServerSystem(this.label, this.icon, [this.color]);

  final String label;
  final IconData icon;
  final Color? color;

  static const _ids = {
    'linux': linux,
    'ubuntu': ubuntu,
    'debian': debian,
    'fedora': fedora,
    'centos': centos,
    'rhel': redHat,
    'redhat': redHat,
    'rocky': rocky,
    'almalinux': alma,
    'alpine': alpine,
    'arch': arch,
    'archlinux': arch,
    'archarm': arch,
    'manjaro': manjaro,
    'opensuse': opensuse,
    'opensuse-leap': opensuse,
    'opensuse-tumbleweed': opensuse,
    'opensuse-slowroll': opensuse,
    'raspbian': raspberryPi,
    'raspios': raspberryPi,
    'linuxmint': mint,
    'gentoo': gentoo,
    'nixos': nixos,
    'kali': kali,
    'freebsd': freebsd,
    'macos': macos,
    'darwin': macos,
    'windows': windows,
  };

  /// Prefer os-release ID; use PRETTY_NAME only on hosts without an ID.
  static ServerSystem resolve({String osId = '', String osName = ''}) {
    final id = osId.trim().toLowerCase();
    if (id.isNotEmpty) return _ids[id] ?? linux;

    final name = osName.trim().toLowerCase();
    if (name.isEmpty) return unknown;
    if (name.startsWith('raspberry pi') || name.startsWith('raspbian')) {
      return raspberryPi;
    }
    if (name.startsWith('linux mint')) return mint;
    if (name.startsWith('red hat')) return redHat;
    for (final system in values) {
      final prefix = system.label.toLowerCase();
      if (name == prefix ||
          name.startsWith('$prefix ') ||
          name.startsWith('$prefix/')) {
        return system;
      }
    }
    // All metrics currently come from Linux; an unrecognized release still
    // gets Tux, while a server with no system information keeps the server icon.
    return linux;
  }
}

class ServerSystemIcon extends StatelessWidget {
  const ServerSystemIcon({
    super.key,
    this.osId = '',
    this.osName = '',
    this.size = 24,
    this.color,
  });

  final String osId;
  final String osName;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final system = ServerSystem.resolve(osId: osId, osName: osName);
    return Icon(
      system.icon,
      size: size,
      color: color,
      semanticLabel: osName.trim().isEmpty ? system.label : osName.trim(),
    );
  }
}
