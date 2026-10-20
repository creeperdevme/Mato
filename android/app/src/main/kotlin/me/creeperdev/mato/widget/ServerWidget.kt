package me.creeperdev.mato.widget

import android.content.Context
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.RemoteViews
import me.creeperdev.mato.R

/** 單台伺服器小工具：CPU、記憶體、磁碟的環形圖，旁邊是網路與負載。 */
object ServerWidget : WidgetRenderer {
    /** 比這窄（約 2 格）放不下環形圖，改用長條。 */
    private const val COMPACT_WIDTH_DP = 200

    /** 放得下環形圖旁邊的網路與負載。 */
    private const val STATS_WIDTH_DP = 290

    /** 放得下作業系統與開機時間那一行。 */
    private const val SUBTITLE_HEIGHT_DP = 135

    override fun render(
        context: Context,
        widgetId: Int,
        options: Bundle,
        data: WidgetData,
    ): RemoteViews {
        val snapshot = data.snapshot
        val serverId = data.store.serverOf(widgetId)
        val server =
            snapshot.byId(serverId)
                ?: return when {
                    snapshot.servers.isEmpty() ->
                        WidgetViews.message(
                            context,
                            R.drawable.widget_ic_server,
                            R.string.widget_no_servers,
                            WidgetViews.openApp(context),
                        )
                    else ->
                        WidgetViews.message(
                            context,
                            R.drawable.widget_ic_add,
                            if (serverId == null) R.string.widget_choose_server
                            else R.string.widget_server_removed,
                            WidgetViews.pickServer(context, widgetId),
                        )
                }

        val (width, height) = WidgetViews.sizeDp(context, options)
        val compact = width in 1 until COMPACT_WIDTH_DP
        val views =
            RemoteViews(
                context.packageName,
                if (compact) R.layout.widget_server_small else R.layout.widget_server,
            )
        views.setOnClickPendingIntent(
            android.R.id.background,
            WidgetViews.openApp(context, server.id),
        )
        views.setImageViewResource(R.id.status_dot, WidgetViews.statusDot(server.status))
        views.setTextViewText(R.id.name, server.name)
        views.setTextViewText(
            R.id.updated,
            WidgetViews.updatedText(context, server.checkedAt, data.refreshing),
        )
        WidgetViews.bindRefresh(views, context, ServerWidgetProvider::class.java, data.refreshing)

        // 和 App 首頁的卡片一樣，連不上時只顯示原因，不留著過期的數字。
        val metrics = server.metrics?.takeIf { server.online }
        views.setViewVisibility(R.id.metrics, if (metrics != null) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.message_box, if (metrics != null) View.GONE else View.VISIBLE)
        if (metrics == null) {
            views.setImageViewResource(R.id.message_icon, WidgetViews.statusIcon(server.status))
            views.setTextViewText(R.id.message, WidgetViews.statusMessage(context, server))
        } else {
            for ((progress, value, percent) in
                listOf(
                    Triple(R.id.cpu_progress, R.id.cpu_value, metrics.cpu),
                    Triple(R.id.memory_progress, R.id.memory_value, metrics.memory),
                    Triple(R.id.disk_progress, R.id.disk_value, metrics.disk),
                )) {
                views.setProgressBar(
                    progress,
                    WidgetViews.PROGRESS_MAX,
                    WidgetViews.progress(percent),
                    false,
                )
                views.setTextViewText(value, WidgetViews.percent(percent))
            }
        }
        if (compact) return views

        val subtitle =
            if (metrics == null) WidgetViews.statusLabel(context, server.status)
            else
                listOf(
                        metrics.os,
                        metrics.uptime.takeIf { it.isNotEmpty() }?.let {
                            context.getString(R.string.widget_uptime, it)
                        } ?: "",
                    )
                    .filter { it.isNotEmpty() }
                    .joinToString(" · ")
        views.setTextViewText(R.id.subtitle, subtitle)
        views.setViewVisibility(
            R.id.subtitle,
            if (subtitle.isEmpty() || height in 1 until SUBTITLE_HEIGHT_DP) View.GONE
            else View.VISIBLE,
        )
        if (metrics != null) {
            val stats = width == 0 || width >= STATS_WIDTH_DP
            views.setViewVisibility(R.id.stats, if (stats) View.VISIBLE else View.GONE)
            // 沒有網路與負載那一欄時，環形圖置中。
            views.setInt(
                R.id.metrics,
                "setGravity",
                if (stats) Gravity.CENTER_VERTICAL or Gravity.START else Gravity.CENTER,
            )
            views.setTextViewText(R.id.rx, metrics.rx)
            views.setTextViewText(R.id.tx, metrics.tx)
            views.setTextViewText(R.id.load, context.getString(R.string.widget_load, metrics.load))
        }
        return views
    }
}
