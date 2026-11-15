package cn.suixing.suixing_loc

import java.math.BigInteger
import java.security.KeyFactory
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.*

// Pure JVM protocol core. All calls belong to one session executor; Android owns transport/lifecycle.
internal object Wire {
    val marker = bytes(255, 85, 2, 0, 238, 16)
    val sync = bytes(1, 4, 255, 255, 15, 160, 1, 244, 4, 3, 10, 0, 2, 11, 2, 1, 12, 1, 2)
    fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }
    fun u8(b: Byte) = b.toInt() and 255
    fun u16(b: ByteArray, p: Int) = (u8(b[p]) shl 8) or u8(b[p + 1])
    fun word(n: Int) = bytes(n shr 8, n)
    fun checksum(data: ByteArray) = (-data.sumOf { u8(it) }).toByte()
    fun param(id: Int, value: ByteArray = byteArrayOf()) = word(value.size + 4) + word(id) + value
    fun str(id: Int, text: String) = param(id, (text + "\u0000").toByteArray(Charsets.UTF_8))
    fun csm(id: Int, vararg params: ByteArray): ByteArray {
        val body = params.fold(byteArrayOf()) { a, b -> a + b }
        require(body.size <= 65529) { "控制消息过长" }
        return bytes(64, 64) + word(body.size + 6) + word(id) + body
    }
    fun params(data: ByteArray): Map<Int, ByteArray> {
        val result = linkedMapOf<Int, ByteArray>()
        var p = 0
        while (p < data.size) {
            require(p + 4 <= data.size) { "控制参数头不完整" }
            val length = u16(data, p)
            require(length >= 4 && p + length <= data.size) { "控制参数长度错误" }
            result[u16(data, p + 2)] = data.copyOfRange(p + 4, p + length)
            p += length
        }
        return result
    }
    fun packet(control: Int, seq: Int, ack: Int, sid: Int, payload: ByteArray? = null): ByteArray {
        val header = bytes(255, 90) + word(if (payload == null) 9 else payload.size + 10) +
            bytes(control, seq, ack, sid)
        return header + byteArrayOf(checksum(header)) +
            (payload?.let { it + byteArrayOf(checksum(it)) } ?: byteArrayOf())
    }
    fun mac(text: String): ByteArray {
        require(Regex("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$").matches(text)) { "蓝牙地址格式应为 AA:BB:CC:DD:EE:FF" }
        require(text != "02:00:00:00:00:00" && text != "00:00:00:00:00:00" && !text.equals("FF:FF:FF:FF:FF:FF", true)) {
            "请填写安卓手机的真实蓝牙地址，不能使用系统占位值"
        }
        return text.split(':').map { it.toInt(16).toByte() }.toByteArray()
    }
    fun identification(localMac: ByteArray, serial: String): ByteArray {
        require(localMac.size == 6)
        val name = "iAP2 Loc " + serial.takeLast(4)
        return str(0, name) + str(1, "Loc1,1") + str(2, "carplay-loc") + str(3, serial) +
            str(4, "0.1.0") + str(5, "1.0") +
            param(6, word(0xAA01) + word(0xAA03) + word(0xFFFB)) +
            param(7, word(0xAA00) + word(0xAA02) + word(0xAA04) + word(0xAA05) + word(0xFFFA) + word(0xFFFC)) +
            param(8, bytes(0)) + param(9, word(20)) + str(12, "en") + str(13, "en") +
            param(17, param(0, word(0)) + str(1, "blue") + param(2) + param(3, localMac) + str(4, "blue") + param(5)) +
            param(22, param(0, word(0)) + str(1, name) + param(17) + param(18))
    }
}

