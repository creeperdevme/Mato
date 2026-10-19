import 'package:flutter/widgets.dart';

/// 讓服務層（例如 SSH 驗證）也能跳出對話框。
final navigatorKey = GlobalKey<NavigatorState>();

/// 首頁被其他頁面蓋住時暫停輪詢。
final routeObserver = RouteObserver<ModalRoute<void>>();
