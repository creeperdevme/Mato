import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_metrics.dart';
import '../models/server_profile.dart';
import '../services/server_store.dart';
import '../services/ssh_service.dart';
import '../utils/error_messages.dart';
import '../widgets/overview_dashboard.dart';
import 'docker_screen.dart';
import 'file_manager_screen.dart';
import 'server_form_screen.dart';
import 'terminal_screen.dart';

class ServerDetailScreen extends StatefulWidget {
  const ServerDetailScreen({super.key, required this.serverId});

  final String serverId;

  @override
  State<ServerDetailScreen> createState() => _ServerDetailScreenState();
}

class _ServerDetailScreenState extends State<ServerDetailScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// 總覽頁的即時更新間隔。
  static const Duration _pollInterval = Duration(seconds: 5);

  late final TabController _tabController = TabController(
    length: 4,
    vsync: this,
  );

  ServerProfile? _connectedProfile;
  bool _loadingCredentials = true;
  String? _credentialError;

  ServerMetrics? _metrics;
  DateTime? _fetchedAt;
  bool _loadingMetrics = false;
  String? _metricsError;
  bool _autoLoadRequested = false;

  /// 是否開啟即時更新（總覽頁每 5 秒抓一次）。
  bool _autoRefresh = true;
  bool _appActive = true;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController.addListener(_handleTabChanged);
    _loadConnectedProfile();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _updatePolling();
  }

  /// 只有「總覽分頁可見 + App 在前景 + 已開啟即時更新」才輪詢，
  /// 避免在終端機或檔案管理分頁時不斷開新 SSH 連線。
  void _handleTabChanged() {
    if (_tabController.indexIsChanging) return;
    _updatePolling();
  }

  void _updatePolling() {
    final shouldPoll =
        _autoRefresh &&
        _appActive &&
        _connectedProfile != null &&
        _tabController.index == 0;
    if (!shouldPoll) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _pollTimer ??= Timer.periodic(_pollInterval, (_) {
      if (!mounted || _loadingMetrics) return;
      _loadMetrics();
    });
  }

  Future<void> _toggleAutoRefresh() async {
    setState(() => _autoRefresh = !_autoRefresh);
    _updatePolling();
    if (_autoRefresh) await _loadMetrics();
  }

  Future<void> _loadConnectedProfile() async {
    setState(() {
      _loadingCredentials = true;
      _credentialError = null;
    });

    try {
      final store = context.read<ServerStore>();
      final profile = store.servers.firstWhere(
        (server) => server.id == widget.serverId,
        orElse: () => throw StateError('找不到伺服器'),
      );
      final password = await store.getPassword(profile.id);
      if (password == null || password.isEmpty) {
        throw Exception('找不到已儲存的密碼');
      }

      if (!mounted) return;
      setState(() {
        _connectedProfile = profile.copyWith(password: password);
        _loadingCredentials = false;
      });
      _maybeAutoLoadMetrics();
      _updatePolling();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingCredentials = false;
        _credentialError = error.toString();
      });
    }
  }

  /// 進入詳情頁時自動抓一次，使用者不必先手動下拉。
  void _maybeAutoLoadMetrics() {
    if (_autoLoadRequested || _connectedProfile == null) return;
    _autoLoadRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadMetrics();
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ServerStore>();
    final profile = store.servers
        .where((server) => server.id == widget.serverId)
        .firstOrNull;
    final connectedProfile = _connectedProfile;

    return Scaffold(
      appBar: AppBar(
        title: Text(profile?.name ?? '伺服器'),
        actions: [
          if (profile != null)
            IconButton(
              tooltip: '編輯',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ServerFormScreen(server: profile),
                  ),
                );
                if (mounted) await _loadConnectedProfile();
              },
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabs: const [
            Tab(text: '總覽'),
            Tab(text: 'SSH 控制'),
            Tab(text: '檔案管理'),
            Tab(text: 'Docker'),
          ],
        ),
      ),
      body: _loadingCredentials
          ? const Center(child: CircularProgressIndicator())
          : _credentialError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_credentialError!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _loadConnectedProfile,
                      child: const Text('重試'),
                    ),
                  ],
                ),
              ),
            )
          : connectedProfile == null
          ? const Center(child: Text('無法載入伺服器'))
          : TabBarView(
              controller: _tabController,
              children: [
                ServerOverviewTab(
                  profile: connectedProfile,
                  status: profile == null
                      ? ServerStatus.unknown
                      : store.statusOf(profile.id),
                  statusMessage: profile == null
                      ? ''
                      : store.statusMessageOf(profile.id),
                  metrics: _metrics,
                  fetchedAt: _fetchedAt,
                  error: _metricsError,
                  loading: _loadingMetrics,
                  autoRefresh: _autoRefresh,
                  onToggleAutoRefresh: _toggleAutoRefresh,
                  onRefresh: _loadMetrics,
                ),
                TerminalScreen(profile: connectedProfile),
                FileManagerScreen(profile: connectedProfile),
                DockerScreen(profile: connectedProfile),
              ],
            ),
    );
  }

  Future<void> _loadMetrics() async {
    final profile = _connectedProfile;
    if (profile == null || _loadingMetrics) return;

    setState(() {
      _loadingMetrics = true;
      _metricsError = null;
    });
    try {
      final metrics = await context.read<SSHService>().fetchMetrics(profile);
      if (!mounted) return;
      setState(() {
        _metrics = metrics;
        _fetchedAt = DateTime.now();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _metricsError = describeSshError(error));
    } finally {
      if (mounted) setState(() => _loadingMetrics = false);
    }
  }
}
