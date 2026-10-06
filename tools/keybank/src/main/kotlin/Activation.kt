package ir.hamrasan.keybank

import org.bouncycastle.crypto.digests.Blake3Digest

/**
 * The inter-organizational activation code — the issuing side.
 *
 * **MIRROR of `lib/core/edition/activation_code.dart`** (which is itself the
 * mentor's original generator, kept exactly): change one without the other
 * and every code this tool issues is refused by the app. Both are pinned to
 * the same reference triples (`ActivationTest` here, `activation_code_test.dart`
 * there).
 *
 * 1. The phone shows a **device code**: BLAKE3(ANDROID_ID), first 3 bytes, hex.
 * 2. Interleave it with the app id `111111`: `d0 1 d1 1 … d5 1`.
 * 3. The **activation code** is BLAKE3 of that, first 5 bytes, lowercase hex.
 *
 * There is no secret in it — see `docs/architecture/editions.md`.
 */
object Activation {
    const val APP_ID = "111111"
    const val DEVICE_CODE_LENGTH = 6
    const val ACTIVATION_CODE_LENGTH = 10

    /** The device code a phone with [androidId] displays. */
    fun deviceCodeFor(androidId: String): String =
        blake3Hex(androidId.toByteArray(Charsets.UTF_8), DEVICE_CODE_LENGTH / 2)

    /** The activation code for a canonical (lowercase hex) [deviceCode]. */
    fun activationCodeFor(deviceCode: String): String {
        require(deviceCode.length == DEVICE_CODE_LENGTH && deviceCode.all { it in HEX }) {
            "a device code is 6 lowercase hex characters"
        }
        val combined = StringBuilder()
        for (i in 0 until DEVICE_CODE_LENGTH) combined.append(deviceCode[i]).append(APP_ID[i])
        return blake3Hex(combined.toString().toByteArray(Charsets.UTF_8), ACTIVATION_CODE_LENGTH / 2)
    }

    /**
     * [input] as a canonical device code, or null when it cannot be one.
     * Forgiving the way the app's own `ActivationCode.normalize` is: the code
     * is read aloud over the phone and typed by hand, so case, spaces, dashes,
     * bidi/ZWNJ marks and Persian or Arabic-Indic digits do not matter.
     */
    fun normalizeDeviceCode(input: String): String? {
        val out = StringBuilder()
        for (c in input) {
            when {
                c in '۰'..'۹' -> out.append('0' + (c - '۰'))
                c in '٠'..'٩' -> out.append('0' + (c - '٠'))
                isIgnorable(c) -> Unit
                else -> out.append(c)
            }
        }
        val code = out.toString().lowercase()
        return code.takeIf { it.length == DEVICE_CODE_LENGTH && it.all { c -> c in HEX } }
    }

    /** `6510c93974` → `6510c-93974`: easier to read aloud; the app ignores the dash. */
    fun display(activationCode: String): String =
        activationCode.substring(0, 5) + "-" + activationCode.substring(5)

    private const val HEX = "0123456789abcdef"

    private fun isIgnorable(c: Char): Boolean =
        c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '-' || c == '_' ||
            c == ' ' || c == '‌' || c == '‎' || c == '‏' ||
            c in '‪'..'‮' || c in '⁦'..'⁩'

    private fun blake3Hex(input: ByteArray, bytes: Int): String {
        val digest = Blake3Digest()
        digest.update(input, 0, input.size)
        // BLAKE3 is an XOF: a short output is the prefix of the long one.
        val out = ByteArray(bytes)
        digest.doFinal(out, 0, bytes)
        return out.joinToString("") { "%02x".format(it) }
    }
}
