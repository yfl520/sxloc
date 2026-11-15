package cn.suixing.suixing_loc

import android.app.*
import android.bluetooth.BluetoothManager
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.*

class LocationService : Service() {
    companion object {
        const val CONNECT = "cn.suixing.CONNECT"
        const val STOP = "cn.suixing.STOP"
        private const val CHANNEL = "bluetooth_location"
        private const val NOTICE = 4102
    }
    inner class LocalBinder : Binder() { fun service() = this@LocationService }
    private val binder = LocalBinder()
    private val main = Handler(Looper.getMainLooper())
    private var session: BluetoothSession? = null
    private var generation = 0
    private var wakeLock: PowerManager.WakeLock? = null
    var listener: ((Map<String, Any?>) -> Unit)? = null
    var snapshot: Map<String, Any?> = mapOf("phase" to "idle", "detail" to "请选择已配对的 iPhone", "active" to false)
        private set
    private var lastPhase = ""
    override fun onBind(intent: Intent?) = binder
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "蓝牙定位连接", NotificationManager.IMPORTANCE_LOW).apply {
                description = "连接 iPhone 期间保持蓝牙会话，可在通知中随时断开"; setShowBadge(false)
            })
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            CONNECT -> try {
                val notification = notification("正在连接 iPhone")
                if (Build.VERSION.SDK_INT >= 29) startForeground(NOTICE, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
                else startForeground(NOTICE, notification)
                begin(intent.getStringExtra("remote") ?: error("缺少 iPhone 地址"), intent.getStringExtra("local") ?: error("缺少安卓蓝牙地址"))
            } catch (error: Exception) { stop("error", "无法启动蓝牙连接：${error.message}") }
            STOP -> stop("idle", "已断开蓝牙连接")
        }
        // Do not reconnect or reapply a target after Android kills the process.
        return START_NOT_STICKY
    }
    private fun begin(remote: String, localText: String) {
        check(getSharedPreferences("bluetooth_test", MODE_PRIVATE).getString("agreementVersion", null) == MainActivity.AGREEMENT_VERSION) {
            "请先打开应用阅读并同意当前使用协议"
        }
        val local = Wire.mac(localText)
        require(android.bluetooth.BluetoothAdapter.checkBluetoothAddress(remote)) { "iPhone 蓝牙地址格式错误" }
        val adapter = getSystemService(BluetoothManager::class.java).adapter ?: error("此设备没有可用蓝牙")
        require(adapter.isEnabled) { "请先开启安卓蓝牙" }
        require(adapter.bondedDevices.any { it.address == remote }) { "请先在系统设置中与 iPhone 配对" }
        generation++; val current = generation
        session?.close(); session = null; releaseWakeLock()
        val identity = MfiIdentity(assets.open("offline-mfi/identity.pk8").use { it.readBytes() },
            assets.open("offline-mfi/certificate.p7b").use { it.readBytes() })
        wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:BluetoothSession").apply { setReferenceCounted(false); acquire() }
        update(mapOf("phase" to "connecting", "active" to true, "detail" to "正在连接 iPhone", "remote" to remote))
        session = BluetoothSession(adapter, remote, local, identity,
            emit = { state -> main.post { if (generation == current && session != null) update(state) } },
            ended = { reason -> main.post { if (generation == current) stop("error", reason) } })
        session!!.start()
    }
    internal fun apply(fix: Fix) { (session ?: error("请先连接 iPhone")).apply(fix) }
    fun disconnect() = stop("idle", "已断开蓝牙连接；停止发送不等于 iPhone 已恢复真实位置")
    private fun update(state: Map<String, Any?>) {
        snapshot = state; listener?.invoke(state)
        val phase = state["phase"] as? String ?: "idle"
        if (phase != lastPhase) {
            lastPhase = phase
            if (state["active"] == true) getSystemService(NotificationManager::class.java).notify(NOTICE,
                notification(when (phase) {
                    "streaming" -> "正在持续发送定位"
                    "pending" -> "等待发送新坐标"
                    "ready" -> "已就绪，等待输入坐标"
                    "authenticating" -> "等待 iPhone 认证"
                    "subscribing" -> "等待 iPhone 订阅定位"
                    "negotiating" -> "正在协商 iAP2"
                    else -> "正在连接 iPhone"
                }))
        }
    }
    private fun stop(phase: String, reason: String) {
        generation++; session?.close(); session = null; releaseWakeLock()
        update(snapshot + mapOf("phase" to phase, "active" to false, "connected" to false,
            "identified" to false, "authenticated" to false, "subscribed" to false, "detail" to reason))
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    private fun releaseWakeLock() { wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null }
    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, LocationService::class.java).setAction(STOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_location_notice)
            .setContentTitle("随行定位 · 蓝牙验证版").setContentText(text).setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "断开连接", stop).build()).build()
    }
    override fun onDestroy() {
        generation++; session?.close(); session = null; releaseWakeLock(); listener = null
        super.onDestroy()
    }
}
