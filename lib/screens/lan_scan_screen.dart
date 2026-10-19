import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/network_tools.dart';
import '../services/server_store.dart';
import '../widgets/common.dart';
import 'server_form_screen.dart';

/// 掃描區網中開著 SSH（22 埠）的主機，點一下即可新增。
class LanScanScreen extends StatefulWidget {
  const LanScanScreen({super.key});

  @override
  State<LanScanScreen> createState() => _LanScanScreenState();
}

class _LanScanScreenState extends State<LanScanScreen> {
  final List<LanHost> _hosts = [];
  StreamSubscription<LanHost>? _subscription;
  List<String> _prefixes = [];
  int _done = 0;
  int _total = 0;
  bool _scanning = false;
  int _port = 22;

  @override
  void initState() {
    super.initState();
    LanScanner.localPrefixes().then((value) {
      if (!mounted) return;
      setState(() => _prefixes = value);
      if (value.isNotEmpty) _scan();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _scan() {
    _subscription?.cancel();
    setState(() {
      _hosts.clear();
      _done = 0;
      _total = 0;
      _scanning = true;
    });
    _subscription =
        LanScanner.scan(
          port: _port,
          prefixes: _prefixes,
          onProgress: (done, total) {
            if (!mounted) return;
            setState(() {
              _done = done;
              _total = total;
            });
          },
        ).listen(
          (host) {
            if (!mounted) return;
            setState(() {
              _hosts
                ..add(host)
                ..sort(
                  (a, b) => _ipValue(a.address).compareTo(_ipValue(b.address)),
                );
            });
          },
          onDone: () {
            if (mounted) setState(() => _scanning = false);
          },
        );
  }

  static int _ipValue(String address) => address
      .split('.')
      .map((part) => int.tryParse(part) ?? 0)
      .fold(0, (value, part) => value * 256 + part);

  Future<void> _editTargets() async {
    final value = await promptText(
      context,
      title: '掃描範圍',
      label: '網段（每行一個，例如 192.168.1）',
      initial: _prefixes.join('\n'),
      multiline: true,
      monospace: true,
    );
    if (value == null) return;
    final prefixes = value
        .split(RegExp(r'[\n, ]+'))
        .map((item) => item.trim().replaceAll(RegExp(r'\.(\d+)?$'), ''))
        .where((item) => RegExp(r'^\d+\.\d+\.\d+$').hasMatch(item))
        .toSet()
        .toList();
    if (prefixes.isEmpty) return;
    setState(() => _prefixes = prefixes);
    _scan();
  }

  Future<void> _editPort() async {
    final value = await promptText(
      context,
      title: 'SSH 連接埠',
      initial: '$_port',
      keyboardType: TextInputType.number,
      validator: (value) {
        final port = int.tryParse(value.trim());
        return port == null || port < 1 || port > 65535 ? '需為 1–65535' : null;
      },
    );
    if (value == null) return;
    setState(() => _port = int.parse(value.trim()));
    _scan();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = {
      for (final server in context.watch<ServerStore>().servers) server.host,
    };
    final progress = _total == 0 ? null : _done / _total;

    return Scaffold(
      appBar: AppBar(
        title: const Text('掃描區網'),
        actions: [
          IconButton(
            tooltip: '連接埠',
            onPressed: _editPort,
            icon: const Icon(Icons.numbers_rounded),
          ),
          IconButton(
            tooltip: '掃描範圍',
            onPressed: _editTargets,
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton(
            tooltip: _scanning ? '停止' : '重新掃描',
            onPressed: _scanning
                ? () {
                    _subscription?.cancel();
                    setState(() => _scanning = false);
                  }
                : _scan,
            icon: Icon(_scanning ? Icons.stop_rounded : Icons.refresh_rounded),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: _scanning
              ? LinearProgressIndicator(value: progress, minHeight: 4)
              : const SizedBox(height: 4),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _prefixes.isEmpty
                        ? '找不到可掃描的網路介面，請按右上角設定掃描範圍。'
                        : '掃描 ${_prefixes.map((item) => '$item.0/24').join('、')} 的 $_port 埠'
                              '${_scanning ? '（$_done/$_total）' : ''}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _hosts.isEmpty
                ? EmptyState(
                    icon: Icons.radar_rounded,
                    title: _scanning ? '掃描中…' : '沒有找到 SSH 主機',
                    message: _scanning
                        ? '開著 SSH 的主機會陸續出現在這裡。'
                        : '可以調整掃描範圍或連接埠後重試。',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _hosts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final host = _hosts[index];
                      final added = known.contains(host.address);
                      return ReadableWidth(
                        child: SurfaceCard(
                          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                          onTap: () => Navigator.of(context).pushReplacement(
                            MaterialPageRoute<void>(
                              builder: (_) => ServerFormScreen(
                                prefillHost: host.address,
                                prefillPort: host.port,
                                prefillName: host.osHint.isEmpty
                                    ? host.address
                                    : '${host.osHint} ${host.address}',
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.computer_rounded,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${host.address}:${host.port}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (host.banner.isNotEmpty)
                                      Text(
                                        host.banner,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: monoStyle(fontSize: 11.5),
                                      ),
                                  ],
                                ),
                              ),
                              if (added)
                                const TagChip(label: '已新增')
                              else
                                const Icon(Icons.add_circle_outline_rounded),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
