package me.creeperdev.mato.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.text.format.DateFormat
import android.text.format.DateUtils
import android.view.View
import android.widget.RemoteViews
import java.util.Date
import kotlin.math.roundToInt
import me.creeperdev.mato.MainActivity
import me.creeperdev.mato.R

/** 兩種小工具共用的畫面元件與點擊動作。 */
internal object WidgetViews {
    /** 從小工具打開 App 的 Intent action；網址交給 Dart 端決定要開哪個畫面。 */
    const val ACTION_LAUNCH = "me.creeperdev.mato.widget.LAUNCH"

    /** 環形圖與長條的進度以千分比設定，見 res/values/widget_styles.xml。 */
    const val PROGRESS_MAX = 1000

    /** 打開 App；有 [serverId] 時直接進入那台伺服器。 */
    fun openApp(context: Context, serverId: String? = null): PendingIntent {
        val uri =
            if (serverId == null) Uri.parse("mato://open")
            else Uri.Builder().scheme("mato").authority("server").appendPath(serverId).build()
        val intent =
            Intent(context, MainActivity::class.java)
                .setAction(ACTION_LAUNCH)
                .setData(uri)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        // 每台伺服器的網址不同，所以各自是不同的 PendingIntent。
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** 立即在背景更新（見 [MatoWidgetProvider.onReceive]）。 */
    fun refresh(context: Context, provider: Class<out MatoWidgetProvider>): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, provider).setAction(MatoWidgetProvider.ACTION_REFRESH),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /** 選擇單台伺服器小工具要顯示哪台。 */
    fun pickServer(context: Context, widgetId: Int): PendingIntent =
        PendingIntent.getActivity(
            context,
            widgetId,
            Intent(context, ServerPickerActivity::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /** 標題列右上角的重新整理；更新中改成轉圈。 */
    fun bindRefresh(
        views: RemoteViews,
        context: Context,
        provider: Class<out MatoWidgetProvider>,
        refreshing: Boolean,
    ) {
        views.setOnClickPendingIntent(R.id.refresh, refresh(context, provider))
        views.setViewVisibility(R.id.refresh_icon, if (refreshing) View.GONE else View.VISIBLE)
        views.setViewVisibility(R.id.refresh_progress, if (refreshing) View.VISIBLE else View.GONE)
    }

    /** 提示畫面（沒有伺服器、還沒選擇等），整個小工具點下去執行 [action]。 */
    fun message(context: Context, icon: Int, text: Int, action: PendingIntent) =
        RemoteViews(context.packageName, R.layout.widget_message).apply {
            setImageViewResource(R.id.message_icon, icon)
            setTextViewText(R.id.message, context.getString(text))
            setOnClickPendingIntent(android.R.id.background, action)
        }

    fun statusDot(status: String) =
        when (status) {
            "online" -> R.drawable.widget_dot_online
            "checking" -> R.drawable.widget_dot_checking
            "authFailed" -> R.drawable.widget_dot_warning
            "offline", "error" -> R.drawable.widget_dot_error
            else -> R.drawable.widget_dot_unknown
        }

    fun statusIcon(status: String) =
        when (status) {
            "offline" -> R.drawable.widget_ic_offline
            "authFailed" -> R.drawable.widget_ic_lock
            "error" -> R.drawable.widget_ic_error
            else -> R.drawable.widget_ic_cloud
        }

    fun statusLabel(context: Context, status: String): String =
        context.getString(
            when (status) {
                "online" -> R.string.widget_status_online
                "checking" -> R.string.widget_status_checking
                "offline" -> R.string.widget_status_offline
                "authFailed" -> R.string.widget_status_auth_failed
                "error" -> R.string.widget_status_error
                else -> R.string.widget_status_unknown
            }
        )

    /** 不是線上時的說明；還沒檢查過的伺服器提示可以立即更新。 */
    fun statusMessage(context: Context, server: WidgetServer): String =
        server.message.ifEmpty {
            if (server.checkedAt == null) context.getString(R.string.widget_not_checked)
            else statusLabel(context, server.status)
        }

    /**
     * 資料的時間：今天只顯示時刻，其他日子加上日期。小工具不會自己重畫，
     * 所以不用「5 分鐘前」這種會過期的寫法。
     */
    fun updatedText(context: Context, millis: Long?, refreshing: Boolean): String =
        when {
            refreshing -> context.getString(R.string.widget_updating)
            millis == null || millis <= 0 -> ""
            DateUtils.isToday(millis) -> DateFormat.getTimeFormat(context).format(Date(millis))
            else ->
                DateUtils.formatDateTime(
                    context,
                    millis,
                    DateUtils.FORMAT_SHOW_DATE or
                        DateUtils.FORMAT_NUMERIC_DATE or
                        DateUtils.FORMAT_NO_YEAR or
                        DateUtils.FORMAT_SHOW_TIME,
                )
        }

    fun percent(value: Double) = "${value.coerceIn(0.0, 100.0).roundToInt()}%"

    fun progress(value: Double) = (value.coerceIn(0.0, 100.0) * PROGRESS_MAX / 100).roundToInt()

    /** 小工具目前的寬高（dp）；桌面沒有提供時是 0。 */
    fun sizeDp(context: Context, options: Bundle): Pair<Int, Int> {
        // 直向時寬度取最小、高度取最大，橫向時相反（AppWidgetManager 的慣例）。
        val landscape =
            context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val width =
            options.getInt(
                if (landscape) AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH
                else AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH
            )
        val height =
            options.getInt(
                if (landscape) AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT
                else AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT
            )
        return width to height
    }
}
