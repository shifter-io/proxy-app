package io.shifter.shifter_app

import android.content.Context
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import java.io.File
import java.net.InetAddress

/**
 * Full-device mode: the VPN routes every IPv4 and IPv6 packet, [HevTunnel]
 * turns them back into TCP connections, and [GatewayBridge] carries each one
 * to the gateway over TLS as an HTTP CONNECT with the plan login. DNS is
 * answered in the engine and resolved by name at the exit. UDP is refused
 * for now (apps fall back to TCP). Shifter itself is excluded from the VPN,
 * so the bridge reaches the gateway directly.
 */
object FullTunnel {
    private const val MTU = 8500
    private const val IPV4 = "198.18.0.1"
    private const val IPV6 = "fc00::1"
    private const val MAPPED_DNS = "198.18.0.2"

    /**
     * Local networks stay direct (printers, casting, the router). Loopback
     * never leaves the device, and Android rejects it in routes.
     */
    private val localNetworks = listOf(
        "10.0.0.0" to 8, "172.16.0.0" to 12, "192.168.0.0" to 16, "169.254.0.0" to 16,
        "224.0.0.0" to 4, "240.0.0.0" to 4,
    )

    /** Before Android 13 (no excludeRoute): all IPv4 minus [localNetworks]. */
    private val publicIPv4 = listOf(
        "1.0.0.0/8", "2.0.0.0/7", "4.0.0.0/6", "8.0.0.0/7", "11.0.0.0/8", "12.0.0.0/6", "16.0.0.0/4",
        "32.0.0.0/3", "64.0.0.0/3", "96.0.0.0/4", "112.0.0.0/5", "120.0.0.0/6", "124.0.0.0/7",
        "126.0.0.0/8", "128.0.0.0/3", "160.0.0.0/5", "168.0.0.0/8", "169.0.0.0/9", "169.128.0.0/10",
        "169.192.0.0/11", "169.224.0.0/12", "169.240.0.0/13", "169.248.0.0/14", "169.252.0.0/15",
        "169.255.0.0/16", "170.0.0.0/7", "172.0.0.0/12", "172.32.0.0/11", "172.64.0.0/10",
        "172.128.0.0/9", "173.0.0.0/8", "174.0.0.0/7", "176.0.0.0/4", "192.0.0.0/9", "192.128.0.0/11",
        "192.160.0.0/13", "192.169.0.0/16", "192.170.0.0/15", "192.172.0.0/14", "192.176.0.0/12",
        "192.192.0.0/10", "193.0.0.0/8", "194.0.0.0/7", "196.0.0.0/6", "200.0.0.0/5", "208.0.0.0/4",
    )

    class Rejected : Exception("Shifter refused the plan login. Check the plan in your Shifter account.")

    /** Routes, DNS and addresses for [VpnService.Builder]. */
    fun configure(builder: VpnService.Builder): VpnService.Builder {
        builder.setMtu(MTU)
            .addAddress(IPV4, 32)
            // DNS is answered inside the engine (mapped DNS): apps get a
            // placeholder address and the gateway resolves the real name at
            // the exit, so DNS never reaches the ISP and needs no UDP.
            .addDnsServer(MAPPED_DNS)
            // IPv6 is routed into the tunnel so nothing leaves around the
            // proxy, but the tunnel has no IPv6 address: the gateway reaches
            // IPv4 only, so apps see no IPv6 and use IPv4 at once instead of
            // trying IPv6 connections that would be reset.
            .addRoute("::", 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            builder.addRoute("0.0.0.0", 0)
            for ((address, prefix) in localNetworks) builder.excludeRoute(IpPrefix(InetAddress.getByName(address), prefix))
        } else {
            for (route in publicIPv4) {
                val (address, prefix) = route.split('/')
                builder.addRoute(address, prefix.toInt())
            }
        }
        return builder
    }

    /**
     * Checks that the gateway answers and accepts the plan login, and returns
     * the bridge to run with. Network I/O: call off the main thread. Throws
     * [Rejected] when the gateway refuses the login.
     */
    fun prepare(login: SocksLogin): GatewayBridge {
        val bridge = GatewayBridge(login)
        if (!bridge.check()) {
            bridge.stop()
            throw if (bridge.rejected) Rejected() else IllegalStateException("Couldn't reach Shifter. Check your connection and try again.")
        }
        return bridge
    }

    /** Starts [bridge] and the engine on the VPN interface [fd]. */
    fun start(context: Context, bridge: GatewayBridge, fd: Int) {
        stop()
        bridge.start()
        this.bridge = bridge
        // A fresh placeholder range on every start: addresses apps cached
        // from the previous run fail instead of reaching another host.
        mappedRange = (mappedRange + 1) % MAPPED_RANGES.size
        // The engine reads its config from a file; it stays in app-private
        // storage and is removed on stop.
        val config = configFile(context)
        config.writeText(yaml(bridge.port, bridge.secret, MAPPED_RANGES[mappedRange]))
        config.setReadable(false, false)
        config.setReadable(true, true)
        lastContext = context.applicationContext
        if (!HevTunnel.TProxyStartService(config.absolutePath, fd)) {
            stop()
            throw IllegalStateException("Shifter couldn't open the connection. Try again.")
        }
    }

    /** Stops the engine and the bridge; every connection closes (apps reconnect on the next exit). */
    fun stop() {
        if (HevTunnel.TProxyIsRunning()) HevTunnel.TProxyStopService()
        bridge?.stop()
        bridge = null
        lastContext?.let { configFile(it).delete() }
    }

    /** The bridge's local port while connected (the app's exit check uses it). */
    val bridgePort: Int? get() = bridge?.port

    /** The bridge's per-session secret (the app's exit check presents it). */
    val bridgeSecret: String? get() = bridge?.secret

    /** True once the gateway refused the plan login while connected. */
    val rejected: Boolean get() = bridge?.rejected == true

    private var bridge: GatewayBridge? = null
    private var lastContext: Context? = null
    private var mappedRange = 0

    /** Placeholder ranges for mapped DNS, inside 100.64.0.0/10 (routed into the tunnel). */
    private val MAPPED_RANGES = listOf("100.64.0.0", "100.80.0.0", "100.96.0.0", "100.112.0.0")

    private fun configFile(context: Context) = File(context.noBackupFilesDir, "tunnel.yml")

    private fun yaml(bridgePort: Int, secret: String, mappedNetwork: String) = """
        tunnel:
          mtu: $MTU
          ipv4: $IPV4
          ipv6: '$IPV6'
        socks5:
          address: 127.0.0.1
          port: $bridgePort
          udp: 'udp'
          username: 'shifter'
          password: '$secret'
        mapdns:
          address: $MAPPED_DNS
          port: 53
          network: $mappedNetwork
          netmask: 255.240.0.0
          cache-size: 10000
        misc:
          task-stack-size: 81920
          connect-timeout: 10000
          log-level: warn
    """.trimIndent()
}
