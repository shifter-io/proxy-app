package io.shifter.shifter_app

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

object DistributionUpdates {
    private lateinit var app: Context
    private val prefs get() = app.getSharedPreferences("shifter_update_direct", Context.MODE_PRIVATE)
    fun initialize(context: Context) { app = context }
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean = false
    @Suppress("DEPRECATION")
    private fun validate(args: Map<*, *>): File {
        require(Build.VERSION.SDK_INT >= 29)
        val release = args["release"] as Map<*, *>
        val artifact = release["artifact"] as Map<*, *>
        val supplied = File(args["path"] as String)
        val file = supplied.canonicalFile
        // Dart path_provider's application-support directory is filesDir.
        val root = File(app.filesDir, "updates-v1").canonicalFile
        require(supplied.absolutePath == file.absolutePath && file.parentFile == root && file.isFile)
        require(file.length() == (artifact["byteLength"] as Number).toLong())
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val b = ByteArray(65536); while (true) { val n = input.read(b); if (n < 0) break; digest.update(b, 0, n) } }
        fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
        require(hex(digest.digest()) == artifact["sha256"])
        val pm = app.packageManager
        val archive = pm.getPackageArchiveInfo(file.path, PackageManager.GET_SIGNING_CERTIFICATES) ?: error("Invalid APK")
        val installed = pm.getPackageInfo(app.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        require(archive.packageName == app.packageName && archive.packageName == release["applicationId"])
        require(archive.longVersionCode == (release["build"] as Number).toLong() && archive.longVersionCode > installed.longVersionCode)
        require(archive.applicationInfo!!.minSdkVersion <= Build.VERSION.SDK_INT)
        val candidate = archive.signingInfo!!.apkContentsSigners.map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }.toSet()
        val current = installed.signingInfo!!.apkContentsSigners.map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }.toSet()
        // Conservative v1: signing rotation needs an explicitly qualified release path.
        require(candidate == current && candidate.size == 1 && candidate.single() == artifact["expectedSigner"])
        ZipFile(file).use { zip ->
            val abis = zip.entries().asSequence().map { it.name }.filter { it.startsWith("lib/") && it.endsWith(".so") }.map { it.split('/')[1] }.toSet()
            require(abis.isEmpty() || Build.SUPPORTED_ABIS.any { it in abis })
        }
        return file
    }
    fun handle(method: String, args: Map<*, *>, result: MethodChannel.Result) {
        when (method) {
            "eligible" -> result.success(Build.VERSION.SDK_INT >= ((args["release"] as Map<*, *>)["minimumOs"] as String).toInt())
            "prepare" -> UpdateBridge.background(result) { validate(args); null }
            "install" -> {
                require(Build.VERSION.SDK_INT >= 29)
                val activity = UpdateBridge.activity ?: return result.error("activity", "Open Shifter to install the update.", null)
                if (!app.packageManager.canRequestPackageInstalls()) {
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${app.packageName}")))
                    return result.error("permission", "Allow updates from Shifter, then return and tap Install update again.", null)
                }
                UpdateBridge.background(result) {
                    val file = validate(args)
                    val installer = app.packageManager.packageInstaller
                    val oldSession = prefs.getInt("sessionId", -1)
                    if (oldSession != -1 && installer.getSessionInfo(oldSession) != null) error("An installation is already pending")
                    val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                        setAppPackageName(app.packageName); setSize(file.length())
                        if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
                    }
                    val id = installer.createSession(params)
                    require(prefs.edit().putInt("sessionId", id).putString("operationId", args["operationId"] as String).putString("state", "awaitingSystemConsent").commit())
                    try {
                        installer.openSession(id).use { session ->
                            session.openWrite("base.apk", 0, file.length()).use { out -> file.inputStream().use { it.copyTo(out) }; session.fsync(out) }
                            val intent = Intent(app, UpdateInstallReceiver::class.java).setAction("${app.packageName}.UPDATE_RESULT").putExtra("sessionId", id)
                            val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                            session.commit(PendingIntent.getBroadcast(app, id, intent, flags).intentSender)
                        }
                    } catch (e: Exception) { installer.abandonSession(id); prefs.edit().putString("state", "failed").commit(); throw e }
                    null
                }
            }
            "reconcile" -> {
                val id = prefs.getInt("sessionId", -1)
                var state = prefs.getString("state", "idle")
                if (id != -1 && state == "awaitingSystemConsent" && app.packageManager.packageInstaller.getSessionInfo(id) == null) {
                    state = "failed"; prefs.edit().putString("state", state).commit()
                }
                result.success(mapOf("state" to state, "operationId" to prefs.getString("operationId", null), "sessionId" to id))
            }
            else -> result.notImplemented()
        }
    }
}

class UpdateInstallReceiver : BroadcastReceiver() {
    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = context.getSharedPreferences("shifter_update_direct", Context.MODE_PRIVATE)
        if (intent.getIntExtra("sessionId", -2) != prefs.getInt("sessionId", -1)) return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirmation != null) {
                    try { confirmation.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK); context.startActivity(confirmation) }
                    catch (_: Exception) { prefs.edit().putString("state", "failed").commit() }
                }
            }
            PackageInstaller.STATUS_SUCCESS -> prefs.edit().putString("state", "installed").remove("sessionId").commit()
            PackageInstaller.STATUS_FAILURE_ABORTED -> prefs.edit().putString("state", "canceled").remove("sessionId").commit()
            else -> prefs.edit().putString("state", "failed").remove("sessionId").commit()
        }
    }
}
