package io.shifter.shifter_app

import android.content.Context
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import java.io.DataInputStream
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Full-device mode: the VPN routes every IPv4 and IPv6 packet, and
 * [HevTunnel] turns them back into SOCKS5 connections to the gateway, TCP as
 * CONNECT and UDP (QUIC, DNS, calls, games) as UDP ASSOCIATE. Shifter itself
 * is excluded from the VPN, so the engine reaches the gateway directly.
 */
object FullTunnel {
    private const val MTU = 8500
    private const val IPV4 = "198.18.0.1"
    private const val IPV6 = "fc00::1"

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
            .addAddress(IPV6, 128)
            // DNS goes through the tunnel as UDP over SOCKS5, never to the ISP.
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")
            // IPv6 also enters the tunnel, so nothing leaves around the proxy.
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
     * Checks the login and opens UDP first, so TCP and UDP start on the same
     * exit. Network I/O: call off the main thread. Throws [Rejected] when the
     * gateway refuses the login.
     */
    fun prepare(login: SocksLogin) {
        Socket().use { control ->
            control.soTimeout = 10_000
            control.connect(InetSocketAddress(login.host, login.port), 10_000)
            val out = control.getOutputStream()
            val inp = DataInputStream(control.getInputStream())
            out.write(byteArrayOf(5, 1, 2))
            val method = ByteArray(2).also { inp.readFully(it) }
            if (method[1].toInt() != 2) throw IllegalStateException("The Shifter gateway didn't accept the login method.")
            val user = login.username.toByteArray()
            val pass = login.password.toByteArray()
            out.write(byteArrayOf(1, user.size.toByte()) + user + byteArrayOf(pass.size.toByte()) + pass)
            val auth = ByteArray(2).also { inp.readFully(it) }
            if (auth[1].toInt() != 0) throw Rejected()

            // UDP ASSOCIATE from 0.0.0.0:0; the reply names the relay.
            out.write(byteArrayOf(5, 3, 0, 1, 0, 0, 0, 0, 0, 0))
            val head = ByteArray(4).also { inp.readFully(it) }
            if (head[1].toInt() != 0) return // No UDP on this exit: TCP still works.
            val relayHost = when (head[3].toInt()) {
                1 -> InetAddress.getByAddress(ByteArray(4).also { inp.readFully(it) }).hostAddress!!
                3 -> String(ByteArray(inp.readUnsignedByte()).also { inp.readFully(it) })
                else -> return
            }
            val relayPort = inp.readUnsignedShort()
            val relay = InetSocketAddress(if (relayHost == "0.0.0.0") login.host else relayHost, relayPort)
            DatagramSocket().use { udp ->
                udp.soTimeout = 3_000
                // A DNS query for example.com to 1.1.1.1:53, in the SOCKS5 UDP header.
                val query = byteArrayOf(0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7) + "example".toByteArray() +
                    byteArrayOf(3) + "com".toByteArray() + byteArrayOf(0, 0, 1, 0, 1)
                val packet = byteArrayOf(0, 0, 0, 1, 1, 1, 1, 1, 0, 53) + query
                udp.send(DatagramPacket(packet, packet.size, relay))
                runCatching { udp.receive(DatagramPacket(ByteArray(1500), 1500)) }
            }
        }
    }

    /** Starts the engine on the VPN interface [fd]. */
    fun start(context: Context, login: SocksLogin, fd: Int) {
        stop()
        // The engine reads its config from a file; it stays in app-private
        // storage and is removed on stop.
        val config = configFile(context)
        config.writeText(yaml(login))
        config.setReadable(false, false)
        config.setReadable(true, true)
        if (!HevTunnel.TProxyStartService(config.absolutePath, fd)) {
            throw IllegalStateException("Shifter couldn't open the connection. Try again.")
        }
        lastContext = context.applicationContext
    }

    /** Stops the engine; every connection closes (apps reconnect on the next exit). */
    fun stop() {
        if (HevTunnel.TProxyIsRunning()) HevTunnel.TProxyStopService()
        lastContext?.let { configFile(it).delete() }
    }

    private var lastContext: Context? = null

    private fun configFile(context: Context) = File(context.noBackupFilesDir, "tunnel.yml")

    private fun quoted(s: String) = "'" + s.replace("'", "''") + "'"

    private fun yaml(login: SocksLogin) = """
        tunnel:
          mtu: $MTU
          ipv4: $IPV4
          ipv6: '$IPV6'
        socks5:
          address: ${quoted(login.host)}
          port: ${login.port}
          udp: 'udp'
          username: ${quoted(login.username)}
          password: ${quoted(login.password)}
        misc:
          task-stack-size: 81920
          connect-timeout: 10000
          log-level: warn
    """.trimIndent()
}
