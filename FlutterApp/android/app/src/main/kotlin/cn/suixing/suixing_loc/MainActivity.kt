package cn.suixing.suixing_loc

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import android.provider.Settings
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    companion object { const val AGREEMENT_VERSION = "2026-11-15.1" }
    private var service: LocationService? = null
    private var bound = false
    private var sink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
    private val prefs by lazy { getSharedPreferences("bluetooth_test", MODE_PRIVATE) }
    private val mapSearchSettings by lazy { MapSearchSettings(this) }
    private var searchInputDialog: SearchInputDialog? = null
    private val updates by lazy { AndroidUpdates(this) }
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = (binder as LocationService.LocalBinder).service()
            service?.listener = { sink?.success(it) }
            sink?.success(service?.snapshot)
        }
        override fun onServiceDisconnected(name: ComponentName?) { service = null }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (prefs.getString("agreementVersion", null) == AGREEMENT_VERSION) bindLocationService()
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "suixing/android/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events; service?.snapshot?.let { events.success(it) } }
            override fun onCancel(arguments: Any?) { sink = null }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "suixing/android/control").setMethodCallHandler { call, result ->
            try {
                if (call.method != "agreement.read" && call.method != "agreement.accept") {
                    check(prefs.getString("agreementVersion", null) == AGREEMENT_VERSION) { "请先阅读并同意使用协议" }
                }
                when (call.method) {
                    "update.directory" -> result.success(updates.directory())
                    "update.install" -> updates.install(call, result)
                    "agreement.read" -> result.success(prefs.getString("agreementVersion", null))
                    "agreement.accept" -> {
                        val version = call.argument<String>("version") ?: ""
                        require(version == AGREEMENT_VERSION) { "协议版本无效，请重新安装应用" }
                        check(prefs.edit().putString("agreementVersion", version)
                            .putLong("agreementAcceptedAt", System.currentTimeMillis()).commit()) { "同意记录保存失败" }
                        bindLocationService()
                        result.success(null)
                    }
                    "mapSearch.edit" -> {
                        val editor = searchInputDialog ?: SearchInputDialog(this).also { searchInputDialog = it }
                        editor.edit(call.argument<String>("field"), call.argument<String>("value") ?: "", result)
                    }
                    "mapSearch.configuration" -> result.success(mapSearchSettings.read())
                    "mapSearch.save" -> {
                        mapSearchSettings.save(call.argument<String>("provider") ?: "auto",
                            (call.argument<String>("key") ?: "").trim(),
                            (call.argument<String>("city") ?: "").trim(),
                            call.argument<Boolean>("nearby") ?: true)
                        result.success(null)
                    }
                    "configuration" -> result.success(mapOf("local" to prefs.getString("local", ""),
                        "remote" to prefs.getString("remote", ""), "lat" to prefs.getString("lat", ""),
                        "lon" to prefs.getString("lon", ""), "altitude" to prefs.getString("altitude", "0"),
                        "android" to Build.VERSION.RELEASE, "sdk" to Build.VERSION.SDK_INT))
                    "configuration.saveLocal" -> {
                        check(service?.snapshot?.get("active") != true) { "断开当前连接后可修改本机地址" }
                        val local = (call.argument<String>("local") ?: "").trim().uppercase(Locale.ROOT)
                        Wire.mac(local)
                        prefs.edit().putString("local", local).apply()
                        result.success(null)
                    }
                    "openGithub" -> {
                        val uri = Uri.parse(call.argument<String>("url") ?: "")
                        require(uri.scheme == "https" && uri.host == "github.com" && uri.userInfo == null &&
                            (uri.port == -1 || uri.port == 443) && uri.pathSegments.size == 2 && uri.query == null && uri.fragment == null) { "GitHub 地址无效" }
                        try { startActivity(Intent(Intent.ACTION_VIEW, uri)); result.success(null) }
                        catch (_: ActivityNotFoundException) { result.error("LINK", "未找到可以打开 GitHub 的应用", null) }
                    }
                    "devices" -> requestDevices(result)
                    "settings" -> { startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS)); result.success(null) }
                    "deviceInfo" -> { startActivity(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS)); result.success(null) }
                    "notifications" -> {
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 202)
                        result.success(null)
                    }
                    "connect" -> {
                        checkPermissions()
                        check(service != null) { "蓝牙服务正在准备，请稍后重试" }
                        check(service?.snapshot?.get("active") != true) { "请先断开当前连接" }
                        val remote = (call.argument<String>("remote") ?: "").uppercase(Locale.ROOT)
                        val local = (call.argument<String>("local") ?: "").uppercase(Locale.ROOT)
                        Wire.mac(local)
                        require(BluetoothAdapter.checkBluetoothAddress(remote)) { "请选择已配对的 iPhone" }
                        val adapter = getSystemService(BluetoothManager::class.java).adapter ?: error("设备不支持蓝牙")
                        require(adapter.isEnabled) { "请先开启安卓蓝牙" }
                        require(adapter.bondedDevices.any { it.address == remote }) { "请先在系统设置中配对 iPhone" }
                        prefs.edit().putString("local", local).putString("remote", remote).apply()
                        startForegroundService(Intent(this, LocationService::class.java).setAction(LocationService.CONNECT)
                            .putExtra("remote", remote).putExtra("local", local))
                        result.success(null)
                    }
                    "disconnect" -> { service?.disconnect(); result.success(null) }
                    "apply" -> {
                        val fix = Fix(call.argument<Number>("lat")?.toDouble() ?: Double.NaN,
                            call.argument<Number>("lon")?.toDouble() ?: Double.NaN,
                            call.argument<Number>("altitude")?.toDouble() ?: 0.0)
                        (service ?: error("蓝牙服务尚未就绪")).apply(fix)
                        prefs.edit().putString("lat", fix.lat.toString()).putString("lon", fix.lon.toString())
                            .putString("altitude", fix.altitude.toString()).apply()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { result.error("BLUETOOTH", error.message ?: "蓝牙操作失败", null) }
        }
    }
    private fun hasPermission() = Build.VERSION.SDK_INT < 31 || checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    private fun bindLocationService() {
        if (!bound) bound = bindService(Intent(this, LocationService::class.java), connection, BIND_AUTO_CREATE)
    }
    private fun checkPermissions() { check(hasPermission()) { "请先刷新设备，并授权附近设备权限" } }
    private fun requestDevices(result: MethodChannel.Result) {
        if (!hasPermission()) {
            check(permissionResult == null) { "请先完成系统权限授权" }
            permissionResult = result
            requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_CONNECT), 201)
        } else result.success(devices())
    }
    @SuppressLint("MissingPermission", "HardwareIds")
    private fun devices(): Map<String, Any?> {
        checkPermissions()
        val adapter = getSystemService(BluetoothManager::class.java).adapter ?: error("此设备不支持蓝牙")
        val local = runCatching { adapter.address }.getOrNull()?.takeIf { runCatching { Wire.mac(it) }.isSuccess }
        return mapOf("enabled" to adapter.isEnabled, "detectedLocal" to local,
            "devices" to if (!adapter.isEnabled) emptyList() else adapter.bondedDevices.sortedBy { it.name ?: it.address }.map {
                mapOf("name" to (it.name ?: "未命名设备"), "address" to it.address)
            })
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 201) {
            val pending = permissionResult; permissionResult = null
            try { pending?.success(devices()) } catch (error: Exception) { pending?.error("PERMISSION", "未获得附近设备权限，请在系统应用权限中允许后重试", null) }
        }
    }
    override fun onDestroy() {
        searchInputDialog?.close(); searchInputDialog = null
        updates.close()
        permissionResult?.error("CANCELLED", "界面已关闭，请重新操作", null); permissionResult = null
        service?.listener = null
        if (bound) unbindService(connection)
        service = null; bound = false; sink = null
        super.onDestroy()
    }
}
