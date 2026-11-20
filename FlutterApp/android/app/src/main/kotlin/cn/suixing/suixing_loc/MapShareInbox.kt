package cn.suixing.suixing_loc

/** One pending text share, held locally until the consent-gated Flutter UI reads it. */
class MapShareInbox {
    private var pending: Map<String, String>? = null

    fun receive(action: String?, mime: String?, text: CharSequence?): Boolean {
        if (action != "android.intent.action.SEND" ||
            mime?.substringBefore(';')?.lowercase() !in setOf("text/plain", "text/uri-list")) return false
        pending = when {
            text == null || text.isBlank() -> mapOf("error" to "未收到地点链接")
            text.length > 8192 -> mapOf("error" to "分享内容过长")
            else -> mapOf("text" to text.toString().trim())
        }
        return true
    }

    fun restore(text: String?, error: String?) {
        pending = when {
            text != null && text.length <= 8192 -> mapOf("text" to text)
            error != null -> mapOf("error" to error.take(200))
            else -> null
        }
    }

    fun peek(): Map<String, String>? = pending
    fun take(): Map<String, String>? = pending.also { pending = null }
}
