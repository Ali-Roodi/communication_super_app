package com.example.communication_super_app.smscrypto.keybank

import com.example.communication_super_app.smscrypto.IdentityKeyPair
import com.example.communication_super_app.smscrypto.Kdf
import com.example.communication_super_app.smscrypto.SmsCryptoException
import com.example.communication_super_app.smscrypto.cryptoError

/**
 * «گروه با عبارت عبور»: a key bank made of nothing but a group name and a
 * shared passphrase — for members with no authority behind them, e.g. two
 * organizations talking to each other.
 *
 * `seed = Argon2id(passphrase, "hamresan.group.v1" ‖ 0 ‖ name)`, and every
 * member's identity is `IdentityKeyPair.fromSeed(HKDF(seed, phone number))`.
 * So each phone can compute **any** member's public key from the number
 * alone: no key is exchanged, a member only tells the app which numbers are
 * their own.
 *
 * The price, which the UI must say: whoever knows the passphrase can derive
 * every member's *private* key too — read the group's messages and write as
 * any member. The group is exactly as strong as its passphrase. (What the
 * protocol still gives: ML-KEM sessions and a fresh key per message; a
 * recorded message is not readable by someone who learns only one session.)
 */
class KeyGroup private constructor(private val seed: ByteArray) {
    companion object {
        private const val FORMAT: Byte = 1
        private const val SEED_BYTES = 32
        const val SERIALIZED_BYTES = 1 + SEED_BYTES
        const val GROUP_ID_BYTES = 8

        private val SALT_LABEL = Kdf.label("hamresan.group.v1")
        private val MEMBER_SALT = Kdf.label("hamresan.group.member.v1")
        private val ID_LABEL = Kdf.label("hamresan.group.id.v1")

        /** Runs Argon2id — about a second on a phone. Off the main thread. */
        fun derive(name: String, passphrase: String): KeyGroup = derive(name, passphrase, PasswordKdf.GROUP)

        /** [kdf] other than [PasswordKdf.GROUP] is for tests only: it is a different group. */
        internal fun derive(name: String, passphrase: String, kdf: PasswordKdf): KeyGroup {
            val canonicalName = Canon.text(name)
            val canonicalPassphrase = Canon.text(passphrase)
            if (canonicalName.isEmpty() || canonicalPassphrase.isEmpty()) {
                cryptoError(SmsCryptoException.Code.BAD_KEY, "empty group name or passphrase")
            }
            val salt = SALT_LABEL + byteArrayOf(0) + canonicalName.toByteArray(Charsets.UTF_8)
            return KeyGroup(kdf.derive(canonicalPassphrase.toByteArray(Charsets.UTF_8), salt, SEED_BYTES))
        }

        fun parse(bytes: ByteArray): KeyGroup {
            if (bytes.size != SERIALIZED_BYTES || bytes[0] != FORMAT) {
                cryptoError(SmsCryptoException.Code.BAD_KEY, "not a key group")
            }
            return KeyGroup(bytes.copyOfRange(1, SERIALIZED_BYTES))
        }
    }

    /**
     * 8 bytes that name the group without revealing it. Members compare it
     * (shown as «کد گروه») to know they typed the same name and passphrase.
     */
    val groupId: ByteArray by lazy { Kdf.sha256(ID_LABEL, seed).copyOf(GROUP_ID_BYTES) }

    /** The identity of the member who owns [phone] (any spelling; see [Canon.phone]). */
    fun member(phone: String): IdentityKeyPair {
        val number = Canon.phone(phone)
            ?: cryptoError(SmsCryptoException.Code.BAD_KEY, "not a phone number")
        return IdentityKeyPair.fromSeed(
            Kdf.hkdf(seed, MEMBER_SALT, Kdf.label(number), IdentityKeyPair.SEED_BYTES),
        )
    }

    fun serialize(): ByteArray = byteArrayOf(FORMAT) + seed
}