internal class MfiIdentity(privateBytes: ByteArray, val certificate: ByteArray) {
    private val key = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(privateBytes)) as ECPrivateKey
    companion object {
        val order = BigInteger("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551", 16)
        // java.security returns DER; iAP2 requires fixed width r || low-s, exactly 64 bytes.
        fun rawSignature(der: ByteArray): ByteArray {
            var p = 0
            fun length(): Int {
                val first = Wire.u8(der[p++])
                if (first < 128) return first
                val n = first and 127
                require(n in 1..2 && p + n <= der.size) { "签名长度无效" }
                var result = 0
                repeat(n) { result = (result shl 8) or Wire.u8(der[p++]) }
                return result
            }
            require(Wire.u8(der[p++]) == 0x30)
            val size = length()
            require(p + size == der.size)
            fun integer(): BigInteger {
                require(Wire.u8(der[p++]) == 2)
                val n = length()
                require(n in 1..33 && p + n <= der.size)
                return BigInteger(der.copyOfRange(p, p + n)).also { p += n }
            }
            val r = integer()
            var s = integer()
            require(p == der.size && r.signum() > 0 && r < order && s.signum() > 0 && s < order)
            if (s > order.shiftRight(1)) s = order - s
            fun fixed(n: BigInteger): ByteArray {
                val b = n.toByteArray().let { if (it.size == 33 && it[0] == 0.toByte()) it.copyOfRange(1, 33) else it }
                require(b.size <= 32)
                return ByteArray(32 - b.size) + b
            }
            return fixed(r) + fixed(s)
        }
    }
    init {
        require(key.params.order == order) { "内置身份不是 P-256 密钥" }
        val probe = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val signature = signDer(probe)
        val certs = CertificateFactory.getInstance("X.509").generateCertificates(certificate.inputStream())
        require(certs.any { cert ->
            val pub = cert.publicKey as? ECPublicKey
            pub != null && pub.params.order == order && runCatching {
                Signature.getInstance("NONEwithECDSA").run { initVerify(pub); update(probe); verify(signature) }
            }.getOrDefault(false)
        }) { "内置证书与私钥不匹配" }
    }
    private fun signDer(hash: ByteArray): ByteArray = Signature.getInstance("NONEwithECDSA").run {
        initSign(key); update(hash); sign()
    }
    fun sign(challenge: ByteArray): ByteArray {
        require(challenge.size == 32) { "iPhone 认证挑战应为 32 字节，当前为 ${challenge.size}" }
        return rawSignature(signDer(challenge))
    }
}

