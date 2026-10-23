package io.shifter.shifter_app

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Engine-owned bridge, with a separately attached Activity across recreation. */
object UpdateBridge {
    var activity: MainActivity? = null
    lateinit var app: Context
        private set
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    fun attach(context: Context, engine: FlutterEngine) {
        app = context.applicationContext
        DistributionUpdates.initialize(app)
        MethodChannel(engine.dartExecutor.binaryMessenger, "shifter/updates").setMethodCallHandler { call, result ->
            val args = (call.arguments as? Map<*, *>) ?: emptyMap<Any, Any>()
            if (call.method == "identity") {
                result.success(mapOf("distribution" to BuildConfig.FLAVOR, "architecture" to "universal", "osVersion" to Build.VERSION.SDK_INT.toString()))
            } else {
                try { DistributionUpdates.handle(call.method, args, result) }
                catch (_: Exception) { result.error("update", "The update could not be completed. Please retry.", null) }
            }
        }
    }
    fun background(result: MethodChannel.Result, task: () -> Any?) {
        worker.execute {
            try { val value = task(); main.post { result.success(value) } }
            catch (_: Exception) { main.post { result.error("validation", "Update validation failed. Check package identity, permissions and free space.", null) } }
        }
    }
    fun foreground(task: () -> Unit) { main.post(task) }
}
