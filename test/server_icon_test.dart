import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mato/models/server_metrics.dart';
import 'package:mato/models/server_profile.dart';
import 'package:mato/screens/home_screen.dart';
import 'package:mato/screens/server_form_screen.dart';
import 'package:mato/services/key_store.dart';
import 'package:mato/services/monitor_service.dart';
import 'package:mato/services/port_forward_service.dart';
import 'package:mato/services/server_store.dart';
import 'package:mato/services/settings_store.dart';
import 'package:mato/services/ssh_service.dart';
import 'package:mato/services/terminal_hub.dart';
import 'package:mato/widgets/server_system_icon.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// 伺服器清單在 SharedPreferences 裡的鍵（見 [ServerStore]）。
const _serversKey = 'mato.servers.v1';

/// 1x1 的透明 PNG；測試只在意位元組有沒有原封不動寫進去。
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

/// 假的 path_provider：把「應用程式支援目錄」指到暫存資料夾，
/// 讓 [ServerStore.initIconStorage] 在測試裡也能真的建目錄、寫檔案。
class _IconHome {
  _IconHome() : dir = Directory.systemTemp.createTempSync('mato-icons');

  static const _channel = MethodChannel('plugins.flutter.io/path_provider');

  final Directory dir;

  Directory get icons => Directory('${dir.path}/server_icons');

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          _channel,
          (call) async => call.method == 'getApplicationSupportDirectory'
              ? dir.path
              : null,
        );
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

Future<ServerStore> _store() async {
  final store = ServerStore(storage: FakeSecureStorage());
  await store.load();
  await store.initIconStorage();
  return store;
}

class _OfflineSsh extends SSHService {
  @override
  Future<ServerMetrics> fetchMetrics(
    ServerProfile profile, {
    bool interactive = false,
  }) async => throw const SocketException('測試環境不連線');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('寫入自訂圖示後拿得到路徑，移除後檔案消失', () async {
    final home = _IconHome()..install();
    addTearDown(home.dispose);
    final store = await _store();

    expect(store.iconPathOf(''), isNull);

    final name = await store.writeIcon(_png, extension: '.PNG');
    expect(name, endsWith('.png'));
    final path = store.iconPathOf(name)!;
    expect(File(path).existsSync(), isTrue);
    expect(File(path).readAsBytesSync(), _png);

    await store.clearIcon(name);
    expect(File(path).existsSync(), isFalse);
  });

  test('副檔名不會被拿來跳出圖示資料夾', () async {
    final home = _IconHome()..install();
    addTearDown(home.dispose);
    final store = await _store();

    final name = await store.writeIcon(_png, extension: '../../evil.png');
    expect(name, isNot(contains('/')));
    expect(store.iconPathOf(name)!.startsWith(home.icons.path), isTrue);
  });

  test('換圖後舊圖會被刪掉，但還有其他伺服器在用時會保留', () async {
    final home = _IconHome()..install();
    addTearDown(home.dispose);
    final store = await _store();
    final first = await store.addServer(testProfile(id: '1'));
    final second = await store.addServer(testProfile(id: '2'));

    final shared = await store.writeIcon(_png);
    await store.updateServer(first.copyWith(iconName: shared));
    await store.updateServer(second.copyWith(iconName: shared));

    // 換掉第一台的圖：第二台還在用同一張，檔案不能刪。
    final other = await store.writeIcon(_png);
    await store.updateServer(first.copyWith(iconName: other));
    expect(File(store.iconPathOf(shared)!).existsSync(), isTrue);

    // 第二台也換掉之後，舊圖才真的沒人用。
    await store.updateServer(second.copyWith(iconName: other));
    expect(File(store.iconPathOf(shared)!).existsSync(), isFalse);
  });

  test('複製伺服器會複製一份圖示，刪掉其中一台不影響另一台', () async {
    final home = _IconHome()..install();
    addTearDown(home.dispose);
    final store = await _store();
    final icon = await store.writeIcon(_png);
    final source = await store.addServer(testProfile(id: '1').copyWith(iconName: icon));

    final copy = (await store.duplicate(source.id))!;
    expect(copy.iconName, isNotEmpty);
    expect(copy.iconName, isNot(icon));
    expect(File(store.iconPathOf(copy.iconName)!).existsSync(), isTrue);

    await store.deleteServer(source.id);
    expect(File(store.iconPathOf(icon)!).existsSync(), isFalse);
    expect(File(store.iconPathOf(copy.iconName)!).existsSync(), isTrue);
  });

