package com.example.communication_super_app.secure

import android.app.Activity
import android.content.Context
import android.os.SystemClock
import android.util.Log
import android.view.WindowManager
import com.example.communication_super_app.security.BiometricGate
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
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
 *   PIN; the database is never re-encrypted (the biometric copy stays valid)
 * - `destroy` → true — file, biometric copy and Keystore keys; the data is
 *   unrecoverable after
 * - `setSecureWindow {secure}` → true
 * - `bioStatus` → [BiometricGate.strongStatus]; `bioEnabled` → Boolean
 * - `bioEnable {pin, title, subtitle, negative}` → true: the PIN opens the
 *   vault, a strong biometric authorises a new key, the data key is sealed
 *   under it ([SecureBiometric])
 * - `bioUnlock {title, subtitle, negative}` → data key as hex
 * - `bioDisable` → true
 *
 * The PIN here is the **section PIN** — its own, never the app PIN.
 *
 * Biometric errors are `BIO_<outcome>` (`BIO_CANCELLED`, `BIO_LOCKOUT`,
 * `BIO_LOCKOUT_PERMANENT`, `BIO_NONE_ENROLLED`, `BIO_UNAVAILABLE`,
 * `BIO_BUSY`, `BIO_ERROR`), `BIO_OFF` (no copy) and `BIO_INVALIDATED`
 * (a biometric was enrolled since — the copy has been deleted).
 *
 * `unlock`/`rekey` errors: `NO_VAULT`, `WRONG_PIN`, `VAULT_KEY_LOST` (the
 * Keystore key is gone — the vault can only be reset), `VAULT_CORRUPT`.
 *
 * The file lives in `noBackupFilesDir`. The data key crosses the channel as
 * hex because SQLCipher is opened from Dart; it never touches disk in clear.
 */
