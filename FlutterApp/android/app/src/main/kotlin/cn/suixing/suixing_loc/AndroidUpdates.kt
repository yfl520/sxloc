package cn.suixing.suixing_loc

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class AndroidUpdates(private val activity: Activity) {
    private val worker = Executors.newSingleThreadExecutor()

    fun directory(): String {
        val root = File(activity.cacheDir, "updates")
        check(root.isDirectory || root.mkdirs()) { "无法创建更新目录，请检查存储空间" }
        return root.canonicalPath
    }

    fun install(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path") ?: ""
        val hash = call.argument<String>("sha256") ?: ""
        val version = call.argument<String>("version") ?: ""
        val build = call.argument<Number>("buildNumber")?.toLong() ?: 0L
        worker.execute {
            try {
                val file = File(path).canonicalFile
                val root = File(directory()).canonicalFile
                require(file.path.startsWith(root.path + File.separator) && file.name == "sxloc-android.apk" &&
                    file.isFile && file.length() in 1..(512L * 1024 * 1024)) { "更新文件无效，请重新下载" }
                require(Regex("[a-f0-9]{64}").matches(hash)) { "更新校验信息无效" }
                val digest = MessageDigest.getInstance("SHA-256")
                file.inputStream().buffered().use { input ->
                    val buffer = ByteArray(128 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        digest.update(buffer, 0, count)
                    }
                }
                require(hex(digest.digest()) == hash) { "更新文件校验失败，请重新下载" }
                val manager = activity.packageManager
                @Suppress("DEPRECATION")
                val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                @Suppress("DEPRECATION")
                val archive = manager.getPackageArchiveInfo(file.path, flags) ?: error("无法读取 APK 安装信息")
                @Suppress("DEPRECATION")
                val installed = manager.getPackageInfo(activity.packageName, flags)
                require(archive.packageName == activity.packageName) { "此安装包不属于随行定位" }
                require(code(archive) == build && code(archive) > code(installed) && archive.versionName == version) {
                    "安装包版本不匹配，或当前已安装更新版本，请重新检查"
                }
                require((archive.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE) <= Build.VERSION.SDK_INT) {
                    "此更新不支持当前 Android 系统"
                }
                val oldSigners = signers(installed)
                require(oldSigners.isNotEmpty() && oldSigners == signers(archive)) {
                    "安装包签名与当前应用不一致，无法覆盖更新"
                }
                activity.runOnUiThread {
                    try {
                        check(!activity.isFinishing && !activity.isDestroyed) { "应用已关闭，请重新打开后安装" }
                        if (!manager.canRequestPackageInstalls()) {
                            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${activity.packageName}")))
                            result.success("permission")
                        } else {
                            val relative = file.relativeTo(activity.cacheDir.canonicalFile).invariantSeparatorsPath
                            val uri = Uri.Builder().scheme("content").authority("${activity.packageName}.updates")
                                .path(relative).build()
                            activity.startActivity(Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                            result.success("installer")
                        }
                    } catch (error: Exception) { result.error("UPDATE", error.message ?: "无法打开系统安装界面", null) }
                }
            } catch (error: Exception) {
                activity.runOnUiThread { result.error("UPDATE", error.message ?: "更新校验失败", null) }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures?.map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }?.toSet() ?: emptySet()
    }

    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    fun close() { worker.shutdown() }
}
