package me.creeperdev.mato.widget

import android.content.Context
import org.json.JSONException
import org.json.JSONObject

/** 小工具上的一台伺服器，對應 lib/services/home_widget_service.dart 的 WidgetServer。 */
data class WidgetServer(
    val id: String,
    val name: String,
    /** Dart 端 ServerStatus 的名稱：online、checking、offline、authFailed、error、unknown。 */
    val status: String,
    /** 不是線上時的原因，可能是空字串。 */
    val message: String,
    /** 最後一次檢查的時間（epoch 毫秒），不論成功與否。 */
    val checkedAt: Long?,
    /** 只有線上時才有。 */
    val metrics: WidgetMetrics?,
) {
    val online: Boolean
        get() = status == "online" && metrics != null
}

/** 已經格式化好的指標；使用率為 0–100。 */
data class WidgetMetrics(
    val cpu: Double,
    val memory: Double,
    val disk: Double,
    val rx: String,
    val tx: String,
    val load: String,
    val uptime: String,
    val os: String,
)

/** App 寫給小工具的完整資料，依伺服器清單的順序排列。 */
class WidgetSnapshot(val servers: List<WidgetServer>, val refreshMinutes: Int) {
    fun byId(id: String?): WidgetServer? = servers.firstOrNull { it.id == id }

    companion object {
        /** 和 SettingsStore.widgetRefreshMinutes 的預設值相同。 */
        private const val DEFAULT_REFRESH_MINUTES = 30

        fun parse(raw: String?): WidgetSnapshot {
            if (raw.isNullOrEmpty()) return WidgetSnapshot(emptyList(), DEFAULT_REFRESH_MINUTES)
            return try {
                val json = JSONObject(raw)
                val list = json.optJSONArray("servers")
                val servers = buildList {
                    for (index in 0 until (list?.length() ?: 0)) {
                        list?.optJSONObject(index)?.let(::parseServer)?.let(::add)
                    }
                }
                WidgetSnapshot(servers, json.optInt("refreshMinutes", DEFAULT_REFRESH_MINUTES))
            } catch (error: JSONException) {
                WidgetSnapshot(emptyList(), DEFAULT_REFRESH_MINUTES)
            }
        }

        private fun parseServer(json: JSONObject): WidgetServer? {
            val id = json.optString("id")
            if (id.isEmpty()) return null
            val metrics = json.optJSONObject("metrics")?.let {
                WidgetMetrics(
                    cpu = it.optDouble("cpu", 0.0),
                    memory = it.optDouble("memory", 0.0),
                    disk = it.optDouble("disk", 0.0),
                    rx = it.optString("rx"),
                    tx = it.optString("tx"),
                    load = it.optString("load"),
                    uptime = it.optString("uptime"),
                    os = it.optString("os"),
                )
            }
            return WidgetServer(
                id = id,
                name = json.optString("name"),
                status = json.optString("status", "unknown"),
                message = json.optString("message"),
                checkedAt = if (json.has("checkedAt")) json.optLong("checkedAt") else null,
                metrics = metrics,
            )
        }
    }
}

/** 小工具的資料與每個小工具的設定，存在 App 私有的 SharedPreferences。 */
class WidgetStore(context: Context) {
    private val prefs =
        context.applicationContext.getSharedPreferences("mato_widgets", Context.MODE_PRIVATE)

    /** Dart 端寫入的 JSON（見 [WidgetSnapshot]）。 */
    var snapshotJson: String?
        get() = prefs.getString(KEY_SNAPSHOT, null)
        set(value) = prefs.edit().putString(KEY_SNAPSHOT, value).apply()

    fun snapshot() = WidgetSnapshot.parse(snapshotJson)

    /** 單台伺服器小工具要顯示的伺服器。 */
    fun serverOf(widgetId: Int): String? = prefs.getString("server.$widgetId", null)

    fun setServer(widgetId: Int, serverId: String) =
        prefs.edit().putString("server.$widgetId", serverId).apply()

    /** 伺服器總覽目前放得下幾列；背景更新只抓看得到的那幾台。 */
    fun rowsOf(widgetId: Int): Int = prefs.getInt("rows.$widgetId", 0)

    fun setRows(widgetId: Int, rows: Int) {
        if (rowsOf(widgetId) != rows) prefs.edit().putInt("rows.$widgetId", rows).apply()
    }

    fun forget(widgetIds: IntArray) {
        val editor = prefs.edit()
        for (id in widgetIds) {
            editor.remove("server.$id")
            editor.remove("rows.$id")
        }
        editor.apply()
    }

    /** 背景更新開始的時間，0 代表沒有在更新。 */
    var refreshingSince: Long
        get() = prefs.getLong(KEY_REFRESHING, 0)
        set(value) = prefs.edit().putLong(KEY_REFRESHING, value).apply()

    /** 正在背景更新。行程中途被系統結束時，過一陣子就不再顯示更新中。 */
    val refreshing: Boolean
        get() = System.currentTimeMillis() - refreshingSince in 0 until STALE_REFRESH_MS

    /** 從 App 加入單台伺服器小工具時選的伺服器，等桌面放好小工具後套用。 */
    var pendingPinServer: String?
        get() = prefs.getString(KEY_PENDING_PIN, null)
        set(value) = prefs.edit().putString(KEY_PENDING_PIN, value).apply()

    private companion object {
        const val KEY_SNAPSHOT = "snapshot"
        const val KEY_REFRESHING = "refreshingSince"
        const val KEY_PENDING_PIN = "pendingPinServer"
        const val STALE_REFRESH_MS = 60_000L
    }
}