  test('啟動時先建立圖示儲存區，也不會把既有的自訂圖示當孤兒刪掉', () async {
    final home = _IconHome()..install();
    addTearDown(home.dispose);
    home.icons.createSync(recursive: true);
    File('${home.icons.path}/keep.png').writeAsBytesSync(_png);
    File('${home.icons.path}/orphan.png').writeAsBytesSync(_png);
    SharedPreferences.setMockInitialValues({
      _serversKey: jsonEncode([
        testProfile(id: '1').copyWith(iconName: 'keep.png').toJson(),
      ]),
    });

    final store = ServerStore(storage: FakeSecureStorage());
    // main() 是並行呼叫這兩個；清孤兒檔時清單還沒載入就會把 keep.png 刪掉。
    await store.initIconStorage();
    await store.load();

    expect(store.servers.single.iconName, 'keep.png');
    expect(File('${home.icons.path}/keep.png').existsSync(), isTrue);
    // 真的沒人用的孤兒檔還是要清掉。
    expect(File('${home.icons.path}/orphan.png').existsSync(), isFalse);
  });

  test('先載入清單再建立圖示儲存區，孤兒檔一樣會被清掉', () async {
    final home = _IconHome()..install();
    addTearDown(home.dispose);
    home.icons.createSync(recursive: true);
    File('${home.icons.path}/keep.png').writeAsBytesSync(_png);
    File('${home.icons.path}/orphan.png').writeAsBytesSync(_png);
    SharedPreferences.setMockInitialValues({
      _serversKey: jsonEncode([
        testProfile(id: '1').copyWith(iconName: 'keep.png').toJson(),
      ]),
    });

    final store = ServerStore(storage: FakeSecureStorage());
    await store.load();
    await store.initIconStorage();

    expect(File('${home.icons.path}/keep.png').existsSync(), isTrue);
    expect(File('${home.icons.path}/orphan.png').existsSync(), isFalse);
  });

  test('iconName 會存進 JSON，舊資料沒有這個欄位也能讀', () {
    final saved = testProfile().copyWith(iconName: 'abc.png');
    expect(saved.toJson()['iconName'], 'abc.png');
    expect(ServerProfile.fromJson(saved.toJson()).iconName, 'abc.png');

    final legacy = testProfile().toJson()..remove('iconName');
    expect(ServerProfile.fromJson(legacy).iconName, '');
  });

  testWidgets('伺服器卡片有自訂圖示時顯示圖片，沒有時用系統圖示', (tester) async {
    final home = _IconHome()..install();
    addTearDown(home.dispose);
    final settings = SettingsStore(storage: FakeSecureStorage());
    final servers = ServerStore(storage: FakeSecureStorage());
    final ssh = _OfflineSsh();
    // 真的檔案 I/O（建立圖示區、寫檔）要放在 runAsync，否則是 fake async 下
    // 永遠不會完成的 future。
    final icon = await tester.runAsync(() async {
      await settings.load();
      await servers.load();
      await servers.initIconStorage();
      final icon = await servers.writeIcon(_png);
      await servers.addServer(testProfile(id: '1').copyWith(iconName: icon));
      await servers.addServer(testProfile(id: '2'));
      return icon;
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: servers),
          ChangeNotifierProvider.value(
            value: MonitorService(ssh: ssh, store: servers, settings: settings),
          ),
          ChangeNotifierProvider.value(value: PortForwardService()),
          ChangeNotifierProvider.value(value: TerminalHub(ssh)),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final custom = tester.widget<ServerCustomImage>(
      find.byType(ServerCustomImage),
    );
    expect(custom.path, servers.iconPathOf(icon!));
    // 另一台沒有自訂圖示，維持發行版圖示。
    expect(find.byType(ServerSystemIcon), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('伺服器表單可以預覽與移除自訂圖示', (tester) async {
    final home = _IconHome()..install();
    addTearDown(home.dispose);
    final servers = ServerStore(storage: FakeSecureStorage());
    final keys = KeyStore(storage: FakeSecureStorage());
    final profile = await tester.runAsync(() async {
      await servers.load();
      await servers.initIconStorage();
      await keys.load();
      final icon = await servers.writeIcon(_png);
      return servers.addServer(testProfile(id: '1').copyWith(iconName: icon));
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: servers),
          ChangeNotifierProvider.value(value: keys),
        ],
        child: MaterialApp(home: ServerFormScreen(server: profile)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('自訂圖示（選填）'), findsOneWidget);
    final path = servers.iconPathOf(profile!.iconName);
    expect(
      tester.widget<ServerCustomImage>(find.byType(ServerCustomImage)).path,
      path,
    );

    await tester.ensureVisible(find.text('移除'));
    await tester.tap(find.text('移除'));
    await tester.pump();
    expect(find.byType(ServerCustomImage), findsNothing);
    expect(find.text('選擇圖片'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