class SecureVaultHandler(
    private val context: Context,
    private val activity: () -> Activity?,
) {
    companion object {
        const val CHANNEL = "com.example.communication_super_app/secure_vault"
        private const val FILE_NAME = "secure_vault.txt"
        private const val BIO_FILE_NAME = "secure_vault_bio.txt"
        private const val TAG = "SecureVaultHandler"

        /**
         * The secure section is open in this process: Dart sets FLAG_SECURE
         * before any secure content reaches the screen and clears it on every
         * lock, so the flag is the section's state. Process memory only — a
         * new process is locked.
         */
        @JvmStatic
        @Volatile
        var sectionOpen = false
            private set
    }

    private val file = File(context.noBackupFilesDir, FILE_NAME)
    private val bioFile = File(context.noBackupFilesDir, BIO_FILE_NAME)
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
                "bioStatus" -> result.success(BiometricGate.strongStatus(context))
                "bioEnabled" -> run(call, result) { file.exists() && bioFile.exists() }
                "bioEnable" -> bioEnable(call, result)
                "bioUnlock" -> bioUnlock(call, result)
                "bioDisable" -> run(call, result) {
                    disableBio()
                    true
                }
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
        // A copy from a section that no longer exists must not survive into the
        // new one.
        disableBio()
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
        disableBio()
        if (file.exists() && !file.delete()) {
            throw VaultError("IO", "could not delete the vault file")
        }
        wrapper.delete()
        return true
    }

    private fun disableBio() {
        if (bioFile.exists()) bioFile.delete()
        SecureBiometric.delete()
    }

    /** Write-then-rename, so a crash mid-write can never leave half a vault. */
    private fun writeAtomically(text: String, target: File = file) {
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw VaultError("IO", "could not write the vault file")
        }
    }

    // ── Biometric copy ──────────────────────────────────────────────────────

    /** A prompt outcome other than success, as `BIO_<OUTCOME>`. */
    private class BioError(outcome: String) : Exception(outcome) {
        val code = "BIO_" + outcome.uppercase()
    }

    private fun MethodCall.text(name: String): String = argument<String>(name) ?: ""

    /**
     * The strong-biometric prompt over the activity, bound to [cipher];
     * resumes with the authorised cipher or throws [BioError].
     */
    private suspend fun prompt(call: MethodCall, cipher: Cipher): Cipher =
        suspendCancellableCoroutine { cont ->
            val host = activity()
            if (host == null || host.isFinishing || host.isDestroyed) {
                cont.resumeWithException(BioError("unavailable"))
                return@suspendCancellableCoroutine
            }
            BiometricGate.authenticateWithCipher(
                host,
                cipher,
                title = call.text("title"),
                subtitle = call.text("subtitle"),
                negative = call.text("negative"),
            ) { outcome, unlocked ->
                if (!cont.isActive) return@authenticateWithCipher
                if (outcome == "success" && unlocked != null) {
                    cont.resume(unlocked)
                } else {
                    cont.resumeWithException(BioError(outcome))
                }
            }
        }

    /**
     * Turns the biometric copy on: the section PIN proves the user may, the
     * prompt proves the finger is one the phone knows — it is never switched
     * on for a biometric that has not just worked. Any failure after the PIN
     * leaves it off, never half on.
     */
    private fun bioEnable(call: MethodCall, result: MethodChannel.Result) {
        val pin = try {
            call.pin("pin")
        } catch (e: IllegalArgumentException) {
            result.error("BAD_ARGS", e.message, null)
            return
        }
        scope.launch {
            var dataKey: ByteArray? = null
            try {
                val key = mutex.withLock { withContext(Dispatchers.IO) { open(pin) } }
                dataKey = key
                try {
                    val cipher = withContext(Dispatchers.IO) { SecureBiometric.newEncryptCipher() }
                    val unlocked = prompt(call, cipher)
                    mutex.withLock {
                        withContext(Dispatchers.IO) {
                            val seal = BioSeal(unlocked.iv, unlocked.doFinal(key))
                            writeAtomically(seal.serialize(), bioFile)
                        }
                    }
                } catch (e: Exception) {
                    withContext(Dispatchers.IO) { disableBio() }
                    throw e
                }
                result.success(true)
            } catch (e: Exception) {
                fail(call, result, e)
            } finally {
                dataKey?.fill(0)
            }
        }
    }

    /** Opens the vault with a finger instead of the PIN: the data key, as hex. */
    private fun bioUnlock(call: MethodCall, result: MethodChannel.Result) {
        scope.launch {
            try {
                val seal = mutex.withLock {
                    withContext(Dispatchers.IO) {
                        if (!file.exists()) throw VaultError("NO_VAULT", "no vault")
                        if (!bioFile.exists()) throw BioError("off")
                        BioSeal.parse(bioFile.readText()) ?: run {
                            disableBio()
                            throw BioError("invalidated")
                        }
                    }
                }
                val cipher = try {
                    withContext(Dispatchers.IO) { SecureBiometric.decryptCipher(seal) }
                } catch (e: SecureBiometric.InvalidatedException) {
                    // A finger was enrolled (or the phone lock removed) since the
                    // copy was made: the system destroyed its key. Gone for good.
                    withContext(Dispatchers.IO) { disableBio() }
                    throw BioError("invalidated")
                }
                val unlocked = prompt(call, cipher)
                val key = try {
                    withContext(Dispatchers.IO) { unlocked.doFinal(seal.sealed) }
                } catch (e: AEADBadTagException) {
                    withContext(Dispatchers.IO) { disableBio() }
                    throw BioError("invalidated")
                }
                result.success(Hex.encode(key))
                key.fill(0)
            } catch (e: Exception) {
                fail(call, result, e)
            }
        }
    }

    private fun setSecureWindow(secure: Boolean, result: MethodChannel.Result) {
        sectionOpen = secure
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
            } catch (e: Exception) {
                fail(call, result, e)
            }
        }
    }

    private fun fail(call: MethodCall, result: MethodChannel.Result, e: Exception) {
        when (e) {
            is BioError -> result.error(e.code, e.message, null)
            is VaultError -> result.error(e.code, e.message, null)
            is VaultCrypto.WrongPinException -> result.error("WRONG_PIN", "wrong PIN", null)
            is KeystoreKeyWrapper.KeyLostException -> {
                Log.e(TAG, "Vault key lost: ${e.message}")
                result.error("VAULT_KEY_LOST", e.message, null)
            }
            is VaultCrypto.CorruptVaultException -> {
                Log.e(TAG, "Vault corrupt: ${e.message}")
                result.error("VAULT_CORRUPT", e.message, null)
            }
            is IllegalArgumentException -> result.error("BAD_ARGS", e.message, null)
            else -> {
                // Never log the PIN or the key — only what kind of failure.
                Log.e(TAG, "Vault ${call.method} failed: ${e.javaClass.simpleName}")
                result.error("FAILED", e.javaClass.simpleName, null)
            }
        }
    }
}
