package cn.suixing.suixing_loc

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The user's Web service Key is local and encrypted with an Android Keystore key. */
internal class MapSearchSettings(context: Context) {
    private val prefs = context.getSharedPreferences("map_search", Context.MODE_PRIVATE)
    private val alias = "suixing.map_search.v1"

    private fun secret(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    fun read(): Map<String, Any> {
        val stored = prefs.getString("encrypted_key", "") ?: ""
        val key = if (stored.isEmpty()) "" else try {
            val parts = stored.split('.')
            require(parts.size == 2)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secret(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
            String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8)
        } catch (_: Exception) { error("无法读取搜索 Key，请在搜索设置中重新填写并保存") }
        return mapOf("provider" to (prefs.getString("provider", "auto") ?: "auto"),
            "key" to key, "city" to (prefs.getString("city", "") ?: ""),
            "nearby" to prefs.getBoolean("nearby", true))
    }

    fun save(provider: String, key: String, city: String, nearby: Boolean) {
        require(provider in setOf("auto", "amap", "photon")) { "搜索服务无效" }
        require(key.isEmpty() || key.matches(Regex("[A-Za-z0-9]{16,128}"))) { "Key 格式无效，请填写 Web 服务 Key" }
        require(city.length <= 80) { "城市名称过长" }
        require(provider != "amap" || key.isNotEmpty()) { "选择高德搜索时需填写 Web 服务 Key" }
        val encrypted = if (key.isEmpty()) "" else try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secret())
            val body = cipher.doFinal(key.toByteArray(Charsets.UTF_8))
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + "." + Base64.encodeToString(body, Base64.NO_WRAP)
        } catch (_: Exception) { error("无法加密保存搜索 Key，请稍后重试") }
        check(prefs.edit().putString("provider", provider).putString("encrypted_key", encrypted)
            .putString("city", city).putBoolean("nearby", nearby).commit()) { "保存搜索设置失败，请重试" }
    }
}
