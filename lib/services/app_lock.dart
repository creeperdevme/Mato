import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';

import 'settings_store.dart';

/// 以 Face ID／Touch ID／Windows Hello／裝置密碼鎖住 App。
class AppLockService extends ChangeNotifier with WidgetsBindingObserver {
  AppLockService(this._settings) {
    WidgetsBinding.instance.addObserver(this);
  }

  final SettingsStore _settings;
  final LocalAuthentication _auth = LocalAuthentication();
  bool _locked = false;
  bool _authenticating = false;
  DateTime? _backgroundedAt;
  String? lastError;

  bool get locked => _locked;

  /// Linux 沒有官方實作，其餘平台再詢問裝置是否支援。
  Future<bool> isSupported() async {
    if (Platform.isLinux) return false;
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  /// App 啟動時呼叫：有開啟 App 鎖就先鎖住。
  void lockOnLaunch() {
    if (_settings.appLock) {
      _locked = true;
      notifyListeners();
    }
  }

  Future<bool> authenticate({String reason = '解鎖 Mato'}) async {
    if (_authenticating) return false;
    _authenticating = true;
    lastError = null;
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
      return ok;
    } on LocalAuthException catch (error) {
      lastError = error.description ?? error.code.name;
      return false;
    } catch (error) {
      lastError = error.toString();
      return false;
    } finally {
      _authenticating = false;
    }
  }

  Future<void> unlock() async {
    if (await authenticate()) {
      _locked = false;
    }
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_authenticating || !_settings.appLock) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      _backgroundedAt = null;
      if (since != null &&
          DateTime.now().difference(since).inSeconds >=
              _settings.appLockDelay) {
        _locked = true;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