internal class Iap2Link(
    private val write: (ByteArray) -> Unit,
    private val message: (Int, Map<Int, ByteArray>) -> Unit,
    private val ready: () -> Unit,
    private val fail: (String) -> Unit,
    private val clock: () -> Long
) {
    enum class State { DETECT, NEGOTIATE, NORMAL, DEAD }
    var state = State.DETECT; private set
    var bytesIn = 0L; private set
    var bytesOut = 0L; private set
    private var input = byteArrayOf()
    private var controlBuffer = byteArrayOf()
    private var startedAt = 0L
    private var markerAt = 0L
    private var syncAt = 0L
    private var seq = 0
    private var ack = 0
    private var window = 4
    private var maxLength = 4000
    private var timeout = 500
    private var maxRetries = 4
    private data class Pending(val seq: Int, val data: ByteArray, var at: Long, var retries: Int = 0)
    private val pending = mutableListOf<Pending>()
    private val queued = ArrayDeque<ByteArray>()
    private val reordered = mutableMapOf<Int, Pair<Int, ByteArray>>()
    fun start() { startedAt = clock(); markerAt = startedAt; raw(Wire.marker) }
    fun close() { state = State.DEAD; queued.clear(); pending.clear(); reordered.clear(); input = byteArrayOf(); controlBuffer = byteArrayOf() }
    private fun bad(reason: String) { if (state != State.DEAD) { close(); fail(reason) } }
    private fun raw(data: ByteArray) { if (state != State.DEAD) { write(data); bytesOut += data.size } }
    private fun packet(ctrl: Int, sequence: Int = seq, sid: Int = 0, data: ByteArray? = null) = raw(Wire.packet(ctrl, sequence, ack, sid, data))
    private fun sync() { syncAt = clock(); packet(128, data = Wire.sync) }
    fun send(id: Int, vararg params: ByteArray) {
        check(state != State.DEAD) { "iAP2 链路已断开" }
        val data = Wire.csm(id, *params)
        val chunk = (maxLength - 10).coerceAtLeast(1)
        check(queued.size + (data.size + chunk - 1) / chunk <= 2048) { "iPhone 接收过慢，发送队列已满" }
        for (offset in data.indices step chunk) queued.addLast(data.copyOfRange(offset, minOf(offset + chunk, data.size)))
        flush()
    }
    private fun flush() {
        while (state == State.NORMAL && queued.isNotEmpty() && pending.size < window) {
            val data = queued.removeFirst(); seq = (seq + 1) and 255
            pending.add(Pending(seq, data, clock()))
            packet(64, seq, 10, data)
        }
    }
    fun receive(data: ByteArray) {
        if (state == State.DEAD) return
        bytesIn += data.size
        require(input.size + data.size <= 131072) { "蓝牙接收缓存超限" }
        input += data
        if (state == State.DETECT) {
            if (input.size < 6) return
            if (!input.copyOfRange(0, 6).contentEquals(Wire.marker)) { bad("iPhone 未回应 iAP2 探测标记"); return }
            input = input.copyOfRange(6, input.size)
            state = State.NEGOTIATE; startedAt = clock(); sync()
        }
        while (state != State.DEAD && input.size >= 9) {
            if (input.copyOfRange(0, 6).contentEquals(Wire.marker)) { input = input.copyOfRange(6, input.size); continue }
            if (Wire.u8(input[0]) != 255 || Wire.u8(input[1]) != 90) { input = input.copyOfRange(1, input.size); continue }
            val size = Wire.u16(input, 2)
            if (size < 9) { bad("iAP2 数据包长度错误"); return }
            if (input.size < size) return
            val frame = input.copyOfRange(0, size); input = input.copyOfRange(size, input.size)
            handle(frame)
        }
    }
    private fun handle(frame: ByteArray) {
        if (frame.take(9).sumOf { Wire.u8(it) } and 255 != 0) return
        val payload = if (frame.size > 10) frame.copyOfRange(9, frame.size - 1) else null
        if (frame.size == 10) { bad("iAP2 数据包缺少有效载荷"); return }
        if (payload != null && (frame.drop(9).sumOf { Wire.u8(it) } and 255) != 0) return
        val ctrl = Wire.u8(frame[4]); val sequence = Wire.u8(frame[5]); val acknowledge = Wire.u8(frame[6]); val sid = Wire.u8(frame[7])
        if (ctrl and 16 != 0) { bad("iPhone 重置了 iAP2 连接"); return }
        if (ctrl and 128 != 0) {
            if (payload == null || payload.size < 10 || payload[0] != 1.toByte()) { bad("iAP2 协商参数无效"); return }
            window = Wire.u8(payload[1]).coerceIn(1, 64)
            maxLength = Wire.u16(payload, 2).coerceAtLeast(64)
            timeout = Wire.u16(payload, 4).coerceAtLeast(50)
            maxRetries = Wire.u8(payload[8]).coerceAtLeast(1)
            ack = sequence; packet(64)
        }
        if (ctrl and 64 != 0) {
            pending.removeAll { ((acknowledge - it.seq) and 255) < 128 }
            if (state == State.NEGOTIATE) { state = State.NORMAL; ready() }
            flush()
        }
        if (ctrl and 32 != 0 && payload != null) {
            for (missing in payload) pending.find { it.seq == Wire.u8(missing) }?.let { packet(64, it.seq, 10, it.data) }
            return
        }
        if (ctrl and 64.inv() == 0 && payload != null) {
            val distance = (sequence - ack) and 255
            when {
                distance == 1 -> {
                    ack = sequence; deliver(sid, payload)
                    while (state != State.DEAD) {
                        val next = reordered.remove((ack + 1) and 255) ?: break
                        ack = (ack + 1) and 255; deliver(next.first, next.second)
                    }
                    packet(64)
                }
                distance in 2..127 && reordered.size < 64 -> {
                    reordered[sequence] = sid to payload
                    packet(32, data = ByteArray(distance - 1) { ((ack + it + 1) and 255).toByte() })
                }
                else -> packet(64)
            }
        }
    }
    private fun deliver(sid: Int, data: ByteArray) {
        if (sid != 10 || state == State.DEAD) return
        require(controlBuffer.size + data.size <= 131072) { "控制消息缓存超限" }
        controlBuffer += data
        while (controlBuffer.size >= 6 && state != State.DEAD) {
            require(Wire.u16(controlBuffer, 0) == 0x4040) { "控制消息标记错误" }
            val size = Wire.u16(controlBuffer, 2)
            require(size >= 6) { "控制消息长度错误" }
            if (controlBuffer.size < size) return
            val id = Wire.u16(controlBuffer, 4)
            val params = Wire.params(controlBuffer.copyOfRange(6, size))
            controlBuffer = controlBuffer.copyOfRange(size, controlBuffer.size)
            message(id, params)
        }
    }
    fun tick() {
        val now = clock()
        when (state) {
            State.DETECT -> {
                if (now - startedAt > 15000) { bad("iAP2 探测超时：请确认已配对，且 iPhone 没有被其他定位连接占用"); return }
                if (now - markerAt >= 1000) { raw(Wire.marker); markerAt = now }
            }
            State.NEGOTIATE -> {
                if (now - startedAt > 20000) { bad("iAP2 协商超时"); return }
                if (now - syncAt >= 500) sync()
            }
            State.NORMAL -> for (item in pending.toList()) {
                if (now - item.at < timeout) continue
                if (++item.retries > maxRetries) { bad("iAP2 数据确认超时，蓝牙连接已停止"); return }
                item.at = now; packet(64, item.seq, 10, item.data)
            }
            State.DEAD -> Unit
        }
    }
}

