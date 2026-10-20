package me.creeperdev.mato.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.RemoteViews

/** 依目前的資料與尺寸畫出一個小工具。 */
interface WidgetRenderer {
    fun render(context: Context, widgetId: Int, options: Bundle, data: WidgetData): RemoteViews
}

/** 畫小工具需要的資料，一次更新多個小工具時共用。 */
class WidgetData(val store: WidgetStore, val snapshot: WidgetSnapshot, val refreshing: Boolean)

/** 兩種小工具共用的 AppWidgetProvider：畫面交給 [renderer]，背景更新交給 [WidgetRefresher]。 */
abstract class MatoWidgetProvider(private val renderer: WidgetRenderer) : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, widgetIds: IntArray) {
        Widgets.update(context, javaClass, widgetIds)
        // 重新開機後系統會對每個小工具送一次更新，順便排回定時更新。
        WidgetRefresher.schedule(context)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        widgetId: Int,
        options: Bundle,
    ) {
        // 調整大小：換成適合的版面，伺服器總覽也會改變列數。
        val data = Widgets.data(context)
        manager.updateAppWidget(widgetId, renderer.render(context, widgetId, options, data))
    }

    override fun onDeleted(context: Context, widgetIds: IntArray) {
        WidgetStore(context).forget(widgetIds)
    }

    override fun onEnabled(context: Context) {
        WidgetRefresher.schedule(context)
    }

    override fun onDisabled(context: Context) {
        WidgetRefresher.schedule(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_REFRESH -> WidgetRefresher.refreshNow(context, goAsync())
            ACTION_PINNED -> {
                // 從 App 加入的單台伺服器小工具：桌面放好後才知道小工具 ID。
                val widgetId =
                    intent.getIntExtra(
                        AppWidgetManager.EXTRA_APPWIDGET_ID,
                        AppWidgetManager.INVALID_APPWIDGET_ID,
                    )
                val serverId = intent.getStringExtra(EXTRA_SERVER_ID)
                val store = WidgetStore(context)
                if (
                    widgetId != AppWidgetManager.INVALID_APPWIDGET_ID &&
                        serverId != null &&
                        store.serverOf(widgetId) == null
                ) {
                    store.setServer(widgetId, serverId)
                }
                store.pendingPinServer = null
                WidgetRefresher.refreshNow(context, goAsync())
            }
            else -> super.onReceive(context, intent)
        }
    }

    companion object {
        const val ACTION_REFRESH = "me.creeperdev.mato.widget.REFRESH"
        const val ACTION_PINNED = "me.creeperdev.mato.widget.PINNED"
        const val EXTRA_SERVER_ID = "serverId"
    }
}

class ServerWidgetProvider : MatoWidgetProvider(ServerWidget)

class OverviewWidgetProvider : MatoWidgetProvider(OverviewWidget)

/** 主畫面上所有的 Mato 小工具。 */
object Widgets {
    private val renderers: Map<Class<out MatoWidgetProvider>, WidgetRenderer> =
        mapOf(
            ServerWidgetProvider::class.java to ServerWidget,
            OverviewWidgetProvider::class.java to OverviewWidget,
        )

    fun ids(context: Context, provider: Class<out MatoWidgetProvider>): IntArray =
        AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, provider))

    fun any(context: Context) = renderers.keys.any { ids(context, it).isNotEmpty() }

    fun data(context: Context): WidgetData {
        val store = WidgetStore(context)
        return WidgetData(store, store.snapshot(), store.refreshing)
    }

    fun updateAll(context: Context) {
        val data = data(context)
        for (provider in renderers.keys) update(context, provider, ids(context, provider), data)
    }

    fun update(
        context: Context,
        provider: Class<out MatoWidgetProvider>,
        widgetIds: IntArray,
        data: WidgetData = data(context),
    ) {
        val renderer = renderers.getValue(provider)
        val manager = AppWidgetManager.getInstance(context)
        for (id in widgetIds) {
            manager.updateAppWidget(
                id,
                renderer.render(context, id, manager.getAppWidgetOptions(id), data),
            )
        }
    }
}
