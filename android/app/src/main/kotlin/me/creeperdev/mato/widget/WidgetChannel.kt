package me.creeperdev.mato.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** 背景更新時交給 Dart 端的參數，以及完成時的通知。 */
class RefreshSession(val request: Map<String, Any>, val onDone: () -> Unit)

/**
 * 和 Dart 端（lib/services/home_widget_service.dart）溝通的通道。App 開著時由
 * MainActivity 建立；背景更新時由 [WidgetRefresher] 建在背景引擎上，並帶著 [session]。
 */
class WidgetChannel(
    private val context: Context,
    messenger: BinaryMessenger,
    private val session: RefreshSession? = null,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, NAME)
    private val store = WidgetStore(context)
    private var pendingLaunch: String? = null

    init {
        channel.setMethodCallHandler(this)
    }

    /** 從小工具打開 App 的 Intent（冷啟動或 onNewIntent），由 Dart 端來取。 */
    fun onIntent(intent: Intent?) {
        if (intent?.action != WidgetViews.ACTION_LAUNCH) return
        // 從「最近使用的應用程式」回來時，系統會再送一次當初啟動 App 的 Intent。
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        pendingLaunch = intent.dataString
        // Dart 端還沒準備好時會在啟動後自己來取（takeLaunch）。
        channel.invokeMethod("launchPending", null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "load" -> result.success(store.snapshotJson)
            "save" -> {
                store.snapshotJson = call.arguments as? String
                Widgets.updateAll(context)
                WidgetRefresher.schedule(context)
                result.success(null)
            }
            "takeLaunch" -> {
                result.success(pendingLaunch)
                pendingLaunch = null
            }
            "pin" -> result.success(pin(call.argument("kind"), call.argument("serverId")))
            "refreshRequest" -> result.success(session?.request)
            "refreshDone" -> {
                result.success(null)
                session?.onDone?.invoke()
            }
            else -> result.notImplemented()
        }
    }

    /** 請桌面加入小工具；Android 8 起且桌面支援時才有。 */
    private fun pin(kind: String?, serverId: String?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = context.getSystemService(AppWidgetManager::class.java) ?: return false
        if (!manager.isRequestPinAppWidgetSupported) return false
        val provider =
            if (kind == "server") ServerWidgetProvider::class.java
            else OverviewWidgetProvider::class.java
        store.pendingPinServer = serverId
        // 桌面放好後會在這個 Intent 補上小工具 ID 送回來，所以要是可變的。
        val mutable =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
        val callback =
            PendingIntent.getBroadcast(
                context,
                0,
                Intent(context, provider)
                    .setAction(MatoWidgetProvider.ACTION_PINNED)
                    .putExtra(MatoWidgetProvider.EXTRA_SERVER_ID, serverId),
                PendingIntent.FLAG_UPDATE_CURRENT or mutable,
            )
        return manager.requestPinAppWidget(ComponentName(context, provider), null, callback)
    }

    companion object {
        const val NAME = "me.creeperdev.mato/home_widget"
    }
}
