package io.shifter.shifter_app

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

class MainActivity : FlutterActivity() {
    /**
     * One engine for the whole process, kept after the window closes: the
     * local proxy runs in Dart, so it has to outlive the activity while
     * connected (swiping Shifter out of recents must not cut traffic off).
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        return FlutterEngine(context.applicationContext).also { engine ->
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            VpnBridge.attach(context, engine)
            cache.put(ENGINE_ID, engine)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        VpnBridge.activity = this
    }

    override fun onDestroy() {
        if (VpnBridge.activity === this) VpnBridge.activity = null
        super.onDestroy()
    }

    @Deprecated("Activity result API; FlutterActivity is not a ComponentActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VpnBridge.REQUEST_CONSENT) {
            VpnBridge.onConsent(resultCode == RESULT_OK)
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private companion object {
        const val ENGINE_ID = "shifter"
    }
}
