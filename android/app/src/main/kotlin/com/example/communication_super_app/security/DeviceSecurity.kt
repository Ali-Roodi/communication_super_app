package com.example.communication_super_app.security

import android.app.KeyguardManager
import android.app.admin.DevicePolicyManager
import android.app.role.RoleManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.provider.Telephony
import com.example.communication_super_app.secure.KeystoreKeyWrapper
import java.io.File
import java.security.MessageDigest

/**
 * «کنترل امنیت سامانه» (matrix row 29): the facts about this phone that
 * decide how far the secure section can be trusted on it. Kotlin only
 * reports; Dart words them and weighs them (`DeviceSecurityReport`).
 *
 * Nothing here needs a permission, and nothing leaves the phone.
 */
object DeviceSecurity {
    /**
     * SHA-256 of the release signing certificate (`upload-keystore.jks`).
     * A different signer means the APK was rebuilt by someone else.
     */
    private const val RELEASE_CERT_SHA256 =
        "58bc0e5f2fc3b5be6f5e5baff0c5b02fe7bd9a8ecad06f86b4e0e174b3c3970a"

    private val SU_PATHS = listOf(
        "/system/bin/su", "/system/xbin/su", "/sbin/su", "/su/bin/su",
        "/system/sbin/su", "/vendor/bin/su", "/data/local/su", "/data/local/bin/su",
        "/data/local/xbin/su", "/system/sd/xbin/su", "/system/bin/failsafe/su",
        "/system/app/Superuser.apk", "/system/app/SuperSU.apk", "/data/adb/magisk",
        "/data/adb/ksu", "/data/adb/ap",
    )

    private val HOOK_MARKERS = listOf("frida", "xposed", "lsposed", "substrate", "zygisk", "riru")

    fun report(context: Context): Map<String, Any?> {
        val app = context.applicationContext
        return mapOf(
            "rootReasons" to rootReasons(),
            "hooks" to hookMarkers(),
            "emulator" to isEmulator(),
            "adb" to (globalInt(app, Settings.Global.ADB_ENABLED) == 1),
            "developerOptions" to (globalInt(app, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED) == 1),
            "screenLock" to screenLock(app),
            "securityPatch" to Build.VERSION.SECURITY_PATCH,
            "sdk" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
            "debuggable" to ((app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0),
            "debugger" to android.os.Debug.isDebuggerConnected(),
            "signature" to signatureState(app),
            "installer" to installer(app),
            "accessibility" to accessibilityServices(app),
            "encrypted" to storageEncrypted(app),
            "keystore" to KeystoreKeyWrapper().securityLevel(),
            "defaultSms" to (Telephony.Sms.getDefaultSmsPackage(app) == app.packageName),
            "defaultDialer" to isDefaultDialer(app),
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
        )
    }

    private fun globalInt(context: Context, name: String): Int = try {
        Settings.Global.getInt(context.contentResolver, name, 0)
    } catch (e: Exception) {
        0
    }

    private fun rootReasons(): List<String> {
        val out = mutableListOf<String>()
        SU_PATHS.firstOrNull { runCatching { File(it).exists() }.getOrDefault(false) }
            ?.let { out.add("su:$it") }
        if (Build.TAGS?.contains("test-keys") == true) out.add("test-keys")
        if (prop("ro.debuggable") == "1") out.add("ro.debuggable")
        if (prop("ro.secure") == "0") out.add("ro.secure")
        val path = System.getenv("PATH") ?: ""
        if (path.split(':').any { runCatching { File(it, "su").exists() }.getOrDefault(false) }) {
            if (out.none { it.startsWith("su:") }) out.add("su:PATH")
        }
        return out
    }

    private fun prop(name: String): String? = try {
        val cls = Class.forName("android.os.SystemProperties")
        cls.getMethod("get", String::class.java).invoke(null, name) as? String
    } catch (e: Exception) {
        null
    }

    /** Instrumentation frameworks loaded into this very process. */
    private fun hookMarkers(): List<String> = try {
        val maps = File("/proc/self/maps").readText().lowercase()
        HOOK_MARKERS.filter { maps.contains(it) }
    } catch (e: Exception) {
        emptyList()
    }

    private fun isEmulator(): Boolean {
        val f = Build.FINGERPRINT ?: ""
        return f.startsWith("generic") || f.contains("emulator") || f.contains("sdk_gphone") ||
            Build.HARDWARE == "goldfish" || Build.HARDWARE == "ranchu" ||
            Build.PRODUCT?.contains("sdk") == true && Build.MODEL?.contains("Emulator") == true
    }

    private fun screenLock(context: Context): Boolean = try {
        val km = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        km.isDeviceSecure
    } catch (e: Exception) {
        false
    }

    /** `release`, `other` (a different signer) or `unknown`. */
    private fun signatureState(context: Context): String = try {
        val pm = context.packageManager
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val info = pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            info.signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNATURES).signatures
        }
        val digests = signatures?.map { sig ->
            MessageDigest.getInstance("SHA-256").digest(sig.toByteArray())
                .joinToString("") { "%02x".format(it) }
        }.orEmpty()
        when {
            digests.isEmpty() -> "unknown"
            digests.contains(RELEASE_CERT_SHA256) -> "release"
            else -> "other"
        }
    } catch (e: Exception) {
        "unknown"
    }

    private fun installer(context: Context): String? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getInstallerPackageName(context.packageName)
        }
    } catch (e: Exception) {
        null
    }

    /** Apps allowed to read the screen — FLAG_SECURE does not stop them. */
    private fun accessibilityServices(context: Context): List<String> {
        val enabled = try {
            Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            )
        } catch (e: Exception) {
            null
        } ?: return emptyList()
        val pm = context.packageManager
        return enabled.split(':')
            .mapNotNull { it.substringBefore('/').takeIf { p -> p.isNotBlank() } }
            .filter { it != context.packageName }
            .distinct()
            .map { pkg ->
                try {
                    pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
                } catch (e: Exception) {
                    pkg
                }
            }
    }

    private fun storageEncrypted(context: Context): Boolean? = try {
        val dpm = context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
        when (dpm.storageEncryptionStatus) {
            DevicePolicyManager.ENCRYPTION_STATUS_ACTIVE,
            DevicePolicyManager.ENCRYPTION_STATUS_ACTIVE_PER_USER,
            DevicePolicyManager.ENCRYPTION_STATUS_ACTIVE_DEFAULT_KEY -> true
            DevicePolicyManager.ENCRYPTION_STATUS_INACTIVE -> false
            else -> null
        }
    } catch (e: Exception) {
        null
    }

    private fun isDefaultDialer(context: Context): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            context.getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_DIALER)
        } else {
            val tm = context.getSystemService(Context.TELECOM_SERVICE) as android.telecom.TelecomManager
            tm.defaultDialerPackage == context.packageName
        }
    } catch (e: Exception) {
        false
    }
}
