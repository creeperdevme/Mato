import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../models/ssh_key.dart';
import '../services/key_store.dart';
import '../services/server_store.dart';
import '../services/ssh_service.dart';
import '../utils/error_messages.dart';
import '../utils/format.dart';
import '../widgets/common.dart';

/// SSH 金鑰管理；[selectable] 時點選金鑰會回傳它的 id。
class KeysScreen extends StatelessWidget {
  const KeysScreen({super.key, this.selectable = false});

  final bool selectable;

  Future<void> _importFile(BuildContext context) async {
    final file = await FilePicker.pickFile(dialogTitle: '選擇私鑰檔（例如 id_ed25519）');
    if (file == null || !context.mounted) return;
    try {
      final pem = utf8.decode(await file.xFile.readAsBytes());
      if (!context.mounted) return;
      await _import(context, pem, file.name);
    } catch (error) {
      if (context.mounted) showMessage(context, '無法讀取檔案：$error', error: true);
    }
  }

  Future<void> _paste(BuildContext context) async {
    final pem = await promptText(
      context,
      title: '貼上私鑰',
      hint: '-----BEGIN OPENSSH PRIVATE KEY-----',
      multiline: true,
      monospace: true,
      confirmLabel: '下一步',
      validator: (value) => value.contains('PRIVATE KEY') ? null : '這看起來不是私鑰',
    );
    if (pem == null || !context.mounted) return;
    await _import(context, pem, '');
  }

  Future<void> _import(
    BuildContext context,
    String pem,
    String suggestedName,
  ) async {
    final keys = context.read<KeyStore>();
    var passphrase = '';
    if (SSHKeyPair.isEncryptedPem(pem)) {
      final value = await promptText(
        context,
        title: '輸入密語',
        label: '這把私鑰已加密',
        obscure: true,
      );
      if (value == null || !context.mounted) return;
      passphrase = value;
    }
    if (!context.mounted) return;
    final name = await promptText(
      context,
      title: '金鑰名稱',
      initial: suggestedName,
      hint: '例如：工作筆電、GitHub 部署',
      validator: (value) => value.trim().isEmpty ? '請輸入名稱' : null,
    );
    if (name == null || !context.mounted) return;
    try {
      final entry = await runWithProgress(
        context,
        '正在解析私鑰…',
        () =>
            keys.importKey(name: name.trim(), pem: pem, passphrase: passphrase),
      );
      if (context.mounted) showMessage(context, '已匯入 ${entry.name}');
    } catch (error) {
      if (context.mounted) {
        showMessage(context, '匯入失敗：${describeSshError(error)}', error: true);
      }
    }
  }

  Future<void> _generate(BuildContext context) async {
    final keys = context.read<KeyStore>();
    final name = await promptText(
      context,
      title: '產生 Ed25519 金鑰',
      label: '金鑰名稱',
      initial: 'mato',
      validator: (value) => value.trim().isEmpty ? '請輸入名稱' : null,
    );
    if (name == null || !context.mounted) return;
    try {
      final entry = await runWithProgress(
        context,
        '正在產生金鑰…',
        () => keys.generateEd25519(name: name.trim(), comment: name.trim()),
      );
      if (!context.mounted) return;
      await _showPublicKey(context, entry);
    } catch (error) {
      if (context.mounted) showMessage(context, '產生失敗：$error', error: true);
    }
  }

