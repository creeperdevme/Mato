package me.creeperdev.mato.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import me.creeperdev.mato.MainActivity
import me.creeperdev.mato.R

/**
 * 單台伺服器小工具的設定畫面：放到桌面時、Android 12 起長按「重新設定」時，
 * 以及點了還沒選伺服器的小工具時，選擇要顯示哪台。本身透明，只有一個對話框。
 */
class ServerPickerActivity : AppCompatActivity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        widgetId =
            intent?.getIntExtra(
                AppWidgetManager.EXTRA_APPWIDGET_ID,
                AppWidgetManager.INVALID_APPWIDGET_ID,
            ) ?: AppWidgetManager.INVALID_APPWIDGET_ID
        // 沒選就離開時，桌面會把剛放上去的小工具拿掉。
        setResult(RESULT_CANCELED, result())
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        val store = WidgetStore(this)
        val servers = store.snapshot().servers
        val dialog =
            if (servers.isEmpty()) {
                AlertDialog.Builder(this)
                    .setTitle(R.string.widget_picker_empty_title)
                    .setMessage(R.string.widget_picker_empty_message)
                    .setPositiveButton(R.string.widget_open_app) { _, _ ->
                        // 小工具先留著，新增伺服器後點它就能選。
                        setResult(RESULT_OK, result())
                        Widgets.updateAll(this)
                        startActivity(
                            Intent(this, MainActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    }
            } else {
                val current = store.serverOf(widgetId) ?: store.pendingPinServer
                AlertDialog.Builder(this)
                    .setTitle(R.string.widget_picker_title)
                    .setSingleChoiceItems(
                        servers.map { it.name }.toTypedArray(),
                        servers.indexOfFirst { it.id == current },
                    ) { dialog, which ->
                        choose(store, servers[which].id)
                        dialog.dismiss()
                    }
            }
        dialog
            .setNegativeButton(R.string.widget_cancel, null)
            .setOnDismissListener { if (!isChangingConfigurations) finish() }
            .show()
    }

    private fun choose(store: WidgetStore, serverId: String) {
        store.setServer(widgetId, serverId)
        store.pendingPinServer = null
        setResult(RESULT_OK, result())
        Widgets.updateAll(this)
        // 馬上抓一次這台的指標，不必等下一輪定時更新。
        sendBroadcast(
            Intent(this, ServerWidgetProvider::class.java)
                .setAction(MatoWidgetProvider.ACTION_REFRESH)
        )
    }

    private fun result() = Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
}
