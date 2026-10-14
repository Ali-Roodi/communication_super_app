package com.example.communication_super_app.security

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import android.util.Log
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/**
 * «باز کردن با اثر انگشت یا چهره» — the phone's own biometric unlock, offered
 * in place of typing the app PIN.
 *
 * It is the platform [BiometricPrompt] (API 28+), not `androidx.biometric` or
 * the `local_auth` plugin: both of those need the activity to be a
 * `FragmentActivity`, and `MainActivity` is a plain `FlutterActivity` that the
 * whole call UI is built around (lock-screen flags, the incoming-call
 * full-screen intent). The framework prompt works on any activity. Below
 * Android 9 the feature is simply not offered.
 *
 * What it unlocks is the **app lock only**. The secure section is sealed under
 * the PIN itself (PBKDF2 → AES-GCM, see `VaultCrypto`), so a fingerprint cannot
 * open it and does not pretend to: it still asks for the PIN.
 *
 * ### New fingerprint, no fingerprint unlock
 *
 * Someone who knows the *phone's* PIN could otherwise add their own finger to
 * the phone and walk into the app. A Keystore key created with
 * `setInvalidatedByBiometricEnrollment(true)` is destroyed by the system the
 * moment a biometric is added (or all are removed), so its absence-after-
 * presence is a reliable "the enrolled set changed" signal. The key is never
 * used to encrypt anything — [sentinelState] only tries to initialise a cipher
 * with it. Creating such a key requires a *strong* (Class 3) biometric; on a
 * phone that only has a weak one (most face unlocks) creation fails and the
 * check is skipped, which [createSentinel] reports so the caller knows.
 */
object BiometricGate {
    private const val TAG = "BiometricGate"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val SENTINEL_ALIAS = "hamresan_biometric_sentinel_v1"

    // ── Availability ────────────────────────────────────────────────────────