  Future<void> _showPublicKey(BuildContext context, SshKeyEntry entry) {
    return showTextOutput(
      context,
      title: '${entry.name} 公鑰',
      text: entry.publicKey,
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            _deploy(context, entry);
          },
          child: const Text('部署到伺服器'),
        ),
      ],
    );
  }

  /// 把公鑰加進伺服器的 authorized_keys（同 ssh-copy-id）。
  Future<void> _deploy(BuildContext context, SshKeyEntry entry) async {
    final store = context.read<ServerStore>();
    final ssh = context.read<SSHService>();
    final servers = store.servers;
    if (servers.isEmpty) {
      showMessage(context, '還沒有伺服器', error: true);
      return;
    }
    final target = await showDialog<ServerProfile>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('部署到哪台伺服器？'),
        children: [
          for (final server in servers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, server),
              child: ListTile(
                title: Text(server.name),
                subtitle: Text(server.address),
              ),
            ),
        ],
      ),
    );
    if (target == null || !context.mounted) return;
    try {
      final result = await runWithProgress(context, '正在部署公鑰…', () async {
        final profile = await store.resolve(target.id);
        return ssh.run(
          profile,
          KeyStore.authorizeCommand(entry.publicKey),
          interactive: true,
        );
      });
      if (!context.mounted) return;
      if (result.stdout.contains('MATO_KEY_OK')) {
        final switchAuth = await confirmAction(
          context,
          title: '部署完成',
          message: '公鑰已加入 ${target.name} 的 authorized_keys。要把這台伺服器改用此金鑰登入嗎？',
          confirmLabel: '改用金鑰',
        );
        if (switchAuth) {
          await store.updateServer(
            target.copyWith(authMethod: AuthMethod.privateKey, keyId: entry.id),
          );
          ssh.disconnect(target.id);
          if (context.mounted) showMessage(context, '${target.name} 已改用金鑰登入');
        }
      } else {
        showMessage(context, '部署失敗：${result.text.trim()}', error: true);
      }
    } catch (error) {
      if (context.mounted) {
        showMessage(context, '部署失敗：${describeSshError(error)}', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = context.watch<KeyStore>().keys;
    final servers = context.watch<ServerStore>().servers;

    return Scaffold(
      appBar: AppBar(title: Text(selectable ? '選擇私鑰' : 'SSH 金鑰')),
      floatingActionButton: PopupMenuButton<String>(
        tooltip: '新增金鑰',
        onSelected: (value) {
          switch (value) {
            case 'generate':
              _generate(context);
            case 'file':
              _importFile(context);
            case 'paste':
              _paste(context);
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: 'generate',
            child: ListTile(
              leading: Icon(Icons.auto_fix_high_rounded),
              title: Text('產生新金鑰（Ed25519）'),
            ),
          ),
          PopupMenuItem(
            value: 'file',
            child: ListTile(
              leading: Icon(Icons.file_open_outlined),
              title: Text('從檔案匯入'),
            ),
          ),
          PopupMenuItem(
            value: 'paste',
            child: ListTile(
              leading: Icon(Icons.content_paste_rounded),
              title: Text('貼上私鑰'),
            ),
          ),
        ],
        child: const IgnorePointer(
          child: FloatingActionButton.extended(
            onPressed: null,
            icon: Icon(Icons.add_rounded),
            label: Text('新增金鑰'),
          ),
        ),
      ),
      body: keys.isEmpty
          ? const EmptyState(
              icon: Icons.vpn_key_outlined,
              title: '還沒有 SSH 金鑰',
              message:
                  '產生一把新的 Ed25519 金鑰，或匯入現有的 OpenSSH／PEM 私鑰。'
                  '私鑰只會存在這台裝置的安全儲存區。',
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: keys.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final entry = keys[index];
                final usedBy = servers
                    .where((server) => server.keyId == entry.id)
                    .map((server) => server.name)
                    .toList();
                return ReadableWidth(
                  child: SurfaceCard(
                    padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
                    onTap: selectable
                        ? () => Navigator.pop(context, entry.id)
                        : () => _showPublicKey(context, entry),
                    child: Row(
                      children: [
                        Icon(
                          Icons.vpn_key_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      entry.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  TagChip(label: entry.type),
                                  if (entry.encrypted) ...[
                                    const SizedBox(width: 6),
                                    const TagChip(
                                      label: '有密語',
                                      icon: Icons.lock_outline,
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                entry.fingerprint,
                                style: monoStyle(fontSize: 11.5),
                              ),
                              Text(
                                usedBy.isEmpty
                                    ? '建立於 ${formatDateTime(entry.createdAt)}'
                                    : '使用中：${usedBy.join('、')}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                        if (!selectable)
                          PopupMenuButton<String>(
                            onSelected: (value) async {
                              final keyStore = context.read<KeyStore>();
                              switch (value) {
                                case 'copy':
                                  await copyText(
                                    context,
                                    entry.publicKey,
                                    label: '公鑰',
                                  );
                                case 'deploy':
                                  await _deploy(context, entry);
                                case 'rename':
                                  final name = await promptText(
                                    context,
                                    title: '重新命名',
                                    initial: entry.name,
                                  );
                                  if (name != null && name.trim().isNotEmpty) {
                                    await keyStore.rename(
                                      entry.id,
                                      name.trim(),
                                    );
                                  }
                                case 'delete':
                                  final ok = await confirmAction(
                                    context,
                                    title: '刪除金鑰',
                                    message: usedBy.isEmpty
                                        ? '確定要刪除「${entry.name}」嗎？'
                                        : '「${entry.name}」正被 ${usedBy.join('、')} 使用，刪除後這些伺服器將無法用金鑰登入。',
                                    confirmLabel: '刪除',
                                    destructive: true,
                                  );
                                  if (ok) await keyStore.delete(entry.id);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(value: 'copy', child: Text('複製公鑰')),
                              PopupMenuItem(
                                value: 'deploy',
                                child: Text('部署到伺服器'),
                              ),
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('重新命名'),
                              ),
                              PopupMenuItem(value: 'delete', child: Text('刪除')),
                            ],
                          )
                        else
                          const Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
