import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/server_profile.dart';
import '../services/ai_service.dart';
import '../services/monitor_service.dart';
import '../services/network_tools.dart';
import '../services/port_forward_service.dart';
import '../services/server_store.dart';
import '../services/ssh_service.dart';
import '../services/terminal_hub.dart';
import '../utils/error_messages.dart';
import '../widgets/common.dart';
import 'server_detail_screen.dart';

/// 伺服器頁面的路由名稱，用來判斷畫面上是不是已經開著這台。
String serverRouteName(String serverId) => '/server/$serverId';

Future<void> openServer(
  BuildContext context,
  String serverId, {
  DetailSection section = DetailSection.overview,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: serverRouteName(serverId)),
      builder: (_) =>
          ServerDetailScreen(serverId: serverId, initialSection: section),
    ),
  );
}

Future<void> wakeServer(BuildContext context, ServerProfile server) async {
  try {
    await WakeOnLan.send(
      server.macAddress,
      broadcast: server.wolBroadcast,
      port: server.wolPort,
    );
    if (context.mounted) {
      showMessage(context, '已送出 Wake-on-LAN 封包到 ${server.macAddress}');
    }
  } catch (error) {
    if (context.mounted) showMessage(context, '喚醒失敗：$error', error: true);
  }
}

/// 刪除伺服器，並關閉所有跟它有關的連線、終端機、轉發與 AI 對話。
Future<bool> deleteServer(BuildContext context, ServerProfile server) async {
  final confirmed = await confirmAction(
    context,
    title: '刪除伺服器',
    message:
        '確定要刪除「${server.name}」嗎？已儲存的密碼、終端機分頁、連接埠轉發'
        '與 AI 對話也會一併移除。',
    confirmLabel: '刪除',
    destructive: true,
  );
  if (!confirmed || !context.mounted) return false;

  context.read<TerminalHub>().closeAll(server.id);
  await context.read<PortForwardService>().stopAllFor(server.id);
  if (!context.mounted) return false;
  context.read<MonitorService>().forget(server.id);
  context.read<SSHService>().disconnect(server.id);
  await context.read<AiHub>().forget(server.id);
  if (!context.mounted) return false;
  await context.read<ServerStore>().deleteServer(server.id);
  return true;
}

enum PowerAction { reboot, shutdown }

Future<void> powerAction(
  BuildContext context,
  String serverId,
  PowerAction action,
) async {
  final reboot = action == PowerAction.reboot;
  final store = context.read<ServerStore>();
  final ssh = context.read<SSHService>();
  final server = store.byId(serverId);
  if (server == null) return;
  final confirmed = await confirmAction(
    context,
    title: reboot ? '重新啟動伺服器' : '關閉伺服器',
    message: reboot
        ? '「${server.name}」會立即重新開機，所有服務與連線都會中斷。'
        : '「${server.name}」會立即關機，之後需要實體開機或 Wake-on-LAN 才能再連上。',
    confirmLabel: reboot ? '重新啟動' : '關機',
    destructive: true,
  );
  if (!confirmed || !context.mounted) return;

  try {
    final profile = await store.resolve(serverId);
    if (!profile.isRoot && profile.password.isEmpty) {
      throw const SshException('需要 sudo 權限：請在伺服器設定中儲存密碼，或使用 root 帳號。');
    }
    final command = reboot
        ? '(systemctl reboot || shutdown -r now || reboot) >/dev/null 2>&1 &'
        : '(systemctl poweroff || shutdown -h now || poweroff) >/dev/null 2>&1 &';
    final result = await ssh.runPrivileged(
      profile,
      command,
      timeout: const Duration(seconds: 15),
    );
    final denied = result.stderr.toLowerCase();
    if (denied.contains('incorrect password') ||
        denied.contains('not in the sudoers') ||
        denied.contains('a password is required')) {
      throw SshException('sudo 失敗：${result.stderr.trim()}');
    }
    ssh.disconnect(serverId);
    if (context.mounted) {
      showMessage(context, reboot ? '已送出重新啟動指令' : '已送出關機指令');
    }
  } catch (error) {
    // 關機時連線常在回應前就斷掉，這種情況視為成功。
    final message = describeSshError(error);
    final lost = message.startsWith('連線中斷');
    if (context.mounted) {
      showMessage(
        context,
        lost ? (reboot ? '伺服器正在重新啟動' : '伺服器正在關機') : '操作失敗：$message',
        error: !lost,
      );
    }
  }
}
