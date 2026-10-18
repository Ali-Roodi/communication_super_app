package com.example.communication_super_app.smscrypto

import java.security.SecureRandom
import org.bouncycastle.crypto.kems.MLKEMExtractor
import org.bouncycastle.crypto.kems.MLKEMGenerator
import org.bouncycastle.crypto.params.MLKEMParameters
import org.bouncycastle.crypto.params.MLKEMPublicKeyParameters

/**
 * Makes a [CertHandshake] session post-quantum, in the background, once the
 * conversation is already running — the owner's trade (1405/07/25): the
 * first message goes after two SMS parts each way, and the ~20 parts of
 * ML-KEM follow behind it instead of in front.
 *
 * ```
 * A → B  (on the session)  PQ_OFFER   ek_A                       ~11 parts
 * B → A  (on the session)  PQ_ACCEPT  sid', ct = Encaps(ek_A)    ~10 parts
 * ```
 *
 * Both then hold a **new session** `sid'`, keyed by
 * `HKDF(root ‖ ss, salt = hash(ek, ct, sid'))`: secret as long as *either*
 * the classical handshake (whose [Session.root] goes in) or ML-KEM holds.
 * A new session rather than re-keyed chains, so a message sealed on the old
 * one before the switch, and delivered after it, still opens.
 *
 * Both packets travel inside the session they upgrade, so they are
 * encrypted and authenticated by it: nobody can substitute the key or the
 * ciphertext. `ek` is the offerer's long-term ML-KEM key (from its key file)
 * — so there is no post-quantum forward secrecy against a later theft of
 * that key; the classical ephemeral term is still in `root`.
 */
object Upgrade {
    private val SALT_LABEL = Kdf.label("hamresan.sms.pq-upgrade.salt.v1")
    private val SESSION_INFO = Kdf.label("hamresan.sms.pq-upgrade.v1")
    private const val KEY_BYTES = 32
    private const val SID_SPACE = 1 shl (8 * Wire.SID_BYTES)

    /** [session] carries our offer; the state that sealed it is returned. */
    fun offer(session: Session, own: IdentityKeyPair): Session.Sealed =
        session.seal(Payload.pqOffer(own.public.mlkem.encoded), control = true)

    /**
     * The upgraded session, and the old one's next state with the answer
     * sealed on it. [encapsulationKey] is what the offer carried.
     */
    class Accepted(val answer: Session.Sealed, val upgraded: Session)

    fun accept(
        session: Session,
        encapsulationKey: ByteArray,
        random: SecureRandom,
        busySids: Set<Int> = emptySet(),
    ): Accepted {
        val root = session.root
        val ek = try {
            MLKEMPublicKeyParameters(MLKEMParameters.ml_kem_768, encapsulationKey)
        } catch (e: IllegalArgumentException) {
            cryptoError(SmsCryptoException.Code.BAD_KEY, "invalid ML-KEM key")
        }
        require(busySids.size < SID_SPACE) { "no free session id" }
        var sid: Int
        do {
            sid = random.nextInt(SID_SPACE)
        } while (sid in busySids || sid == session.sid)
        val kem = MLKEMGenerator(random).generateEncapsulated(ek)
        val keys = derive(root, kem.secret, encapsulationKey, kem.encapsulation, sid)
        return Accepted(
            session.seal(Payload.pqAccept(sid, kem.encapsulation), control = true),
            Session.start(
                sid, session.ownKid, session.peerKid,
                sendChain = keys.accepterToOfferer,
                receiveChain = keys.offererToAccepter,
                root = keys.root,
            ),
        )
    }

    /** The offerer's side: the upgraded session from the answer. */
    fun complete(session: Session, own: IdentityKeyPair, sid: Int, ciphertext: ByteArray): Session {
        val root = session.root
        if (ciphertext.size != Wire.KEM_CIPHERTEXT_BYTES) {
            cryptoError(SmsCryptoException.Code.BAD_PAYLOAD, "not an ML-KEM ciphertext")
        }
        val secret = MLKEMExtractor(own.mlkem).extractSecret(ciphertext)
        val keys = derive(root, secret, own.public.mlkem.encoded, ciphertext, sid)
        return Session.start(
            sid, session.ownKid, session.peerKid,
            sendChain = keys.offererToAccepter,
            receiveChain = keys.accepterToOfferer,
            root = keys.root,
        )
    }

    private class Keys(
        val offererToAccepter: ByteArray,
        val accepterToOfferer: ByteArray,
        val root: ByteArray,
    )

    private fun derive(root: ByteArray, secret: ByteArray, ek: ByteArray, ct: ByteArray, sid: Int): Keys {
        val salt = Kdf.sha256(SALT_LABEL, ek, ct, Wire.writeSid(sid))
        val okm = Kdf.hkdf(root + secret, salt, SESSION_INFO, 3 * KEY_BYTES)
        return Keys(
            okm.copyOfRange(0, KEY_BYTES),
            okm.copyOfRange(KEY_BYTES, 2 * KEY_BYTES),
            okm.copyOfRange(2 * KEY_BYTES, 3 * KEY_BYTES),
        )
    }
}
