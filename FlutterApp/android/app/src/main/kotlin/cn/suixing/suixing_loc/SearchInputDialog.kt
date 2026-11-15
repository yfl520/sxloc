package cn.suixing.suixing_loc

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.text.InputFilter
import android.text.InputType
import android.text.method.PasswordTransformationMethod
import android.view.ContextThemeWrapper
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import io.flutter.plugin.common.MethodChannel

/** Separate native editor/IME connection for devices rejecting Flutter's editor.
 * Values are returned to the unsaved Flutter form, never logged or persisted here.
 */
class SearchInputDialog(private val activity: Activity) {
    private var dialog: AlertDialog? = null

    fun edit(field: String?, value: String, result: MethodChannel.Result) {
        require(field == "key" || field == "city") { "无效的输入项" }
        check(dialog == null) { "请先完成当前输入" }
        check(!activity.isFinishing && !activity.isDestroyed) { "页面正在关闭，请重新打开" }
        val secret = field == "key"
        val context = ContextThemeWrapper(activity, android.R.style.Theme_Material_Light_Dialog_Alert)
        val padding = (20 * activity.resources.displayMetrics.density).toInt()
        val editor = EditText(context).apply {
            inputType = if (secret) InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                else InputType.TYPE_CLASS_TEXT
            setSingleLine(true)
            imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI or
                EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
            filters = arrayOf(InputFilter.LengthFilter(if (secret) 128 else 80))
            hint = if (secret) "填写高德 Web 服务 Key" else "例如：上海；留空跟随地图区域"
            setText(value)
            setSelection(text.length)
            // Do not let the Android hierarchy retain a second saved copy.
            isSaveEnabled = false
        }
        val content = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding / 2, padding, 0)
            addView(editor, LinearLayout.LayoutParams(-1, -2))
        }
        if (secret) {
            content.addView(CheckBox(context).apply {
                text = "显示 Key"
                setOnCheckedChangeListener { _, checked ->
                    val selection = editor.selectionStart.coerceAtLeast(0)
                    editor.transformationMethod = if (checked) null else PasswordTransformationMethod.getInstance()
                    editor.setSelection(selection.coerceAtMost(editor.length()))
                }
            })
        }
        var replied = false
        fun complete(value: String?) {
            if (replied) return
            replied = true
            result.success(value)
        }
        val created = AlertDialog.Builder(context)
            .setTitle(if (secret) "兼容输入 · 高德 Key" else "兼容输入 · 优先城市")
            .setView(content)
            .setNegativeButton("取消") { _, _ -> complete(null) }
            .setPositiveButton("填入") { _, _ -> complete(editor.text.toString()) }
            .create()
        val windowFocusListener = android.view.ViewTreeObserver.OnWindowFocusChangeListener { focused ->
            if (focused && editor.hasFocus() && created.isShowing) {
                (activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                    .showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT)
            }
        }
        editor.viewTreeObserver.addOnWindowFocusChangeListener(windowFocusListener)
        dialog = created
        created.setOnDismissListener {
            if (editor.viewTreeObserver.isAlive) {
                editor.viewTreeObserver.removeOnWindowFocusChangeListener(windowFocusListener)
            }
            dialog = null
            complete(null)
            editor.setText("")
        }
        editor.setOnEditorActionListener { _, action, _ ->
            if (action == EditorInfo.IME_ACTION_DONE) {
                complete(editor.text.toString())
                created.dismiss()
                true
            } else false
        }
        // The editor belongs to this focused dialog window, not the FlutterView.
        created.window?.apply {
            if (secret) addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE or
                WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        created.setOnShowListener {
            editor.requestFocus()
            editor.post {
                if (created.isShowing && editor.hasWindowFocus()) {
                    (activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                        .showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT)
                }
            }
        }
        try {
            created.show()
        } catch (error: Exception) {
            if (editor.viewTreeObserver.isAlive) {
                editor.viewTreeObserver.removeOnWindowFocusChangeListener(windowFocusListener)
            }
            dialog = null
            editor.setText("")
            throw error
        }
    }

    fun close() { dialog?.dismiss(); dialog = null }
}
