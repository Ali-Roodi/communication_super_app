package com.example.communication_super_app.secure

import android.app.Activity
import android.content.Context
import android.os.SystemClock
import android.util.Log
import android.view.WindowManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The secure section's key vault, over `…/secure_vault`.
 *
 * Holds the one file that seals the key of `secure.db` ([VaultCrypto]) and the
 * window flag that keeps an open secure section out of screenshots.
 *
 * Methods (all errors are `PlatformException` codes the Dart side maps):
 * - `exists` → Boolean
 * - `create {pin}` → data key as hex (`ALREADY_EXISTS`)
 * - `unlock {pin}` → data key as hex
 * - `rekey {oldPin, newPin}` → true — the same data key, sealed under the new
 *   PIN; the database is never re-encrypted
 * - `destroy` → true — file and Keystore key; the data is unrecoverable after
 * - `setSecureWindow {secure}` → true
 *
 * `unlock`/`rekey` errors: `NO_VAULT`, `WRONG_PIN`, `VAULT_KEY_LOST` (the
 * Keystore key is gone — the vault can only be reset), `VAULT_CORRUPT`.
 *
 * The file lives in `noBackupFilesDir`. The data key crosses the channel as
 * hex because SQLCipher is opened from Dart; it never touches disk in clear.
 */
class SecureVaultHandler(
    context: Context,
    private val activity: () -> Activity?,
) {
    companion object {
        const val CHANNEL = "com.example.communication_super_app/secure_vault"
        private const val FILE_NAME = "secure_vault.txt"
        private const val TAG = "SecureVaultHandler"
    }

    private val file = File(context.noBackupFilesDir, FILE_NAME)
    private val wrapper = KeystoreKeyWrapper()
    private val crypto = VaultCrypto(wrapper)

    /** Main-thread scope; the work itself runs on [Dispatchers.IO]. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** One vault operation at a time: create and rekey must never interleave. */
    private val mutex = Mutex()

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "exists" -> run(call, result) { file.exists() }
                "create" -> run(call, result) { create(call.pin("pin")) }
                "unlock" -> run(call, result) { Hex.encode(open(call.pin("pin"))) }
                "rekey" -> run(call, result) { rekey(call.pin("oldPin"), call.pin("newPin")) }
                "destroy" -> run(call, result) { destroy() }
                "setSecureWindow" -> setSecureWindow(call.argument<Boolean>("secure") == true, result)
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() = scope.cancel()

    private fun MethodCall.pin(name: String): String =
        argument<String>(name)?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("missing $name")

    private fun create(pin: String): String {
        if (file.exists()) throw VaultError("ALREADY_EXISTS", "a vault already exists")
        val dataKey = crypto.newDataKey()
        writeAtomically(crypto.seal(dataKey, pin).serialize())
        return Hex.encode(dataKey)
    }

    private fun open(pin: String): ByteArray {
        if (!file.exists()) throw VaultError("NO_VAULT", "no vault")
        return crypto.open(VaultCrypto.Sealed.parse(file.readText()), pin)
    }

    private fun rekey(oldPin: String, newPin: String): Boolean {
        val dataKey = open(oldPin)
        writeAtomically(crypto.seal(dataKey, newPin).serialize())
        return true
    }

    private fun destroy(): Boolean {
        if (file.exists() && !file.delete()) {
            throw VaultError("IO", "could not delete the vault file")
        }
        wrapper.delete()
        return true
    }

    /** Write-then-rename, so a crash mid-write can never leave half a vault. */
    private fun writeAtomically(text: String) {
        val tmp = File(file.parentFile, "$FILE_NAME.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(file)) {
            tmp.delete()
            throw VaultError("IO", "could not write the vault file")
        }
    }

    private fun setSecureWindow(secure: Boolean, result: MethodChannel.Result) {
        val window = activity()?.window
        if (window == null) {
            result.success(false)
            return
        }
        if (secure) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        result.success(true)
    }

    private class VaultError(val code: String, message: String) : Exception(message)

    private fun run(call: MethodCall, result: MethodChannel.Result, block: () -> Any) {
        scope.launch {
            try {
                val started = SystemClock.elapsedRealtime()
                val value = mutex.withLock { withContext(Dispatchers.IO) { block() } }
                // How long the PIN-derived work takes on this phone — the cost
                // every unlock pays. Method name and duration only, never data.
                Log.i(TAG, "${call.method} took ${SystemClock.elapsedRealtime() - started} ms")
                result.success(value)
            } catch (e: VaultError) {
                result.error(e.code, e.message, null)
            } catch (e: VaultCrypto.WrongPinException) {
                result.error("WRONG_PIN", "wrong PIN", null)
            } catch (e: KeystoreKeyWrapper.KeyLostException) {
                Log.e(TAG, "Vault key lost: ${e.message}")
                result.error("VAULT_KEY_LOST", e.message, null)
            } catch (e: VaultCrypto.CorruptVaultException) {
                Log.e(TAG, "Vault corrupt: ${e.message}")
                result.error("VAULT_CORRUPT", e.message, null)
            } catch (e: IllegalArgumentException) {
                result.error("BAD_ARGS", e.message, null)
            } catch (e: Exception) {
                // Never log the PIN or the key — only what kind of failure.
                Log.e(TAG, "Vault operation failed: ${e.javaClass.simpleName}")
                result.error("FAILED", e.javaClass.simpleName, null)
            }
        }
    }
}
