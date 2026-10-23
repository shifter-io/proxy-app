package io.shifter.shifter_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.google.android.play.core.appupdate.AppUpdateManager
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.InstallStatus
import com.google.android.play.core.install.model.UpdateAvailability
import io.flutter.plugin.common.MethodChannel

/** This source set never includes the APK installer or its permission. */
object DistributionUpdates {
    private const val REQUEST_UPDATE = 0x5f3
    private lateinit var manager: AppUpdateManager
    private lateinit var app: Context
    private val prefs get() = app.getSharedPreferences("shifter_update_play", Context.MODE_PRIVATE)
    fun initialize(context: Context) { app = context; manager = AppUpdateManagerFactory.create(app) }
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_UPDATE) return false
        val state = when (resultCode) {
            Activity.RESULT_OK -> null
            Activity.RESULT_CANCELED -> "canceled"
            else -> "failed"
        }
        prefs.edit().putString("consentResult", state).commit()
        return true
    }
    fun handle(method: String, args: Map<*, *>, result: MethodChannel.Result) {
        when (method) {
            "reconcile" -> manager.appUpdateInfo.addOnSuccessListener { info ->
                val state = when (info.installStatus()) {
                    InstallStatus.DOWNLOADED -> "ready"
                    InstallStatus.DOWNLOADING, InstallStatus.PENDING -> "downloading"
                    InstallStatus.FAILED -> "failed"
                    InstallStatus.CANCELED -> "canceled"
                    else -> prefs.getString("consentResult", null) ?: "idle"
                }
                result.success(mapOf("available" to (info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE && info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE)),
                    "build" to info.availableVersionCode(), "state" to state, "operationId" to prefs.getString("operationId", null),
                    "progress" to if (info.totalBytesToDownload() > 0) info.bytesDownloaded().toDouble() / info.totalBytesToDownload() else null))
            }.addOnFailureListener { result.error("play", "Google Play availability could not be checked.", null) }
            "download" -> {
                val activity = UpdateBridge.activity ?: return result.error("activity", "Open Shifter to update.", null)
                check(prefs.edit().putString("operationId", args["operationId"] as String).remove("consentResult").commit())
                // AppUpdateInfo is single-use: acquire fresh eligibility for every retry.
                manager.appUpdateInfo.addOnSuccessListener { info ->
                    if (info.updateAvailability() != UpdateAvailability.UPDATE_AVAILABLE || !info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE) || info.availableVersionCode() != (args["build"] as Number).toInt()) {
                        result.error("eligibility", "This update is not available to this Google Play account.", null)
                    } else {
                        try {
                            val started = manager.startUpdateFlowForResult(info, activity, AppUpdateOptions.newBuilder(AppUpdateType.FLEXIBLE).build(), REQUEST_UPDATE)
                            if (started) result.success(null) else result.error("play", "Google Play could not start the update.", null)
                        } catch (_: Exception) { result.error("play", "Google Play could not start the update.", null) }
                    }
                }.addOnFailureListener { result.error("play", "Google Play could not start the update.", null) }
            }
            "prepare" -> manager.appUpdateInfo.addOnSuccessListener { info ->
                if (info.installStatus() == InstallStatus.DOWNLOADED) result.success(null)
                else result.error("pending", "Wait for Google Play to finish downloading.", null)
            }.addOnFailureListener { result.error("play", "Google Play status is unavailable.", null) }
            "install" -> manager.completeUpdate().addOnSuccessListener { result.success(null) }
                .addOnFailureListener { result.error("play", "Google Play could not finish the update.", null) }
            "openStore" -> {
                val activity = UpdateBridge.activity ?: return result.error("activity", "Open Shifter first.", null)
                activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=${app.packageName}")))
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
