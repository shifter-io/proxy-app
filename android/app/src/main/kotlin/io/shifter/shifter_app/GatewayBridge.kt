package io.shifter.shifter_app

import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.Collections
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * Local bridge between the packet engine and the Shifter gateway, on
 * 127.0.0.1 inside this app (which is outside the VPN). Each local
 * connection, SOCKS5 CONNECT from the engine or HTTP CONNECT from the app's
 * exit check, becomes one TLS connection to the gateway carrying an HTTP
 * CONNECT with the plan login, so everything between the device and the
 * gateway is encrypted. UDP is refused here; apps fall back to TCP.
 *
 * Local clients must present [secret] (SOCKS5 username/password, or HTTP
 * Proxy-Authorization), so other apps on the device can't use the plan.
 */
class GatewayBridge(private val login: SocksLogin) {
    private val server = ServerSocket(0, 512, InetAddress.getByName("127.0.0.1"))
    private val open = Collections.synchronizedSet(mutableSetOf<Closeable>())
    @Volatile private var closed = false

    /** Set when the gateway refuses the plan login (407). */
    @Volatile var rejected = false
        private set

    val port: Int get() = server.localPort

    /** Random per-session secret local clients must present (username "shifter"). */
    val secret: String = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
    private val localAuthorization =
        "Basic " + Base64.encodeToString("shifter:$secret".toByteArray(), Base64.NO_WRAP)

    private val authorization =
        "Basic " + Base64.encodeToString("${login.username}:${login.password}".toByteArray(), Base64.NO_WRAP)

    fun start() {
        thread("bridge-accept") {
            while (!closed) {
                val client = try { server.accept() } catch (e: Exception) { break }
                open += client
                thread("bridge-conn") { serve(client) }
            }
        }
    }

    fun stop() {
        closed = true
        runCatching { server.close() }
        synchronized(open) { open.toList() }.forEach { runCatching { it.close() } }
        open.clear()
    }

    private fun serve(client: Socket) {
        var upstream: Socket? = null
        var piping = false
        try {
            client.soTimeout = 15_000
            val inp = DataInputStream(client.getInputStream())
            val out = client.getOutputStream()
            val first = inp.readUnsignedByte()
            val socks = first == 5
            val target: String
            if (socks) {
                val methods = ByteArray(inp.readUnsignedByte()).also { inp.readFully(it) }
                if (2.toByte() !in methods) return out.write(byteArrayOf(5, 0xFF.toByte()))
                out.write(byteArrayOf(5, 2)) // username/password: the session secret
                if (inp.readUnsignedByte() != 1) return
                val user = String(ByteArray(inp.readUnsignedByte()).also { inp.readFully(it) })
                val pass = String(ByteArray(inp.readUnsignedByte()).also { inp.readFully(it) })
                if (user != "shifter" || !constantTimeEquals(pass, secret)) return out.write(byteArrayOf(1, 1))
                out.write(byteArrayOf(1, 0))
                val head = ByteArray(4).also { inp.readFully(it) }
                if (head[1].toInt() != 1) return reply(out, 7) // only CONNECT: no UDP for now
                val host = when (head[3].toInt()) {
                    1 -> InetAddress.getByAddress(ByteArray(4).also { inp.readFully(it) }).hostAddress!!
                    3 -> String(ByteArray(inp.readUnsignedByte()).also { inp.readFully(it) })
                    else -> return reply(out, 8) // IPv6: the gateway reaches IPv4 only
                }
                target = "$host:${inp.readUnsignedShort()}"
            } else {
                val head = first.toChar() + readHead(inp)
                val auth = head.lineSequence().firstOrNull { it.startsWith("Proxy-Authorization:", ignoreCase = true) }
                    ?.substringAfter(':')?.trim()
                if (auth == null || !constantTimeEquals(auth, localAuthorization)) {
                    out.write("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Shifter\"\r\nConnection: close\r\n\r\n".toByteArray())
                    return
                }
                val parts = head.lineSequence().first().split(' ')
                if (parts.size < 2 || parts[0] != "CONNECT") {
                    out.write("HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n".toByteArray())
                    return
                }
                target = parts[1]
            }

            if (!TARGET.matches(target)) {
                if (socks) reply(out, 4) else out.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".toByteArray())
                return
            }
            val gateway = connectGateway(target)
            if (gateway == null) {
                if (socks) reply(out, 5) else out.write("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".toByteArray())
                return
            }
            upstream = gateway
            open += gateway
            if (socks) reply(out, 0) else out.write("HTTP/1.1 200 Connection established\r\n\r\n".toByteArray())
            client.soTimeout = 0
            piping = true
            pipe(gateway.getInputStream(), out, client, gateway)
            pipe(inp, gateway.getOutputStream(), client, gateway)
        } catch (e: Exception) {
            if (!closed) Log.d("ShifterBridge", "connection ended: ${e.javaClass.simpleName}")
        } finally {
            if (!piping) close(client, upstream)
        }
    }

