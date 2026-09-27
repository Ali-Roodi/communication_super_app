package com.example.communication_super_app.smscrypto

/**
 * Every way the SMS crypto refuses. [code] is the `PlatformException` code
 * the Dart side sees (`SmsCryptoHandler`), so the names are part of the
 * channel contract.
 *
 * None of these carries key material or message text in its message.
 */
class SmsCryptoException(val code: Code, message: String) : Exception(message) {
    enum class Code {
        /** Not a `#E:` packet this build can read (or not one at all). */
        NOT_OURS,

        /** A packet of a different kind than the operation expects. */
        WRONG_TYPE,

        /** A key, identity or state blob that does not parse. */
        BAD_KEY,

        /** The packet names a sender identity other than the peer given. */
        WRONG_PEER,

        /** The packet was made for an identity other than ours. */
        NOT_FOR_US,

        /** A message for a session other than the one given. */
        WRONG_SESSION,

        /**
         * A message counter this session has already consumed — the carrier
         * delivered the same SMS twice, or somebody replays it.
         */
        DUPLICATE,

        /** A counter too far past the last one to be a delayed message. */
        TOO_FAR_AHEAD,

        /**
         * The authentication tag did not verify: tampered, truncated, or made
         * under another key. The session is left exactly as it was.
         */
        AUTH_FAILED,

        /** Decrypted, but the content inside is not a payload we know. */
        BAD_PAYLOAD,

        /** The send counter is exhausted; a new session is needed. */
        REKEY_REQUIRED,

        // ── Key bank (keybank/) ──────────────────────────────────────────

        /** Not a key file of ours (wrong magic, unknown format). */
        NOT_A_KEY_FILE,

        /** The password does not open the key file. */
        WRONG_PASSWORD,

        /** Signed by an authority this build does not trust. */
        UNTRUSTED,

        /** The authority's signature does not verify: altered or forged. */
        BAD_SIGNATURE,

        /** Opened and signed, but its contents contradict themselves. */
        BAD_BUNDLE,
    }
}

internal fun cryptoError(code: SmsCryptoException.Code, message: String): Nothing =
    throw SmsCryptoException(code, message)
