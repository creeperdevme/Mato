/// 組遠端指令與 POSIX 路徑時用到的小工具。
library;

/// 以單引號包住字串，可安全放進 `sh` 指令列。
String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// 以 `sh -c` 執行，避免使用者的登入 shell（例如 fish）不吃 POSIX 語法。
String posixShell(String script) => 'sh -c ${shellQuote(script)}';

String joinRemotePath(String parent, String name) {
  if (parent.isEmpty) return name;
  if (parent.endsWith('/')) return '$parent$name';
  return '$parent/$name';
}

/// 目前路徑的上一層；已在 `/` 時回傳 null。
String? parentRemotePath(String path) {
  if (path.isEmpty || path == '/') return null;
  var trimmed = path;
  while (trimmed.length > 1 && trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final index = trimmed.lastIndexOf('/');
  return index <= 0 ? '/' : trimmed.substring(0, index);
}

String remoteBaseName(String path) {
  var trimmed = path;
  while (trimmed.length > 1 && trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final index = trimmed.lastIndexOf('/');
  return index < 0 ? trimmed : trimmed.substring(index + 1);
}

/// 把路徑拆成麵包屑：`/home/a` → `['/', '/home', '/home/a']`。
List<String> remotePathSegments(String path) {
  final result = <String>['/'];
  var current = '';
  for (final part in path.split('/')) {
    if (part.isEmpty) continue;
    current = '$current/$part';
    result.add(current);
  }
  return result;
}

/// 把八進位權限轉成 `rwxr-xr-x`。
String permissionString(int mode) {
  const flags = 'rwxrwxrwx';
  final buffer = StringBuffer();
  for (var i = 0; i < 9; i++) {
    final bit = 1 << (8 - i);
    buffer.write(mode & bit != 0 ? flags[i] : '-');
  }
  return buffer.toString();
}
