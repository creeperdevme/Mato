// 各平台的 App 圖示與原生啟動畫面資源，依 lib/widgets/mato_logo.dart 產生。
//
// 平常只檢查文字檔（向量圖、顏色、storyboard）是否和程式碼一致。修改圖案後在
// 專案根目錄執行下面的指令重新產生所有檔案（含 PNG 與 .ico），並提交結果：
//
//   MATO_UPDATE_ICONS=1 flutter test test/app_icons_test.dart
//
// 原生啟動畫面必須和 lib/screens/startup_splash.dart 的第一個畫面一致（同樣的
// 底色、位置與大小），Flutter 接手時才看不出切換。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mato/screens/startup_splash.dart';
import 'package:mato/widgets/mato_logo.dart';

const _generated = '由 test/app_icons_test.dart 產生，請勿手動修改。';

final _update = Platform.environment['MATO_UPDATE_ICONS'] == '1';

/// 檢查模式下和程式碼不一致的檔案。
final _stale = <String>[];

void main() {
  testWidgets('App 圖示與原生啟動畫面和標誌的定義一致', (tester) async {
    await tester.runAsync(() async {
      await _android();
      await _ios();
      await _macos();
      await _windows();
      await _linux();
    });
    expect(
      _stale,
      isEmpty,
      reason:
          '這些檔案和 lib/widgets/mato_logo.dart 不一致，請執行 '
          'MATO_UPDATE_ICONS=1 flutter test test/app_icons_test.dart 重新產生',
    );
  });
}

// ─── Android ────────────────────────────────────────────────────────────────

