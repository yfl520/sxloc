package cn.suixing.suixing_loc

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothSocket
import android.os.SystemClock
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** One socket and one serial protocol executor, closed together on every exit path. */
@SuppressLint("MissingPermission")
internal class BluetoothSession(
    private val adapter: BluetoothAdapter, private val remote: String,
    private val local: ByteArray, private val identity: MfiIdentity,
    private val emit: (Map<String, Any?>) -> Unit, private val ended: (String) -> Unit
) {
    companion object { val iap2Uuid: UUID = UUID.fromString("00000000-deca-fade-deca-deafdecacafe") }
    private val closed = AtomicBoolean(false)
    private val serial = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "iap2-protocol").apply { isDaemon = true } }
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "iap2-bluetooth").apply { isDaemon = true } }
    @Volatile private var socket: BluetoothSocket? = null
    private var link: Iap2Link? = null
    private var location: LocationProtocol? = null
    private val startAt = SystemClock.elapsedRealtime()
    private var connected = false
    private var lastEmit = 0L
    private var detail = "正在连接 iPhone 的 iAP2 蓝牙服务"
    private var initialSubscription = false
    private var pendingTarget: Fix? = null
    private fun execute(action: () -> Unit) {
        if (closed.get()) return
        runCatching { serial.execute { if (!closed.get()) guard(action) } }
    }
    private fun guard(action: () -> Unit) {
        try { action() } catch (error: Exception) {
            finish(if (error is SecurityException) "蓝牙权限被撤回，请重新授权附近设备" else
                "蓝牙会话失败：${error.message ?: error.javaClass.simpleName}")
        }
    }
    fun start() {
        execute { log(detail) }
        serial.scheduleAtFixedRate({ if (!closed.get()) guard { tick() } }, 10, 10, TimeUnit.MILLISECONDS)
        io.execute {
            try {
                val channel = adapter.getRemoteDevice(remote).createRfcommSocketToServiceRecord(iap2Uuid)
                socket = channel
                if (closed.get()) { channel.close(); return@execute }
                // Paired devices only; no discovery or location permission is requested.
                channel.connect()
                if (closed.get()) { channel.close(); return@execute }
                execute {
                    connected = true
                    val protocol = Iap2Link(
                        write = { channel.outputStream.write(it); channel.outputStream.flush() },
                        message = { id, params -> location?.message(id, params) },
                        ready = { log("iAP2 协商完成，等待 iPhone 识别与认证") },
                        fail = { finish(it) }, clock = SystemClock::elapsedRealtime)
                    link = protocol
                    location = LocationProtocol(protocol, identity, local, SystemClock::elapsedRealtime, ::log, ::finish)
                    pendingTarget?.let { location?.apply(it) }; pendingTarget = null
                    log("蓝牙已连接，正在探测 iAP2")
                    protocol.start()
                }
                val buffer = ByteArray(8192)
                while (!closed.get()) {
                    val count = channel.inputStream.read(buffer)
                    if (count < 0) { finish("iPhone 已断开蓝牙连接"); break }
                    if (count > 0) { val data = buffer.copyOf(count); execute { link?.receive(data) } }
                }
            } catch (error: Exception) {
                if (!closed.get()) finish(if (error is SecurityException) "缺少蓝牙连接权限，请允许附近设备" else
                    "蓝牙连接中断：${error.message ?: "连接失败"}。请确认两台手机已配对，且桌面端已断开。")
            }
        }
    }
    fun apply(fix: Fix) = execute {
        val protocol = location
        if (protocol != null) protocol.apply(fix) else pendingTarget = fix
        log("新坐标已保存，按 iPhone 的订阅周期发送")
    }
    private fun tick() {
        val now = SystemClock.elapsedRealtime()
        if (!connected && now - startAt > 25000) { finish("蓝牙连接超时，请确认已在系统设置中配对 iPhone"); return }
        link?.tick()
        if (closed.get()) return
        location?.let { p ->
            if (p.subscribed && p.authenticated) initialSubscription = true
            if (connected && !initialSubscription && now - startAt > 90000) {
                finish("iPhone 未完成认证或定位订阅，请查看最近日志后重试"); return
            }
            p.tick()
        }
        if (now - lastEmit >= 500) publish()
    }
    private fun log(text: String) {
        detail = text
        publish()
    }
    private fun publish() {
        if (closed.get()) return
        lastEmit = SystemClock.elapsedRealtime()
        val p = location
        val phase = when {
            !connected -> "connecting"
            link?.state != Iap2Link.State.NORMAL -> "negotiating"
            p?.authenticated != true -> "authenticating"
            !p.subscribed -> "subscribing"
            p.target == null -> "ready"
            p.reports == 0L || p.queuedRevision != p.target?.revision -> "pending"
            else -> "streaming"
        }
        emit(mapOf("phase" to phase, "detail" to detail, "active" to true, "connected" to connected,
            "identified" to (p?.identified ?: false), "authenticated" to (p?.authenticated ?: false),
            "subscribed" to (p?.subscribed ?: false), "reports" to (p?.reports ?: 0L),
            "revision" to (p?.target?.revision ?: 0L), "queuedRevision" to (p?.queuedRevision ?: 0L),
            "queuedAt" to p?.queuedAt, "bytesIn" to (link?.bytesIn ?: 0L), "bytesOut" to (link?.bytesOut ?: 0L),
            "targetLat" to p?.target?.lat, "targetLon" to p?.target?.lon, "remote" to remote))
    }
    private fun finish(reason: String) { if (closeOnce()) ended(reason) }
    private fun closeOnce(): Boolean {
        if (!closed.compareAndSet(false, true)) return false
        // Close from the caller's thread to unblock connect/read/write, including a stuck writer.
        runCatching { socket?.close() }
        serial.shutdownNow(); io.shutdownNow()
        return true
    }
    fun close() { closeOnce() }
}