    /**
     * `available`, `none_enrolled` (hardware, nothing enrolled), `no_lock` (the
     * phone has no screen lock, so it has no biometrics to offer either),
     * `unavailable` (hardware busy or temporarily off) or `unsupported`.
     */
    fun status(context: Context): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return "unsupported"
        val keyguard = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!keyguard.isDeviceSecure) return "no_lock"
        return try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> mapCanAuthenticate(
                    context.getSystemService(BiometricManager::class.java)
                        .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK),
                )
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> mapCanAuthenticate(
                    @Suppress("DEPRECATION")
                    context.getSystemService(BiometricManager::class.java).canAuthenticate(),
                )
                // Android 9 has no BiometricManager. A fingerprint reader is the
                // only biometric it exposes to apps; whether anything is enrolled
                // is learnt from the prompt itself (`none_enrolled`).
                context.packageManager.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT) ->
                    "available"
                else -> "unsupported"
            }
        } catch (e: Exception) {
            Log.w(TAG, "status failed: ${e.javaClass.simpleName}")
            "unsupported"
        }
    }

    private fun mapCanAuthenticate(code: Int): String = when (code) {
        BiometricManager.BIOMETRIC_SUCCESS -> "available"
        BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "none_enrolled"
        BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "unavailable"
        else -> "unsupported"
    }

    // ── The prompt ──────────────────────────────────────────────────────────

    /** The one prompt in flight; a second request while it is up is refused. */
    private var inFlight: CancellationSignal? = null

    /**
     * Shows the system prompt over [activity] and calls [done] exactly once
     * with `success`, `cancelled` (the user dismissed it or chose the PIN),
     * `lockout` (too many tries — the system's own temporary lockout),
     * `lockout_permanent`, `none_enrolled`, `unavailable`, `busy` or `error`.
     * Must be called on the main thread.
     */
    fun authenticate(
        activity: Activity,
        title: String,
        subtitle: String,
        negative: String,
        done: (String) -> Unit,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            done("unsupported")
            return
        }
        if (inFlight != null) {
            done("busy")
            return
        }
        var answered = false
        val signal = CancellationSignal()
        fun finish(outcome: String) {
            if (answered) return
            answered = true
            if (inFlight === signal) inFlight = null
            done(outcome)
        }
        try {
            val executor = activity.mainExecutor
            val builder = BiometricPrompt.Builder(activity)
                .setTitle(title)
                .setSubtitle(subtitle)
                .setNegativeButton(negative, executor) { _, _ -> finish("cancelled") }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // A face that is recognised opens the app without a second tap.
                builder.setConfirmationRequired(false)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // WEAK includes STRONG: whatever the phone lets apps use. Never
                // DEVICE_CREDENTIAL — the phone's own PIN is not the app's PIN,
                // and accepting it would hand the app to anyone who knows it.
                builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            }
            inFlight = signal
            builder.build().authenticate(
                signal,
                executor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        result: BiometricPrompt.AuthenticationResult?,
                    ) = finish("success")

                    override fun onAuthenticationError(code: Int, message: CharSequence?) {
                        Log.d(TAG, "prompt error $code")
                        finish(
                            when (code) {
                                BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                                BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
                                BiometricPrompt.BIOMETRIC_ERROR_TIMEOUT,
                                -> "cancelled"
                                BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT -> "lockout"
                                BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT ->
                                    "lockout_permanent"
                                BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS -> "none_enrolled"
                                BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT,
                                BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE,
                                -> "unavailable"
                                else -> "error"
                            },
                        )
                    }

                    // A finger that does not match: the prompt says so itself and
                    // stays up for another try. Nothing to report.
                    override fun onAuthenticationFailed() = Unit
                },
            )
        } catch (e: Exception) {
            Log.e(TAG, "prompt failed: ${e.javaClass.simpleName}")
            finish("error")
        }
    }

    /** Takes down a prompt still on screen (the activity is going away). */
    fun cancel() {
        try {
            inFlight?.cancel()
        } catch (_: Exception) {
        }
    }

    // ── Enrollment-change sentinel ──────────────────────────────────────────

    /**
     * (Re)creates the sentinel. True when it exists afterwards; false on a
     * phone without a strong biometric, where enrollment changes cannot be
     * detected.
     */
    fun createSentinel(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        return try {
            deleteSentinel()
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
            generator.init(
                KeyGenParameterSpec.Builder(
                    SENTINEL_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setUserAuthenticationRequired(true)
                    .setInvalidatedByBiometricEnrollment(true)
                    .build(),
            )
            generator.generateKey()
            true
        } catch (e: Exception) {
            // InvalidAlgorithmParameterException "At least one biometric must
            // be enrolled" — only a weak biometric (or none) on this phone.
            Log.i(TAG, "No enrollment sentinel: ${e.javaClass.simpleName}")
            deleteSentinel()
            false
        }
    }

    /**
     * `valid`, `invalidated` (a biometric was added, or all were removed, or the
     * screen lock was turned off since [createSentinel]) or `absent`.
     */
    fun sentinelState(): String {
        return try {
            val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
            val key = store.getKey(SENTINEL_ALIAS, null) as? SecretKey ?: return "absent"
            try {
                Cipher.getInstance("AES/GCM/NoPadding").init(Cipher.ENCRYPT_MODE, key)
                "valid"
            } catch (e: KeyPermanentlyInvalidatedException) {
                "invalidated"
            } catch (e: UserNotAuthenticatedException) {
                // Still bound to the same enrolled set; it just wants a finger
                // to be used, which this check never does.
                "valid"
            }
        } catch (e: Exception) {
            // Anything else is not the signal this looks for. Reported as valid
            // so a Keystore hiccup does not switch the user's setting off; the
            // specific exception above is the only thing that does.
            Log.w(TAG, "sentinel check failed: ${e.javaClass.simpleName}")
            "valid"
        }
    }

    fun deleteSentinel() {
        try {
            val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
            if (store.containsAlias(SENTINEL_ALIAS)) store.deleteEntry(SENTINEL_ALIAS)
        } catch (e: Exception) {
            Log.w(TAG, "sentinel delete failed: ${e.javaClass.simpleName}")
        }
    }
}
