package ir.hamrasan.panel

import java.awt.Desktop
import java.awt.FileDialog
import java.awt.Frame
import java.awt.Toolkit
import java.awt.datatransfer.StringSelection
import java.io.File
import java.util.prefs.Preferences

/** The small pieces of Windows the panel touches. */
object Platform {
    private val prefs: Preferences = Preferences.userRoot().node("ir/hamrasan/panel")

    fun copy(text: String) {
        Toolkit.getDefaultToolkit().systemClipboard.setContents(StringSelection(text), null)
    }

    /** The native «Open» dialog, filtered to the authority file. */
    fun chooseAuthorityFile(current: File?): File? {
        val dialog = FileDialog(null as Frame?, "انتخاب فایل مرجع (authority.hka)", FileDialog.LOAD)
        current?.parentFile?.takeIf { it.isDirectory }?.let { dialog.directory = it.path }
        dialog.file = "*.hka"
        dialog.isVisible = true
        val name = dialog.file ?: return null
        return File(dialog.directory, name)
    }

    /** Opens Explorer with [file] selected (or the folder itself). */
    fun reveal(file: File) {
        if (file.isFile) {
            ProcessBuilder("explorer.exe", "/select,", file.absolutePath).start()
        } else {
            open(file)
        }
    }

    fun open(file: File) {
        runCatching { Desktop.getDesktop().open(file) }
    }

    /** Where the authority file was last time — its path only, never its password. */
    var lastAuthorityFile: File?
        get() = prefs.get("authorityFile", null)?.let(::File)
        set(value) {
            if (value == null) prefs.remove("authorityFile") else prefs.put("authorityFile", value.absolutePath)
        }
}
