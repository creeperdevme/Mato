# Mato

Mato 是一款使用 Flutter 開發的跨平台 SSH 伺服器管理工具，支援 Windows、macOS、Linux、Android 與 iOS。

## 功能
- 新增伺服器：顯示名稱、主機位址、SSH 埠、帳號與密碼。
- 狀態檢查：顯示線上、離線、驗證失敗或錯誤狀態。
- 伺服器總覽：作業系統、開機時間、負載、磁碟與記憶體概況。
- SSH 控制：互動式遠端終端機。
- 檔案管理：透過 SFTP 瀏覽、新增資料夾、上傳、下載與刪除。
- Docker 管理：列出容器並執行啟動、停止、重新啟動與檢視日誌。

## 套件識別碼
`me.creeperdev.mato`

## 開發與執行
```bash
flutter pub get
flutter run -d windows
```

其他平台：

```bash
flutter run -d macos
flutter run -d linux
flutter run -d <android-device-id>
flutter run -d <ios-device-id>
```

## 驗證
```bash
flutter analyze
flutter test
flutter build windows --debug
```

## 安全注意事項
目前版本為了首次連線便利性尚未導入 known-hosts 驗證。正式部署前，建議加入主機金鑰指紋確認與長期保存機制。
