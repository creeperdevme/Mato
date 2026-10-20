import 'package:flutter/material.dart';

import '../widgets/common.dart';
import '../widgets/mato_logo.dart';
import 'home_screen.dart';
import 'scripts_screen.dart';
import 'settings_screen.dart';

/// 最上層：伺服器、腳本、設定。手機用底部導覽列，寬螢幕用側邊欄。
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;
  final _visited = <int>{0};

  static const _destinations = [
    (Icons.dns_outlined, Icons.dns_rounded, '伺服器'),
    (Icons.terminal_outlined, Icons.terminal_rounded, '腳本'),
    (Icons.settings_outlined, Icons.settings_rounded, '設定'),
  ];

  void _select(int index) {
    setState(() {
      _index = index;
      _visited.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      const HomeScreen(),
      _visited.contains(1) ? const ScriptsScreen() : const SizedBox.shrink(),
      _visited.contains(2) ? const SettingsScreen() : const SizedBox.shrink(),
    ];
    final body = IndexedStack(index: _index, children: pages);

    if (isWide(context)) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: _select,
              labelType: NavigationRailLabelType.all,
              leading: const Padding(
                padding: EdgeInsets.only(top: 8, bottom: 12),
                child: MatoLogo(),
              ),
              destinations: [
                for (final (icon, selected, label) in _destinations)
                  NavigationRailDestination(
                    icon: Icon(icon),
                    selectedIcon: Icon(selected),
                    label: Text(label),
                  ),
              ],
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        height: 66,
        destinations: [
          for (final (icon, selected, label) in _destinations)
            NavigationDestination(
              icon: Icon(icon),
              selectedIcon: Icon(selected),
              label: label,
            ),
        ],
      ),
    );
  }
}
