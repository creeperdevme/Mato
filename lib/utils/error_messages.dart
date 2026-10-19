/// 把 SSH／Socket 例外轉成一般使用者看得懂的說明。
///
/// 原始例外訊息仍會由呼叫端保留（例如放在「原始輸出」），這裡只負責給
/// 使用者一個可行動的提示。
String describeSshError(Object error) {
  final raw = error.toString();
  final lower = raw.toLowerCase();

  if (lower.contains('timed out') ||
      lower.contains('timeout') ||
      lower.contains('errno = 10060') ||
      lower.contains('errno = 110')) {
    return '連線逾時：主機在時限內沒有回應。請確認 IP／連接埠是否正確、'
        '主機是否開機，或該網路是否允許 SSH 連線。';
  }

  if (lower.contains('refused') ||
      lower.contains('errno = 10061') ||
      lower.contains('errno = 111')) {
    return '連線被拒絕：該連接埠沒有提供 SSH 服務，可能是 sshd 未啟動、'
        '連接埠設定不同，或被防火牆阻擋。';
  }

  if (lower.contains('failed host lookup') ||
      lower.contains('nodename nor servname') ||
      lower.contains('no address associated')) {
    return '找不到主機：網域名稱無法解析，請檢查名稱拼音或 DNS 設定。';
  }

  if (lower.contains('network is unreachable') ||
      lower.contains('no route to host') ||
      lower.contains('host is unreachable') ||
      lower.contains('errno = 10065')) {
    return '網路不可達：目前裝置連不到該主機，請確認網路與路由。';
  }

  if (lower.contains('permission denied') ||
      lower.contains('authentication') ||
      lower.contains('auth fail') ||
      lower.contains('no supported authentication')) {
    return '驗證失敗：帳號或密碼不正確，或該帳號不允許密碼登入'
        '（可改用 SSH 金鑰）。';
  }

  if (lower.contains('handshake') || lower.contains('kex')) {
    return 'SSH 交握失敗：可能是主機金鑰或演算法不相容，請確認伺服器設定。';
  }

  if (lower.contains('connection closed') ||
      lower.contains('connection reset') ||
      lower.contains('broken pipe')) {
    return '連線中斷：主機在完成前關閉了連線，請稍後重試。';
  }

  return '發生未預期的錯誤：$raw';
}
