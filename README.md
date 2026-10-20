# Mato

Mato 是一款使用 Flutter 開發的跨平台 SSH 伺服器管理工具，支援 Windows、macOS、Linux、Android 與 iOS。只需要 SSH，伺服器端不必安裝任何代理程式。

## 下載

最新的自動建置版本在 [Releases › nightly](../../releases/tag/nightly)，main 有新提交時每天自動更新，下載連結固定不變：

| 平台 | 檔案 |
|---|---|
| Android | `Mato-android-arm64-v8a.apk`（多數手機）、`armeabi-v7a`、`x86_64` |
| Windows | `Mato-windows-x64.zip` |
| macOS | `Mato-macos.zip`（未公證，第一次請按右鍵 › 開啟） |
| Linux | `Mato-linux-x64.tar.gz`（需要 `libsecret-1-0`、`libgtk-3-0`） |
| iOS | `Mato-ios-unsigned.ipa`（未簽章，需自行重新簽署或用 AltStore／SideStore 安裝） |

## 功能

**伺服器與連線**
- 伺服器總覽：每台一張卡片，即時顯示 CPU、記憶體、磁碟環形圖、網路上下行與負載，可依分組篩選與搜尋。
- 登入方式：密碼、私鑰（OpenSSH／PEM，支援密語）、keyboard-interactive／2FA 驗證碼；可選擇不儲存密碼、每次詢問。
- 跳板機（ProxyJump）、SOCKS5 代理、備援位址（主要位址連不上時依序嘗試）、SSH Agent 轉發。
- 主機金鑰驗證（TOFU）：第一次連線記下指紋，之後若改變會警告並中止。
- 連線池：同一台伺服器共用一條長連線，監控、檔案、Docker 等操作不必每次重新交握。
- 區網掃描找出開著 SSH 的主機；Wake-on-LAN 喚醒；遠端重新開機／關機。

**監控**
- CPU 整體與各核心使用率、I/O 等待、溫度、型號；記憶體（已用／快取／可用）與交換空間。
- 所有掛載點容量、磁碟讀寫速度與 IOPS；網路速率與累計流量（可切換網卡）。
- NVIDIA／AMD GPU 使用率、顯示記憶體、溫度、功耗與 GPU 程序。
- 歷史曲線、平均負載、系統資訊；App 在背景時自動暫停輪詢。

**終端機**
- 多分頁，離開伺服器頁面後仍在背景保留；tmux／zellij 工作階段（斷線可接回）與附加既有 tmux。
- 行動裝置特殊鍵列：Esc、Tab、黏住的 Ctrl／Alt、方向鍵（長按連發）、常用符號。
- 快捷片段、輸入已存密碼、多行輸入（可輸入中文）、上傳檔案並貼上路徑（方便 Claude Code 等 CLI 工具讀取圖片與檔案）。
- ZMODEM：遠端執行 `sz` 下載到本機、`rz` 從本機上傳。
- 10 種配色、字級、字型、游標樣式；初始化指令；把選取內容或最近輸出交給 AI 助理。

**檔案（SFTP）**
- 麵包屑路徑、排序、隱藏檔、篩選；上傳／下載進度（大檔串流，不佔記憶體）。
- 語法高亮編輯器（行號、搜尋與取代、自動換行、保留 CRLF）、圖片預覽、大型日誌只讀尾端。
- 重新命名、權限（chmod）、MD5／SHA-256、遞迴刪除、在終端機開啟、自訂長按指令。

**程序與容器**
- 程序列表：依 CPU／記憶體／PID／名稱排序、搜尋、送出 TERM／KILL／HUP 等訊號（權限不足可改用 sudo）。
- Docker／Podman：容器啟動／停止／重新啟動／暫停／刪除、即時用量、日誌（可即時追蹤）、inspect、進入容器 shell、建立容器；映像檔拉取與刪除；磁碟區、網路與清理。

**自動化**
- 腳本庫：在多台伺服器（可依分組選取）同時執行，可用 sudo，保存執行紀錄並可重跑失敗的伺服器。
- 連接埠轉發：本機轉發（`-L`）與 SOCKS5 動態轉發（`-D`），可設定進入伺服器頁面時自動啟動。

**AI 助理**
- 使用自己的 Anthropic（Claude，預設 `claude-opus-5-5`）或 OpenAI 相容 API 金鑰。
- 可讀取監控指標、執行指令、讀寫檔案、列目錄；會修改系統的操作預設需要逐一核准。
- 計畫模式（先調查並提出計畫，核准後才執行）、附加圖片、每台伺服器保存對話紀錄。

**安全與資料**
- 密碼、私鑰與 API 金鑰存在系統安全儲存區（Keychain／Keystore／Credential Manager／libsecret）。
- App 鎖：Face ID／Touch ID／指紋／Windows Hello 或裝置密碼。
- 匯出／還原備份；包含機密時以 PBKDF2-SHA256 + AES-256-GCM 加密。

### 與 NeoServer 的差異
Mato 參考 NeoServer 的功能設計，但以下項目因平台或協定限制沒有實作：Mosh（需要 UDP 與 mosh-server 協定）、iOS 主畫面小工具與通知中心、iCloud 同步（改用加密備份檔）、Tailscale 連線類型、語音輸入。

## 開發與執行

需要 Flutter 3.44 以上（CI 使用 3.47.7）。

```bash
flutter pub get
flutter run -d windows   # 或 macos、linux、<android/ios 裝置 id>
```

## 驗證

```bash
flutter analyze
flutter test
```

App 圖示與各平台的原生啟動畫面都依 `lib/widgets/mato_logo.dart` 的標誌定義產生，`flutter test` 會檢查兩者是否一致。修改標誌後重新產生並提交：

```bash
MATO_UPDATE_ICONS=1 flutter test test/app_icons_test.dart
```

`test/e2e_ssh_test.dart` 會對真正的 SSH 伺服器測試連線池、監控腳本、SFTP、腳本、轉發、跳板機、SOCKS5 與 tmux，預設略過；要執行時設定環境變數：

```bash
MATO_E2E_HOST=127.0.0.1 MATO_E2E_PORT=22 MATO_E2E_USER=me \
MATO_E2E_KEY=~/.ssh/id_ed25519 flutter test test/e2e_ssh_test.dart
```

## Nightly 建置

`.github/workflows/nightly.yml` 每天台灣時間 03:23 檢查 main，有新提交就建置五個平台並更新 `nightly` release；也可以在 Actions 頁面手動執行。

Android 預設使用 CI 快取的 debug 金鑰簽章。若要使用正式簽章，在 repository secrets 設定：

| Secret | 內容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.jks` 的結果 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密碼 |
| `ANDROID_KEY_ALIAS` | 金鑰別名 |
| `ANDROID_KEY_PASSWORD` | 金鑰密碼 |

## 套件識別碼
`me.creeperdev.mato`
