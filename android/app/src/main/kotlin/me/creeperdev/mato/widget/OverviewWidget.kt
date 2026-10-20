package me.creeperdev.mato.widget

import android.content.Context
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import me.creeperdev.mato.R

/** 伺服器總覽：每台伺服器一列，顯示狀態與 CPU、記憶體、磁碟。 */
object OverviewWidget : WidgetRenderer {
    /** 標題、欄位名稱與上下留白的高度。 */
    private const val CHROME_HEIGHT_DP = 64

    /** 一列加上間距的高度，見 res/values/widget_styles.xml 的 WidgetRow。 */
    private const val ROW_HEIGHT_DP = 38
    private const val MAX_ROWS = 8

    /** 比這窄就只顯示 CPU 一欄。 */
    private const val COMPACT_WIDTH_DP = 250

    /** 桌面沒有提供大小時的列數。 */
    const val DEFAULT_ROWS = 3

    override fun render(
        context: Context,
        widgetId: Int,
        options: Bundle,
        data: WidgetData,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_overview)
        views.setOnClickPendingIntent(android.R.id.background, WidgetViews.openApp(context))
        WidgetViews.bindRefresh(views, context, OverviewWidgetProvider::class.java, data.refreshing)

        val (width, height) = WidgetViews.sizeDp(context, options)
        val rows =
            if (height <= 0) DEFAULT_ROWS
            else ((height - CHROME_HEIGHT_DP) / ROW_HEIGHT_DP).coerceIn(1, MAX_ROWS)
        data.store.setRows(widgetId, rows)
        val compact = width in 1 until COMPACT_WIDTH_DP
        val servers = data.snapshot.servers
        val shown = servers.take(rows)

        views.setTextViewText(
            R.id.summary,
            if (servers.isEmpty()) ""
            else context.getString(R.string.widget_summary, servers.count { it.online }, servers.size),
        )
        views.setTextViewText(
            R.id.updated,
            WidgetViews.updatedText(
                context,
                shown.mapNotNull { it.checkedAt }.maxOrNull(),
                data.refreshing,
            ),
        )
        views.setViewVisibility(R.id.columns, if (shown.any { it.online }) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.column_memory, if (compact) View.GONE else View.VISIBLE)
        views.setViewVisibility(R.id.column_disk, if (compact) View.GONE else View.VISIBLE)
        views.setViewVisibility(R.id.empty, if (servers.isEmpty()) View.VISIBLE else View.GONE)
        views.removeAllViews(R.id.rows)
        for (server in shown) views.addView(R.id.rows, row(context, server, compact))
        return views
    }

    private fun row(context: Context, server: WidgetServer, compact: Boolean): RemoteViews {
        val row = RemoteViews(context.packageName, R.layout.widget_overview_row)
        row.setOnClickPendingIntent(R.id.row, WidgetViews.openApp(context, server.id))
        row.setImageViewResource(R.id.row_dot, WidgetViews.statusDot(server.status))
        row.setTextViewText(R.id.row_name, server.name)

        val metrics = server.metrics?.takeIf { server.online }
        row.setViewVisibility(R.id.row_message, if (metrics == null) View.VISIBLE else View.GONE)
        row.setTextViewText(R.id.row_message, WidgetViews.statusLabel(context, server.status))
        for (cell in
            listOf(
                Cell(R.id.row_cpu, R.id.row_cpu_value, R.id.row_cpu_bar, metrics?.cpu, true),
                Cell(R.id.row_memory, R.id.row_memory_value, R.id.row_memory_bar, metrics?.memory, !compact),
                Cell(R.id.row_disk, R.id.row_disk_value, R.id.row_disk_bar, metrics?.disk, !compact),
            )) {
            val value = cell.value
            if (value == null || !cell.visible) {
                row.setViewVisibility(cell.container, View.GONE)
                continue
            }
            row.setViewVisibility(cell.container, View.VISIBLE)
            row.setTextViewText(cell.text, WidgetViews.percent(value))
            row.setProgressBar(cell.bar, WidgetViews.PROGRESS_MAX, WidgetViews.progress(value), false)
        }
        return row
    }

    private class Cell(
        val container: Int,
        val text: Int,
        val bar: Int,
        val value: Double?,
        val visible: Boolean,
    )
}