internal data class Fix(val lat: Double, val lon: Double, val altitude: Double = 0.0, val revision: Long = 0) {
    init {
        require(lat.isFinite() && lat in -90.0..90.0) { "纬度需在 -90 至 90 之间" }
        require(lon.isFinite() && lon in -180.0..180.0) { "经度需在 -180 至 180 之间" }
        require(altitude.isFinite() && altitude in -1000.0..100000.0) { "海拔需在 -1000 至 100000 米之间" }
    }
}
internal object Nmea {
    private val time = DateTimeFormatter.ofPattern("HHmmss'.00'").withZone(ZoneOffset.UTC)
    private val date = DateTimeFormatter.ofPattern("ddMMyy").withZone(ZoneOffset.UTC)
    fun coordinate(value: Double, lat: Boolean): Pair<String, String> {
        var degrees = abs(value).toInt(); var minutes = (abs(value) - degrees) * 60
        if (minutes >= 60 - 0.00005) { degrees++; minutes = 0.0 }
        return String.format(Locale.US, if (lat) "%02d%07.4f" else "%03d%07.4f", degrees, minutes) to
            (if (lat) { if (value >= 0) "N" else "S" } else { if (value >= 0) "E" else "W" })
    }
    fun sentence(body: String): String = "$" + body + "*" + String.format(Locale.US, "%02X", body.fold(0) { a, b -> a xor b.code }) + "\r\n"
    fun encode(fix: Fix, utc: Instant, speed: Double = 0.0, bearing: Double? = null): Map<Int, String> {
        val (lat, ns) = coordinate(fix.lat, true); val (lon, ew) = coordinate(fix.lon, false)
        val t = time.format(utc); val d = date.format(utc)
        val alt = String.format(Locale.US, "%.1f", fix.altitude)
        val knots = String.format(Locale.US, "%.2f", speed * 1.94384449)
        val course = bearing?.let { String.format(Locale.US, "%.2f", it) } ?: ""
        return mapOf(1 to sentence("GPGGA,$t,$lat,$ns,$lon,$ew,1,08,1.0,$alt,M,0.0,M,,"),
            2 to sentence("GPRMC,$t,A,$lat,$ns,$lon,$ew,$knots,$course,$d,,"))
    }
    fun movement(from: Fix, to: Fix): Pair<Double, Double?> {
        val p1 = Math.toRadians(from.lat); val p2 = Math.toRadians(to.lat)
        val dl = Math.toRadians(to.lon - from.lon); val dp = p2 - p1
        val a = (sin(dp / 2).pow(2) + cos(p1) * cos(p2) * sin(dl / 2).pow(2)).coerceIn(0.0, 1.0)
        if (6371000 * 2 * atan2(sqrt(a), sqrt(1 - a)) < 100) return 0.0 to null
        val bearing = (Math.toDegrees(atan2(sin(dl) * cos(p2), cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl))) + 360) % 360
        return 250.0 to bearing
    }
}

