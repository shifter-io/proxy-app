package io.shifter.shifter_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor

/**
 * Android's only way to give other apps a proxy: a VPN network whose link
 * carries an HTTP proxy (the local Shifter proxy in this app). It has no
 * routes, so no packets ever enter it; apps that follow the proxy talk to
 * the local proxy, everything else goes direct (like the desktop system
 * proxy). Shifter itself is excluded so its own gateway traffic never loops.
 */
class ShifterVpnService : VpnService() {
    companion object {
        private const val ACTION_START = "io.shifter.shifter_app.START"
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL = "connection"

        /** The service while a VPN slot is held (main thread only). */
        var running: ShifterVpnService? = null
            private set

        fun start(context: Context, target: ProxyTarget) {
            context.startService(
                Intent(context, ShifterVpnService::class.java)
                    .setAction(ACTION_START)
                    .putExtra("host", target.host)
                    .putExtra("port", target.port)
                    .putStringArrayListExtra("bypass", ArrayList(target.bypass)),
            )
        }
    }

    private var tun: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_START) {
            running = this
            apply(
                ProxyTarget(
                    intent.getStringExtra("host")!!,
                    intent.getIntExtra("port", 0),
                    intent.getStringArrayListExtra("bypass") ?: emptyList(),
                ),
            )
        } else if (tun == null) {
            // Started by the system (always-on VPN) before the app chose a
            // location: there is nothing to route to yet.
            stopSelf()
        }
        return START_NOT_STICKY
    }

    fun apply(target: ProxyTarget) {
        val error = try {
            val pfd = Builder()
                .setSession("Shifter")
                .addAddress("10.215.173.1", 32)
                .setHttpProxy(ProxyInfo.buildDirectProxy(target.host, target.port, target.bypass))
                .addDisallowedApplication(packageName)
                .setMetered(false)
                .setConfigureIntent(openApp())
                .establish() ?: throw IllegalStateException("Shifter isn't allowed to connect. Tap Connect and choose OK.")
            tun?.close()
            tun = pfd
            goForeground()
            null
        } catch (e: Exception) {
            e.message ?: "Could not start the connection."
        }
        VpnBridge.started(error)
        if (error != null && tun == null) shutdown(null)
    }

    /** Close the VPN slot; [reason] tells Dart when the app didn't ask for it. */
    fun shutdown(reason: String?) {
        if (running === this) running = null
        tun?.close()
        tun = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        if (reason != null) VpnBridge.stopped(reason)
    }

    /** The user turned the VPN off in Settings, or another VPN app took over. */
    override fun onRevoke() = shutdown("revoked")

    override fun onDestroy() {
        if (running === this) running = null
        tun?.close()
        tun = null
        super.onDestroy()
    }

    private fun openApp(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE,
    )

    /** Keeps the process (and the Dart local proxy in it) alive in the background. */
    private fun goForeground() {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(NOTIFICATION_CHANNEL, "Connection", NotificationManager.IMPORTANCE_LOW),
        )
        val notification = Notification.Builder(this, NOTIFICATION_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_shifter)
            .setContentTitle("Connected through Shifter")
            .setContentText("Apps that use the system proxy go through your Shifter location.")
            .setContentIntent(openApp())
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            // The system keeps a VPN service bound at high priority anyway.
        }
    }
}
