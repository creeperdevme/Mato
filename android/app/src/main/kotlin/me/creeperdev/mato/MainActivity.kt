package me.creeperdev.mato

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import me.creeperdev.mato.widget.WidgetChannel

// local_auth（App 鎖）需要 FragmentActivity 才能顯示生物辨識對話框。
class MainActivity : FlutterFragmentActivity() {
    private var widgets: WidgetChannel? = null
    private var restored = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // 旋轉或被系統回收後重建時，啟動用的 Intent 已經處理過了。
        restored = savedInstanceState != null
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 主畫面小工具：同步監控資料，以及從小工具點進來時要打開的伺服器。
        widgets =
            WidgetChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger).also {
                if (!restored) it.onIntent(intent)
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        widgets?.onIntent(intent)
    }
}
