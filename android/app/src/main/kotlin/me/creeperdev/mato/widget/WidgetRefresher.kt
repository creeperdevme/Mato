package me.creeperdev.mato.widget

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import java.util.concurrent.TimeUnit

/**
 * 在背景啟動一個沒有畫面的 Flutter 引擎，執行 Dart 端的 homeWidgetRefreshMain
 * （lib/services/home_widget_service.dart）：連線抓取小工具上那幾台伺服器的指標
 * 並寫回，完成後通知這裡關閉引擎。
 *
 * 同一時間只跑一輪；更新中又有人要求時，等這一輪結束一起完成。全部在主執行緒上執行。
 */
object WidgetRefresher {
    private const val TAG = "MatoWidget"
    private const val JOB_ID = 0x6D61746F

    /** Dart 端每台伺服器最多等 30 秒，這裡再多留時間給引擎啟動與寫回。 */
    private const val TIMEOUT_MS = 50_000L

    private val handler = Handler(Looper.getMainLooper())
    private val waiting = mutableListOf<() -> Unit>()
    private val timeout = Runnable { finish() }
    private var engine: FlutterEngine? = null
    private var context: Context? = null

    /**
     * 使用者按下重新整理或剛設定好小工具時，在廣播接收器裡呼叫：[pending] 讓
     * 行程撐到更新完成，不會一離開 onReceive 就被系統凍結。
     */
    fun refreshNow(context: Context, pending: BroadcastReceiver.PendingResult) =
        refresh(context, manual = true) { pending.finish() }

    /** [manual] 為 false 時，Dart 端會略過剛檢查過與驗證失敗的伺服器。 */
    fun refresh(context: Context, manual: Boolean, done: () -> Unit) {
        waiting += done
        if (engine != null) return
        val app = context.applicationContext
        this.context = app
        WidgetStore(app).refreshingSince = System.currentTimeMillis()
        Widgets.updateAll(app)
        try {
            val started = FlutterEngine(app)
            engine = started
            WidgetChannel(
                app,
                started.dartExecutor.binaryMessenger,
                RefreshSession(request(app, manual)) {
                    // 逾時後才回報的舊引擎不影響下一輪。
                    handler.post { if (engine === started) finish() }
                },
            )
            started.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                    "package:mato/services/home_widget_service.dart",
                    "homeWidgetRefreshMain",
                )
            )
            handler.postDelayed(timeout, TIMEOUT_MS)
        } catch (error: Exception) {
            Log.e(TAG, "無法啟動小工具的背景更新", error)
            finish()
        }
    }

    private fun finish() {
        handler.removeCallbacks(timeout)
        engine?.destroy()
        engine = null
        context?.let {
            WidgetStore(it).refreshingSince = 0
            Widgets.updateAll(it)
        }
        val callbacks = waiting.toList()
        waiting.clear()
        callbacks.forEach { it() }
    }

    /** 要更新哪些伺服器：單台伺服器小工具選的那幾台，加上伺服器總覽看得到的列數。 */
    private fun request(context: Context, manual: Boolean): Map<String, Any> {
        val store = WidgetStore(context)
        val serverIds =
            Widgets.ids(context, ServerWidgetProvider::class.java)
                .toList()
                .mapNotNull(store::serverOf)
                .distinct()
        val overviewRows =
            Widgets.ids(context, OverviewWidgetProvider::class.java).maxOfOrNull { id ->
                store.rowsOf(id).takeIf { it > 0 } ?: OverviewWidget.DEFAULT_ROWS
            } ?: 0
        return mapOf("serverIds" to serverIds, "overviewRows" to overviewRows, "manual" to manual)
    }

    /** 依 App 設定的間隔排定（或取消）定時背景更新；主畫面上沒有小工具時不排。 */
    fun schedule(context: Context) {
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        val minutes = WidgetStore(context).snapshot().refreshMinutes
        if (minutes <= 0 || !Widgets.any(context)) {
            scheduler.cancel(JOB_ID)
            return
        }
        val interval = TimeUnit.MINUTES.toMillis(minutes.toLong())
        // 重排會讓週期重新起算，間隔沒變就不動。
        if (scheduler.getPendingJob(JOB_ID)?.intervalMillis == interval) return
        val job =
            JobInfo.Builder(JOB_ID, ComponentName(context, WidgetRefreshJob::class.java))
                .setPeriodic(interval)
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .build()
        scheduler.schedule(job)
    }
}

/** 定時背景更新（見 [WidgetRefresher.schedule]）。 */
class WidgetRefreshJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        WidgetRefresher.refresh(this, manual = false) { jobFinished(params, false) }
        return true
    }

    // 系統要求提早結束（例如網路斷了）時由 WidgetRefresher 的逾時收尾，下一輪照常。
    override fun onStopJob(params: JobParameters) = false
}
