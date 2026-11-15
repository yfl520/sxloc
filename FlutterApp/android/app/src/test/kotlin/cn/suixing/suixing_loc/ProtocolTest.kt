package cn.suixing.suixing_loc

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.math.BigInteger
import java.security.Signature
import java.security.cert.CertificateFactory
import java.time.Instant

class ProtocolTest {
    private fun identity(): MfiIdentity {
        val folder = File(requireNotNull(System.getenv("ANDROID_TEST_IDENTITY_DIR")) { "请设置离线测试身份材料目录" })
        return MfiIdentity(File(folder, "identity.pk8").readBytes(), File(folder, "certificate.p7b").readBytes())
    }
    private class Peer {
        var time = 0L
        val output = mutableListOf<ByteArray>()
        val messages = mutableListOf<Pair<Int, Map<Int, ByteArray>>>()
        val failures = mutableListOf<String>()
        var remoteSeq = 0
        var remoteAck = 0
        lateinit var handle: (Int, Map<Int, ByteArray>) -> Unit
        val link = Iap2Link({ output.add(it) }, { id, p -> messages.add(id to p); if (::handle.isInitialized) handle(id, p) }, {}, { failures.add(it) }, { time })
        fun ready(maxLength: Int = 65535) {
            link.start()
            // Marker and frame split across arbitrary reads.
            link.receive(Wire.marker.copyOfRange(0, 2))
            link.receive(Wire.marker.copyOfRange(2, 6))
            val sync = Wire.sync.copyOf().apply { this[2] = (maxLength shr 8).toByte(); this[3] = maxLength.toByte() }
            link.receive(Wire.packet(128, 0, 0, 0, sync))
            link.receive(Wire.packet(64, 0, 0, 0))
            assertEquals(Iap2Link.State.NORMAL, link.state)
            output.clear()
        }
        fun send(id: Int, vararg params: ByteArray) {
            remoteSeq = (remoteSeq + 1) and 255
            val frame = Wire.packet(64, remoteSeq, remoteAck, 10, Wire.csm(id, *params))
            frame.asList().chunked(7).forEach { link.receive(it.toByteArray()) }
        }
        fun ackOutput() {
            output.lastOrNull { it.size > 10 && Wire.u8(it[4]) == 64 && Wire.u8(it[7]) == 10 }?.let { remoteAck = Wire.u8(it[5]) }
            output.clear(); link.receive(Wire.packet(64, remoteSeq, remoteAck, 0))
        }
        fun data() = output.filter { it.size > 10 && Wire.u8(it[7]) == 10 }.map { it.copyOfRange(9, it.size - 1) }
    }
    @Test fun packetChecksumsAndDuplicateTlvArePreserved() {
        val data = Wire.csm(0xFFFB, Wire.str(0, "first"), Wire.str(0, "second"))
        assertEquals(0x4040, Wire.u16(data, 0)); assertEquals(data.size, Wire.u16(data, 2))
        val firstLength = Wire.u16(data, 6)
        assertEquals(0, Wire.u16(data, 8)); assertEquals(0, Wire.u16(data, 6 + firstLength + 2))
        val packet = Wire.packet(64, 255, 0, 10, data)
        assertEquals(0, packet.take(9).sumOf { Wire.u8(it) } and 255)
        assertEquals(0, packet.drop(9).sumOf { Wire.u8(it) } and 255)
        assertEquals(9, Wire.packet(64, 0, 0, 0).size)
    }
    @Test fun malformedTlvFailsIncludingTrailingBytes() {
        for (bad in listOf(Wire.bytes(0, 3, 0, 1), Wire.bytes(0, 5, 0, 1), Wire.bytes(0))) {
            assertThrows(IllegalArgumentException::class.java) { Wire.params(bad) }
        }
    }
    @Test fun identificationHasMandatoryTransportAndLocation() {
        val mac = Wire.mac("A0:B1:C2:D3:E4:F5")
        val params = Wire.params(Wire.identification(mac, "LC012345678901"))
        val transport = Wire.params(params.getValue(17))
        assertArrayEquals(mac, transport[3])
        assertTrue(2 in transport && 5 in transport)
        val location = Wire.params(params.getValue(22))
        assertTrue(17 in location && 18 in location)
        assertArrayEquals(Wire.word(0xAA01) + Wire.word(0xAA03) + Wire.word(0xFFFB), params[6])
    }
    @Test fun placeholderAndMalformedMacAreRejected() {
        for (bad in listOf("02:00:00:00:00:00", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "broken", "AA:BB:CC:DD:EE:GG")) {
            assertThrows(IllegalArgumentException::class.java) { Wire.mac(bad) }
        }
    }
    @Test fun fragmentationRespectsNegotiatedPacketLength() {
        val peer = Peer(); peer.ready(64)
        peer.link.send(0xAA01, Wire.param(0, ByteArray(607) { it.toByte() }))
        val reassembled = java.io.ByteArrayOutputStream()
        var loops = 0
        while (peer.data().isNotEmpty() && loops++ < 20) {
            peer.output.filter { it.size > 10 }.forEach { assertTrue(it.size <= 64) }
            peer.data().forEach { reassembled.write(it) }
            peer.ackOutput()
        }
        assertArrayEquals(Wire.csm(0xAA01, Wire.param(0, ByteArray(607) { it.toByte() })), reassembled.toByteArray())
    }
    @Test fun sequenceWrapAndDuplicatesDeliverExactlyOnce() {
        val peer = Peer(); peer.ready()
        repeat(270) { peer.send(0xEA00); peer.ackOutput() }
        assertEquals(270, peer.messages.size)
        peer.link.receive(Wire.packet(64, peer.remoteSeq, 0, 10, Wire.csm(0xEA00)))
        assertEquals(270, peer.messages.size)
    }
    @Test fun outOfOrderRequestsRetransmitThenDeliversInOrder() {
        val peer = Peer(); peer.ready()
        peer.link.receive(Wire.packet(64, 2, 0, 10, Wire.csm(0xEA01)))
        assertTrue(peer.messages.isEmpty())
        assertTrue(peer.output.any { Wire.u8(it[4]) == 32 && it[9] == 1.toByte() })
        peer.link.receive(Wire.packet(64, 1, 0, 10, Wire.csm(0xEA00)))
        assertEquals(listOf(0xEA00, 0xEA01), peer.messages.map { it.first })
    }
    @Test fun corruptChecksumIsDroppedAndValidRetransmissionWorks() {
        val peer = Peer(); peer.ready()
        val frame = Wire.packet(64, 1, 0, 10, Wire.csm(0xEA00))
        val corrupt = frame.copyOf(); corrupt[10] = (corrupt[10].toInt() xor 1).toByte()
        peer.link.receive(corrupt); assertTrue(peer.messages.isEmpty())
        peer.link.receive(frame); assertEquals(1, peer.messages.size)
    }
    @Test fun timeoutRetriesThenClosesWithoutSendingAgain() {
        val peer = Peer(); peer.ready(); peer.link.send(0xAA01, Wire.param(0, Wire.bytes(1)))
        repeat(5) { peer.time += 4001; peer.link.tick() }
        assertEquals(Iap2Link.State.DEAD, peer.link.state); assertEquals(1, peer.failures.size)
        val count = peer.output.size; peer.time += 10000; peer.link.tick()
        assertEquals(count, peer.output.size)
    }
    @Test fun detectTimeoutAndRemoteResetCloseLink() {
        val peer = Peer(); peer.link.start(); peer.time = 15001; peer.link.tick()
        assertEquals(Iap2Link.State.DEAD, peer.link.state)
        val other = Peer(); other.ready(); other.link.receive(Wire.packet(16, 0, 0, 0))
        assertEquals(Iap2Link.State.DEAD, other.link.state)
    }
    @Test fun identitySignsDigestWithoutHashingTwice() {
        val identity = identity()
        val hash = ByteArray(32) { (it + 1).toByte() }
        val raw = identity.sign(hash); assertEquals(64, raw.size)
        val s = BigInteger(1, raw.copyOfRange(32, 64)); assertTrue(s <= MfiIdentity.order.shiftRight(1))
        fun integer(value: ByteArray): ByteArray {
            val bytes = BigInteger(1, value).toByteArray()
            return Wire.bytes(2, bytes.size) + bytes
        }
        val body = integer(raw.copyOfRange(0, 32)) + integer(raw.copyOfRange(32, 64))
        val der = Wire.bytes(0x30, body.size) + body
        val certificates = CertificateFactory.getInstance("X.509").generateCertificates(identity.certificate.inputStream())
        assertTrue(certificates.any { cert -> runCatching {
            Signature.getInstance("NONEwithECDSA").run { initVerify(cert.publicKey); update(hash); verify(der) }
        }.getOrDefault(false) })
        assertThrows(IllegalArgumentException::class.java) { identity.sign(ByteArray(20)) }
    }
    @Test fun nmeaUtcHemispheresAndMinuteRollover() {
        val utc = Instant.parse("2026-11-15T12:35:19Z")
        val gga = Nmea.encode(Fix(48.1173, 11.516666666667, 545.4), utc).getValue(1)
        assertTrue(gga.startsWith("\$GPGGA,123519.00,4807.0380,N,01131.0000,E,1,08,1.0,545.4,M,0.0,M,,*"))
        assertTrue(gga.endsWith("\r\n"))
        val rmc = Nmea.encode(Fix(-31.2, -121.5), utc).getValue(2)
        assertTrue(rmc.contains(",S,12130.0000,W,0.00,,151126,,*"))
        assertEquals("1300.0000", Nmea.coordinate(12.99999999, true).first)
        assertThrows(IllegalArgumentException::class.java) { Fix(Double.NaN, 0.0) }
        assertThrows(IllegalArgumentException::class.java) { Fix(0.0, 181.0) }
    }
    @Test fun subscriptionBeforeAuthWaitsAndHonorsEachSentencePeriod() {
        val peer = Peer(); peer.ready()
        val p = LocationProtocol(peer.link, identity(), Wire.mac("A0:B1:C2:D3:E4:F5"), { peer.time }, {}, { fail(it) })
        peer.handle = p::message
        p.apply(Fix(31.2, 121.5))
        peer.send(0xFFFA, Wire.param(1), Wire.param(2), Wire.param(0x8001, Wire.bytes(0, 0, 0, 250)), Wire.param(0x8002, Wire.bytes(0, 0, 3, 232)))
        peer.ackOutput(); p.tick(); assertEquals(0L, p.reports)
        peer.send(0xAA05); peer.ackOutput(); p.tick(); assertEquals(1L, p.reports)
        val initial = peer.data().single()
        val length = Wire.u16(initial, 6)
        assertEquals(0, Wire.u16(initial, 8)); assertEquals(0, Wire.u16(initial, 6 + length + 2))
        peer.ackOutput(); peer.time = 249; p.tick(); assertEquals(1L, p.reports)
        peer.time = 250; p.tick(); assertEquals(2L, p.reports)
        val gga = peer.data().single().toString(Charsets.UTF_8)
        assertTrue(gga.contains("GPGGA")); assertFalse(gga.contains("GPRMC"))
        peer.ackOutput(); peer.send(0xFFFC); peer.ackOutput(); peer.time = 2000; p.tick(); assertEquals(2L, p.reports)
    }
    @Test fun continuousTargetsIncrementRevisionAndJumpAppliesOnlyToFirstRmc() {
        val peer = Peer(); peer.ready()
        val p = LocationProtocol(peer.link, identity(), Wire.mac("A0:B1:C2:D3:E4:F5"), { peer.time }, {}, { fail(it) })
        peer.handle = p::message
        p.apply(Fix(31.2, 121.5)); peer.send(0xAA05); peer.send(0xFFFA, Wire.param(2)); peer.ackOutput()
        p.tick(); assertEquals(1L, p.queuedRevision); peer.ackOutput()
        p.apply(Fix(39.9, 116.4)); peer.time = 1000; p.tick()
        assertEquals(2L, p.queuedRevision); assertTrue(peer.data().single().toString(Charsets.UTF_8).contains(",485.96,"))
        peer.ackOutput(); peer.time = 2000; p.tick()
        assertTrue(peer.data().single().toString(Charsets.UTF_8).contains(",0.00,,"))
        assertEquals(Iap2Link.State.NORMAL, peer.link.state)
    }
    @Test fun authRejectionStopsLocationEvenAfterSubscription() {
        val peer = Peer(); peer.ready(); val failures = mutableListOf<String>()
        val p = LocationProtocol(peer.link, identity(), Wire.mac("A0:B1:C2:D3:E4:F5"), { peer.time }, {}, { failures.add(it) })
        peer.handle = p::message
        p.apply(Fix(0.0, 0.0)); peer.send(0xFFFA); peer.send(0xAA05); peer.ackOutput(); p.tick(); peer.ackOutput()
        peer.send(0xAA04); peer.ackOutput(); peer.time = 1000; p.tick()
        assertEquals(1L, p.reports); assertFalse(p.authenticated); assertFalse(p.subscribed); assertEquals(1, failures.size)
    }
}