internal class LocationProtocol(
    private val link: Iap2Link,
    private val identity: MfiIdentity,
    private val localMac: ByteArray,
    private val clock: () -> Long,
    private val log: (String) -> Unit,
    private val fail: (String) -> Unit
) {
    var identified = false; private set
    var authenticated = false; private set
    var subscribed = false; private set
    var target: Fix? = null; private set
    var reports = 0L; private set
    var queuedRevision = 0L; private set
    var queuedAt: String? = null; private set
    private val serial = "LC" + ByteArray(6).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02X".format(Wire.u8(it)) }
    private var sentences = setOf(1, 2)
    private var periods = mapOf<Int, Int>()
    private val lastSent = mutableMapOf<Int, Long>()
    private var lastRmc: Fix? = null
    fun apply(fix: Fix) { target = fix.copy(revision = (target?.revision ?: 0) + 1) }
    fun message(id: Int, params: Map<Int, ByteArray>) {
        when (id) {
            0x1D00 -> { log("收到身份识别请求，发送蓝牙与定位组件"); link.send(0x1D01, Wire.identification(localMac, serial)) }
            0x1D02 -> { identified = true; log("iPhone 已接受配件身份") }
            0x1D03 -> { identified = false; fail("iPhone 拒绝配件身份，参数：" + params.keys.joinToString { "0x%04X".format(it) } + if (17 in params) "；请核对安卓本机蓝牙地址" else "") }
            0xAA00 -> { log("发送内置实验身份证书"); link.send(0xAA01, Wire.param(0, identity.certificate)) }
            0xAA02 -> { val challenge = params[0] ?: error("认证请求缺少挑战参数"); link.send(0xAA03, Wire.param(0, identity.sign(challenge))); log("已发送认证签名") }
            0xAA04 -> { authenticated = false; subscribed = false; fail("iPhone 拒绝认证材料，蓝牙定位已停止") }
            0xAA05 -> { authenticated = true; log("iPhone 认证通过") }
            0xFFFA -> {
                sentences = params.filter { it.key in 1..2 && it.value.isEmpty() }.keys.toSet().ifEmpty { setOf(1, 2) }
                periods = params.filter { it.key in 0x8001..0x8002 && it.value.size == 4 }.mapNotNull { (key, value) ->
                    val period = value.fold(0L) { a, b -> (a shl 8) or Wire.u8(b).toLong() }
                    if (period in 1..Int.MAX_VALUE.toLong()) key - 0x8000 to period.toInt() else null
                }.toMap()
                lastSent.clear(); subscribed = true
                log("iPhone 已订阅定位：" + sentences.joinToString { (if (it == 1) "GGA" else "RMC") + " ${periods[it] ?: 1000} 毫秒" })
            }
            0xFFFC -> { subscribed = false; lastSent.clear(); log("iPhone 已暂停定位订阅") }
            0xEA00, 0xEA01 -> Unit
            else -> log("收到控制消息 0x%04X".format(id))
        }
    }
    fun tick(utc: Instant = Instant.now()) {
        if (!authenticated || !subscribed || link.state != Iap2Link.State.NORMAL) return
        val fix = target ?: return
        val now = clock()
        val due = sentences.filter { now - (lastSent[it] ?: (now - (periods[it] ?: 1000))) >= (periods[it] ?: 1000) }
        if (due.isEmpty()) return
        val (speed, bearing) = lastRmc?.let { Nmea.movement(it, fix) } ?: (0.0 to null)
        val nmea = Nmea.encode(fix, utc, speed, bearing)
        link.send(0xFFFB, *due.map { Wire.param(0, (nmea.getValue(it) + "\u0000").toByteArray(Charsets.UTF_8)) }.toTypedArray())
        due.forEach { lastSent[it] = now }
        if (2 in due) lastRmc = fix
        reports++; queuedRevision = fix.revision; queuedAt = utc.toString()
    }
}
