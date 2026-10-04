package io.shifter.shifter_app

import android.content.Context
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** The connection settings Dart hands over: where the local proxy listens. */
data class ProxyTarget(val host: String, val port: Int, val bypass: List<String>)

/**
 * `shifter/vpn` channel (lib/proxy/android_system_proxy.dart): asks for the
 * user's VPN permission once, then starts or stops [ShifterVpnService].
 */
object VpnBridge {
    const val REQUEST_CONSENT = 0x5f1
    private const val CHANNEL = "shifter/vpn"

    var activity: MainActivity? = null
    private lateinit var app: Context
    private var channel: MethodChannel? = null
    private var awaitingConsent: Pair<ProxyTarget, MethodChannel.Result>? = null
    private var starting: MethodChannel.Result? = null

    fun attach(context: Context, engine: FlutterEngine) {
        app = context.applicationContext
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> start(
                        ProxyTarget(call.argument("host")!!, call.argument("port")!!, call.argument("bypass")!!),
                        result,
                    )
                    "stop" -> {
                        ShifterVpnService.running?.shutdown(null)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun start(target: ProxyTarget, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return result.error("unsupported", "Connecting needs Android 10 or newer.", null)
        }
        val consent = VpnService.prepare(app) ?: return launch(target, result)
        val activity = activity ?: return result.error("consent", "Open Shifter to allow the connection.", null)
        awaitingConsent?.second?.error("consent", "Cancelled.", null)
        awaitingConsent = target to result
        activity.startActivityForResult(consent, REQUEST_CONSENT)
    }

    fun onConsent(granted: Boolean) {
        val (target, result) = awaitingConsent ?: return
        awaitingConsent = null
        if (granted) {
            launch(target, result)
        } else {
            result.error("consent", "Shifter needs your permission to route other apps. Tap Connect and choose OK.", null)
        }
    }

    private fun launch(target: ProxyTarget, result: MethodChannel.Result) {
        // Already running (settings changed while connected): update in place.
        ShifterVpnService.running?.let { service ->
            starting = result
            service.apply(target)
            return
        }
        starting = result
        try {
            ShifterVpnService.start(app, target)
        } catch (e: Exception) {
            started(e.message ?: "Could not start the connection.")
        }
    }

    /** The service finished applying a [ProxyTarget]; null = success. */
    fun started(error: String?) {
        val result = starting ?: return
        starting = null
        if (error == null) result.success(null) else result.error("start", error, null)
    }

    /** The VPN slot closed without the app asking. */
    fun stopped(reason: String) {
        channel?.invokeMethod("stopped", reason)
    }
}