    /**
     * One test CONNECT before the tunnel starts: false when the gateway can't
     * be reached or refuses the login ([rejected]). Network I/O: off the main thread.
     */
    fun check(): Boolean = runCatching { connectGateway("www.google.com:443")?.also { it.close() } != null }.getOrDefault(false)

    /** TLS to the gateway, then CONNECT [target]; null if the gateway refuses. */
    private fun connectGateway(target: String): Socket? {
        val raw = Socket()
        raw.connect(InetSocketAddress(login.host, login.port), 10_000)
        val tls = (SSLSocketFactory.getDefault() as SSLSocketFactory)
            .createSocket(raw, login.host, login.port, true) as SSLSocket
        tls.sslParameters = tls.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
        tls.soTimeout = 15_000
        tls.startHandshake()
        tls.getOutputStream().write(
            "CONNECT $target HTTP/1.1\r\nHost: $target\r\nProxy-Authorization: $authorization\r\n\r\n".toByteArray(),
        )
        val status = readHead(DataInputStream(tls.getInputStream())).lineSequence().first().split(' ').getOrNull(1)
        if (status == "200") {
            tls.soTimeout = 0
            return tls
        }
        if (status == "407") rejected = true
        tls.close()
        return null
    }

    private fun constantTimeEquals(a: String, b: String): Boolean =
        java.security.MessageDigest.isEqual(a.toByteArray(), b.toByteArray())

    private fun reply(out: OutputStream, code: Int) {
        out.write(byteArrayOf(5, code.toByte(), 0, 1, 0, 0, 0, 0, 0, 0))
    }

    /** Reads an HTTP header block up to and including the blank line. */
    private fun readHead(inp: InputStream): String {
        val buf = ByteArrayOutputStream()
        var state = 0
        while (state < 4) {
            val b = inp.read()
            if (b < 0) break
            buf.write(b)
            state = when {
                (state == 0 || state == 2) && b == '\r'.code -> state + 1
                (state == 1 || state == 3) && b == '\n'.code -> state + 1
                b == '\r'.code -> 1
                else -> 0
            }
            if (buf.size() > 16_384) break
        }
        return buf.toString("ISO-8859-1")
    }

    private fun pipe(from: InputStream, to: OutputStream, a: Socket, b: Socket) {
        thread("bridge-pipe") {
            val buf = ByteArray(16_384)
            try {
                while (true) {
                    val n = from.read(buf)
                    if (n < 0) break
                    to.write(buf, 0, n)
                }
            } catch (_: Exception) {
            }
            close(a, b)
        }
    }

    private fun close(vararg sockets: Socket?) {
        for (s in sockets) {
            if (s == null) continue
            runCatching { s.close() }
            open -= s
        }
    }

    private companion object {
        /** host:port with a plain host name or IPv4 address: nothing that could break the CONNECT line. */
        val TARGET = Regex("^[A-Za-z0-9.-]{1,253}:[0-9]{1,5}$")
    }

    private fun thread(name: String, body: () -> Unit) {
        Thread(null, body, name, 64 * 1024).apply { isDaemon = true }.start()
    }
}
