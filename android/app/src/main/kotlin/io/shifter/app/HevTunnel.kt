package io.shifter.app

/**
 * JNI binding to hev-socks5-tunnel (jniLibs/, MIT; built by
 * tool/android/build_hev_jni.sh): reads IP packets from the VPN interface
 * and sends them to a SOCKS5 server, TCP as CONNECT and UDP as UDP
 * ASSOCIATE. The library registers these methods on this class when loaded.
 */
object HevTunnel {
    init {
        System.loadLibrary("hev-socks5-tunnel")
    }

    /** Starts the engine on its own thread with the YAML config at [configPath]. */
    @JvmStatic external fun TProxyStartService(configPath: String, fd: Int): Boolean

    /** Stops the engine and waits for its thread. */
    @JvmStatic external fun TProxyStopService(): Boolean

    @JvmStatic external fun TProxyIsRunning(): Boolean

    /** tx packets, tx bytes, rx packets, rx bytes. */
    @JvmStatic external fun TProxyGetStats(): LongArray
}
