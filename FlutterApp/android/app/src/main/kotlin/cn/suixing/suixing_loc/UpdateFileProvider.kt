package cn.suixing.suixing_loc

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

/** Grants the system installer read access to one downloaded APK, never to application data. */
class UpdateFileProvider : ContentProvider() {
    override fun onCreate() = true

    private fun file(uri: Uri): File {
        val app = context ?: throw SecurityException("应用尚未准备")
        val segments = uri.pathSegments
        require(uri.authority == "${app.packageName}.updates" && segments.size == 3 &&
            segments[0] == "updates" && Regex("download-[0-9]+").matches(segments[1]) &&
            segments[2] == "sxloc-android.apk") { "更新文件地址无效" }
        val root = File(app.cacheDir, "updates").canonicalFile
        val apk = File(app.cacheDir, segments.joinToString(File.separator)).canonicalFile
        require(apk.path.startsWith(root.path + File.separator) && apk.isFile) { "更新文件不存在" }
        return apk
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        require(mode == "r") { "更新文件仅供读取" }
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String { file(uri); return "application/vnd.android.package-archive" }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val apk = file(uri)
        val columns = (projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE))
            .filter { it == OpenableColumns.DISPLAY_NAME || it == OpenableColumns.SIZE }
        return MatrixCursor(columns.toTypedArray()).apply {
            addRow(columns.map { if (it == OpenableColumns.SIZE) apk.length() else apk.name })
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
}
