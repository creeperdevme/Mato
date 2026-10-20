import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/home_widget_service.dart';
import '../services/server_store.dart';
import '../widgets/common.dart';
import '../widgets/mato_logo.dart';
import 'home_screen.dart';
import 'scripts_screen.dart';
import 'server_actions.dart';
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
  StreamSubscription<String>? _widgetOpens;

  @override
  void initState() {
    super.initState();
    // 點了主畫面小工具上的伺服器：直接打開那台。
    final widgets = context.read<HomeWidgetService?>();
    if (widgets == null) return;
    _widgetOpens = widgets.openRequests.listen(_openFromWidget);
    final pending = widgets.takePendingOpen();
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openFromWidget(pending),
      );
    }
  }

  @override
  void dispose() {
    _widgetOpens?.cancel();
    super.dispose();
  }

  void _openFromWidget(String serverId) {
    if (!mounted || context.read<ServerStore>().byId(serverId) == null) return;
    // 已經停在這台的頁面（例如從小工具開過、回桌面後又點一次）就不再疊一層。
    // popUntil 第一次就回傳 true，只是用來看最上層的路由，不會關掉任何頁面。
    var current = '';
    Navigator.of(context).popUntil((route) {
      current = route.settings.name ?? '';
      return true;
    });
    if (current == serverRouteName(serverId)) return;
    unawaited(openServer(context, serverId));
  }

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