Future<void> _android() async {
  const res = 'android/app/src/main/res';
  final mark = MatoMarkGeometry.regular;

  // Android 8 起使用自適應圖示（向量）；之前的版本（minSdk 24、25）用 PNG。
  _write('$res/mipmap-anydpi-v26/ic_launcher.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<!-- $_generated -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''');
  // 漸層對齊圖示可見的中央 72 單位，與其他平台的圖示一致。
  _write(
    '$res/drawable/ic_launcher_background.xml',
    _vector('''
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="18"
                android:startY="18"
                android:endX="90"
                android:endY="90"
                android:startColor="${_argb(MatoBrand.tileStart)}"
                android:endColor="${_argb(MatoBrand.tileEnd)}" />
        </aapt:attr>
    </path>'''),
  );
  final glowRadius = mark.ledRadius * 2.3;
  _write(
    '$res/drawable/ic_launcher_foreground.xml',
    _vector('''
${_tracePath(mark, MatoBrand.trace)}
    <path android:pathData="${_circle(mark.led, glowRadius)}">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="radial"
                android:centerX="${_n(mark.led.dx)}"
                android:centerY="${_n(mark.led.dy)}"
                android:gradientRadius="${_n(glowRadius)}"
                android:startColor="${_argb(MatoBrand.led.withValues(alpha: 0.5))}"
                android:endColor="${_argb(MatoBrand.led.withValues(alpha: 0))}" />
        </aapt:attr>
    </path>
${_ledPath(mark, MatoBrand.led)}'''),
  );
  // Android 13 起的主題圖示只看形狀，由系統上色。
  _write(
    '$res/drawable/ic_launcher_monochrome.xml',
    _vector('''
${_tracePath(mark, Colors.white)}
${_ledPath(mark, Colors.white)}'''),
  );
  // 啟動畫面上未通電的標誌。
  _write(
    '$res/drawable/launch_mark.xml',
    _vector('''
${_tracePath(mark, MatoBrand.trace, alpha: MatoBrand.unlitTraceAlpha)}
${_ledPath(mark, MatoBrand.led, alpha: MatoBrand.unlitLedAlpha)}'''),
  );
  _write('$res/values/colors.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<!-- $_generated -->
<resources>
    <color name="splash_background">${_argb(MatoBrand.splash)}</color>
</resources>
''');

  const densities = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  for (final MapEntry(key: density, value: size) in densities.entries) {
    // 舊版啟動器直接顯示整張圖，四周留一點邊。
    await _writeImage(
      '$res/mipmap-$density/ic_launcher.png',
      () => _png(size, size, (canvas, area) {
        paintMatoIcon(canvas, area.deflate(size / 24), cornerRadius: 0.22);
      }),
    );
  }
}

String _vector(String body) => '''
<?xml version="1.0" encoding="utf-8"?>
<!-- $_generated -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
$body
</vector>
''';

String _tracePath(MatoMarkGeometry mark, Color color, {double alpha = 1}) {
  final points = mark.points;
  final data = [
    'M${_n(points.first.dx)},${_n(points.first.dy)}',
    for (final point in points.skip(1)) 'L${_n(point.dx)},${_n(point.dy)}',
  ].join(' ');
  return '''
    <path
        android:pathData="$data"
        android:strokeColor="${_argb(color)}"${alpha < 1 ? '\n        android:strokeAlpha="${_n(alpha)}"' : ''}
        android:strokeWidth="${_n(mark.stroke)}"
        android:strokeLineCap="round"
        android:strokeLineJoin="round" />''';
}

String _ledPath(MatoMarkGeometry mark, Color color, {double alpha = 1}) => '''
    <path
        android:pathData="${_circle(mark.led, mark.ledRadius)}"
        android:fillColor="${_argb(color)}"${alpha < 1 ? '\n        android:fillAlpha="${_n(alpha)}"' : ''} />''';

String _circle(Offset center, double radius) =>
    'M${_n(center.dx - radius)},${_n(center.dy)}'
    'a${_n(radius)},${_n(radius)} 0 1,1 ${_n(radius * 2)},0'
    'a${_n(radius)},${_n(radius)} 0 1,1 ${_n(-radius * 2)},0z';

// ─── iOS ────────────────────────────────────────────────────────────────────

/// iOS 原生啟動畫面裁切的範圍（pt），以 [StartupSplash.gridSize] 的格線為中心。
const _launchImageSize = Size(150, 86);

Future<void> _ios() async {
  const assets = 'ios/Runner/Assets.xcassets';
  // 圖示由系統裁成圓角，這裡畫滿整張且不能帶 alpha（App Store 規定）。
  final icons = jsonDecode(
    File('$assets/AppIcon.appiconset/Contents.json').readAsStringSync(),
  )['images'] as List;
  for (final image in icons.cast<Map<String, dynamic>>()) {
    final points = double.parse((image['size'] as String).split('x').first);
    final scale = int.parse((image['scale'] as String).replaceAll('x', ''));
    final size = (points * scale).round();
    await _writeImage(
      '$assets/AppIcon.appiconset/${image['filename']}',
      () => _png(size, size, opaque: true, (canvas, area) {
        paintMatoIcon(canvas, area);
      }),
    );
  }

  for (final scale in [1, 2, 3]) {
    final width = (_launchImageSize.width * scale).round();
    final height = (_launchImageSize.height * scale).round();
    final suffix = scale == 1 ? '' : '@${scale}x';
    await _writeImage(
      '$assets/LaunchImage.imageset/LaunchImage$suffix.png',
      () => _png(width, height, (canvas, area) {
        paintMatoMark(
          canvas,
          Rect.fromCenter(
            center: area.center,
            width: StartupSplash.gridSize * scale,
            height: StartupSplash.gridSize * scale,
          ),
          lit: 0,
          led: 0,
        );
      }),
    );
  }

  const storyboard = 'ios/Runner/Base.lproj/LaunchScreen.storyboard';
  final splash = MatoBrand.splash;
  _write(
    storyboard,
    File(storyboard)
        .readAsStringSync()
        .replaceFirst(
          RegExp(r'<color key="backgroundColor"[^>]*/>'),
          '<color key="backgroundColor" red="${_n(splash.r, 4)}" '
          'green="${_n(splash.g, 4)}" blue="${_n(splash.b, 4)}" alpha="1" '
          'colorSpace="custom" customColorSpace="sRGB"/>',
        )
        .replaceFirst(
          RegExp(r'<image name="LaunchImage"[^>]*/>'),
          '<image name="LaunchImage" width="${_n(_launchImageSize.width)}" '
          'height="${_n(_launchImageSize.height)}"/>',
        ),
  );
}

// ─── macOS ──────────────────────────────────────────────────────────────────

Future<void> _macos() async {
  const dir = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';
  for (final size in [16, 32, 64, 128, 256, 512, 1024]) {
    // 依 macOS 圖示格線：1024 的畫布裡是 824 的連續曲率圓角方塊，下方帶陰影。
    await _writeImage(
      '$dir/app_icon_$size.png',
      () => _png(size, size, (canvas, area) {
        final tile = Rect.fromCenter(
          center: area.center,
          width: size * 824 / 1024,
          height: size * 824 / 1024,
        );
        if (size >= 64) {
          canvas.drawRSuperellipse(
            RSuperellipse.fromRectAndRadius(
              tile.shift(Offset(0, size * 0.01)),
              Radius.circular(tile.width * 0.225),
            ),
            Paint()
              ..color = Colors.black.withValues(alpha: 0.3)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.012),
          );
        }
        paintMatoIcon(canvas, tile, cornerRadius: 0.225);
      }),
    );
  }
}

// ─── Windows ────────────────────────────────────────────────────────────────

Future<void> _windows() async {
  await _writeImage('windows/runner/resources/app_icon.ico', () async {
    final images = <int, Uint8List>{};
    for (final size in [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]) {
      images[size] = await _png(size, size, (canvas, area) {
        paintMatoIcon(canvas, area.deflate(size * 0.04), cornerRadius: 0.22);
      });
    }
    return _ico(images);
  });
}

/// 多尺寸 .ico，每個尺寸直接內嵌 PNG（Windows Vista 起支援）。
Uint8List _ico(Map<int, Uint8List> images) {
  final header = ByteData(6 + 16 * images.length)
    ..setUint16(2, 1, Endian.little)
    ..setUint16(4, images.length, Endian.little);
  var offset = header.lengthInBytes;
  var entry = 6;
  for (final MapEntry(key: size, value: png) in images.entries) {
    header
      ..setUint8(entry, size >= 256 ? 0 : size)
      ..setUint8(entry + 1, size >= 256 ? 0 : size)
      ..setUint16(entry + 4, 1, Endian.little)
      ..setUint16(entry + 6, 32, Endian.little)
      ..setUint32(entry + 8, png.length, Endian.little)
      ..setUint32(entry + 12, offset, Endian.little);
    offset += png.length;
    entry += 16;
  }
  final out = BytesBuilder(copy: false)..add(header.buffer.asUint8List());
  images.values.forEach(out.add);
  return out.takeBytes();
}

// ─── Linux ──────────────────────────────────────────────────────────────────

Future<void> _linux() async {
  // 由 linux/runner/my_application.cc 載入當作視窗圖示。
  await _writeImage(
    'linux/runner/resources/app_icon.png',
    () => _png(256, 256, (canvas, area) {
      paintMatoIcon(canvas, area.deflate(256 * 0.04), cornerRadius: 0.22);
    }),
  );
}

// ─── 共用 ───────────────────────────────────────────────────────────────────

Future<Uint8List> _png(
  int width,
  int height,
  void Function(Canvas canvas, Rect area) paint, {
  bool opaque = false,
}) async {
  final recorder = ui.PictureRecorder();
  paint(
    Canvas(recorder),
    Offset.zero & Size(width.toDouble(), height.toDouble()),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  image.dispose();
  return _encodePng(
    data!.buffer.asUint8List(),
    width,
    height,
    opaque: opaque,
  );
}

/// 最小的 PNG 編碼器；[opaque] 時輸出不含 alpha 的 RGB。
Uint8List _encodePng(
  Uint8List rgba,
  int width,
  int height, {
  required bool opaque,
}) {
  final channels = opaque ? 3 : 4;
  final raw = Uint8List(height * (1 + width * channels));
  var out = 0;
  for (var y = 0; y < height; y++) {
    raw[out++] = 0; // 不做逐列濾波
    for (var x = 0; x < width; x++) {
      final pixel = (y * width + x) * 4;
      for (var c = 0; c < channels; c++) {
        raw[out++] = rgba[pixel + c];
      }
    }
  }

  final png = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = Uint8List.fromList([...ascii.encode(type), ...data]);
    png
      ..add(_uint32(data.length))
      ..add(body)
      ..add(_uint32(_crc32(body)));
  }

  chunk('IHDR', [
    ..._uint32(width),
    ..._uint32(height),
    8, // 每個色版 8 位元
    opaque ? 2 : 6, // RGB／RGBA
    0,
    0,
    0,
  ]);
  chunk('IDAT', ZLibCodec(level: 9).encode(raw));
  chunk('IEND', const []);
  return png.takeBytes();
}

List<int> _uint32(int value) => [
  value >>> 24 & 0xFF,
  value >>> 16 & 0xFF,
  value >>> 8 & 0xFF,
  value & 0xFF,
];

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >>> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

/// 數字去掉多餘的零，讓產生的 XML 好讀。
String _n(double value, [int digits = 2]) {
  final text = value.toStringAsFixed(digits);
  return text.contains('.')
      ? text.replaceFirst(RegExp(r'\.?0+$'), '')
      : text;
}

String _argb(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

void _write(String path, String content) {
  final file = File(path);
  if (_update) {
    file
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  } else if (!file.existsSync() ||
      // Windows 上 git 取出的檔案可能是 CRLF。
      file.readAsStringSync().replaceAll('\r\n', '\n') !=
          content.replaceAll('\r\n', '\n')) {
    _stale.add(path);
  }
}

/// PNG 與 .ico 在不同平台算繪的結果會有些微差異，只在更新時重畫，
/// 檢查模式下只確認檔案存在。
Future<void> _writeImage(
  String path,
  Future<List<int>> Function() render,
) async {
  final file = File(path);
  if (_update) {
    final bytes = await render();
    file
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  } else if (!file.existsSync()) {
    _stale.add(path);
  }
}
