package com.example.communication_super_app.smscrypto

import android.os.SystemClock
import com.example.communication_super_app.smscrypto.keybank.AuthorityPublic
import com.example.communication_super_app.smscrypto.keybank.Canon
import com.example.communication_super_app.smscrypto.keybank.KeyFile
import com.example.communication_super_app.smscrypto.keybank.MemberCert
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.SecureRandom
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The SMS crypto over `…/sms_crypto`. **Stateless**: every key, pending
 * handshake and session comes in as bytes and the next state goes back out;
 * the Dart side keeps them in the secure section (`secure.db`). Nothing here
 * touches a file, a database or the network.
 *
 * Methods (byte arguments and results are `Uint8List`):
 * - `generateIdentity` → `{secret, public, keyId}` — the secure section's
 *   own sealing key (`SealedBox`)
 * - `publicIdentity {secret}` → `{public, keyId}`
 * - `inspect {text}` → `null` for anything that is not one of our packets,
 *   else `{type: message|init|response, sid, counter?, control?, senderKid?,
 *   certPhone?, certGeneration?}` — for a handshake packet, what its (not yet
 *   verified) certificate says: key id, number and generation
 * - `ownInitWins {ownKid, peerKid}` → Boolean — crossed INITs
 * - `certInitiate {cert, busySids}` → `{pending, sid, wire, parts}` — the
 *   session request (`CertHandshake`)
 * - `certRespond {secret, cert, text, anchors}` → `{session, sid, wire, parts, peer}`
 * - `certComplete {secret, cert, pending, text, anchors}` → `{session, sid, peer}`
 * - `certInfo {cert}` → `{cert, keyId, phone, generation}` (what `peer` is) —
 *   structure only, no signature check
 * - `upgradeOffer {session, secret}` → like `encryptText` (`Upgrade`)
 * - `upgradeAccept {session, key, busySids}` → `{answer: {…encryptText}, upgraded, upgradedSid}`
 * - `upgradeComplete {session, secret, sid, ciphertext}` → `{session, sid}`
 * - `encryptText {session, text, deleteAfterSeen?}` → `{session, wire, parts, sid, counter}`
 * - `encryptText` also takes `groupId` (8 bytes): a group message, and
 *   `ttlSeconds`: a timed message (row 16)
 * - `encryptControl {session, control: seen|delete, refSid, refCounter}` → same
 * - `encryptGroupInfo {session, info: {groupId, version, mode, name,
 *   members: [{phone, keyId}]}}` → same (a control packet)
 * - `decrypt {session, text}` → `{session, sid, counter, kind:
 *   text|seen|delete|groupInfo|pqOffer|pqAccept, text?, deleteAfterSeen?,
 *   groupId?, refSid?, refCounter?, version?, mode?, name?, members?, pqKey?,
 *   pqSid?, pqCiphertext?}` — `sid`/`counter` name
 *   the message itself (what a later seen/delete refers to)
 *
 * Sealed records (`SealedBox` — what Kotlin writes for the hidden phonebook):
 * - `coverEncode {wire, persian}` → String — «متن پوششی» (row 31)
 * - `openSealed {secret, blobs}` → List of Uint8List?, one per blob, null
 *   for a blob that does not open with this key
 *
 * Key bank (`keybank/`):
 * - `canonicalPhone {phone}` → String? — the spelling keys are derived from
 * - `openKeyFile {file, password, anchors}` → `{authorityId, secret, keyId,
 *   cert}` — the member's own key and its certificate (`cert` as
 *   `certInfo` returns it); a key file holds nothing else
 *
 * `anchors` are the trusted authority public keys, passed in by Dart.
 *
 * Errors are the [SmsCryptoException.Code] names, plus `BAD_ARGS` and
 * `FAILED`. Nothing secret and no message text is ever logged.
 */
class SmsCryptoHandler {
    companion object {
        const val CHANNEL = "com.example.communication_super_app/sms_crypto"
        private const val TAG = "SmsCryptoHandler"
    }

    private val random = SecureRandom()

    /** Main-thread scope; the work runs on [Dispatchers.Default]. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    fun setup(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "generateIdentity" -> run(call, result) { identity(IdentityKeyPair.generate(random)) }
                "publicIdentity" -> run(call, result) {
                    val public = IdentityKeyPair.parse(call.bytes("secret")).public
                    mapOf("public" to public.encoded, "keyId" to public.keyId)
                }
                "inspect" -> run(call, result) { inspect(call.string("text")) }
                "ownInitWins" -> run(call, result) {
                    CertHandshake.ownInitWins(call.bytes("ownKid"), call.bytes("peerKid"))
                }
                "certInitiate" -> run(call, result) { certInitiate(call) }
                "certRespond" -> run(call, result) { certRespond(call) }
                "certComplete" -> run(call, result) { certComplete(call) }
                "certInfo" -> run(call, result) { cert(MemberCert.parse(call.bytes("cert"))) }
                "upgradeOffer" -> run(call, result) {
                    val session = Session.parse(call.bytes("session"))
                    sealed(Upgrade.offer(session, own(call)), session)
                }
                "upgradeAccept" -> run(call, result) { upgradeAccept(call) }
                "upgradeComplete" -> run(call, result) {
                    val upgraded = Upgrade.complete(
                        Session.parse(call.bytes("session")),
                        own(call),
                        call.argument<Int>("sid") ?: throw IllegalArgumentException("missing sid"),
                        call.bytes("ciphertext"),
                    )
                    mapOf("session" to upgraded.serialize(), "sid" to upgraded.sid)
                }
                "encryptText" -> run(call, result) { encryptText(call) }
                "encryptControl" -> run(call, result) { encryptControl(call) }
                "encryptGroupInfo" -> run(call, result) { encryptGroupInfo(call) }
                "decrypt" -> run(call, result) { decrypt(call) }
                "coverEncode" -> run(call, result) {
                    val packet = Wire.packetBytes(call.string("wire"))
                        ?: throw IllegalArgumentException("wire")
                    CoverText.encode(
                        packet,
                        if (call.argument<Boolean>("persian") == true) {
                            CoverText.Language.PERSIAN
                        } else {
                            CoverText.Language.ENGLISH
                        },
                    )
                }
                "openSealed" -> run(call, result) { openSealed(call) }
                "canonicalPhone" -> run(call, result) { Canon.phone(call.string("phone")) }
                "openKeyFile" -> run(call, result) { openKeyFile(call) }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() = scope.cancel()

    private fun identity(pair: IdentityKeyPair) = mapOf(
        "secret" to pair.serialize(),
        "public" to pair.public.encoded,
        "keyId" to pair.public.keyId,
    )

    private fun inspect(text: String): Map<String, Any>? {
        if (!Wire.looksEncrypted(text)) return null
        val packet = try {
            Wire.parse(text)
        } catch (e: SmsCryptoException) {
            return null
        }
        return when (packet) {
            is Packet.Message -> mapOf(
                "type" to "message",
                "sid" to packet.sid,
                "counter" to packet.counter,
                "control" to packet.control,
            )
            is Packet.Init -> handshakePacket("init", packet.sid, packet.cert)
            is Packet.Response -> handshakePacket("response", packet.sid, packet.cert)
        }
    }

    /** A handshake packet as `inspect` reports it; null when its certificate is malformed. */
    private fun handshakePacket(type: String, sid: Int, bytes: ByteArray): Map<String, Any>? {
        val cert = try {
            MemberCert.parse(bytes)
        } catch (e: SmsCryptoException) {
            return null
        }
        return mapOf(
            "type" to type,
            "sid" to sid,
            "senderKid" to cert.keyId,
            "certPhone" to cert.phone,
            "certGeneration" to cert.generation,
        )
    }

    private fun cert(c: MemberCert): Map<String, Any> = mapOf(
        "cert" to c.encoded,
        "keyId" to c.keyId,
        "phone" to c.phone,
        "generation" to c.generation,
    )

    private fun certInitiate(call: MethodCall): Map<String, Any> {
        val busy = call.argument<List<Int>>("busySids")?.toSet() ?: emptySet()
        val started = CertHandshake.initiate(MemberCert.parse(call.bytes("cert")), random, busy)
        return mapOf(
            "pending" to started.pending.serialize(),
            "sid" to started.pending.sid,
            "wire" to started.wire,
            "parts" to Wire.smsParts(started.wire),
        )
    }

    private fun certRespond(call: MethodCall): Map<String, Any> {
        val init = Wire.parse(call.string("text")) as? Packet.Init
            ?: cryptoError(SmsCryptoException.Code.WRONG_TYPE, "not a session request")
        val answered = CertHandshake.respond(
            own(call),
            MemberCert.parse(call.bytes("cert")),
            init,
            anchors(call),
            random,
        )
        return mapOf(
            "session" to answered.session.serialize(),
            "sid" to answered.session.sid,
            "wire" to answered.wire,
            "parts" to Wire.smsParts(answered.wire),
            "peer" to cert(answered.peer),
        )
    }

    private fun certComplete(call: MethodCall): Map<String, Any> {
        val response = Wire.parse(call.string("text")) as? Packet.Response
            ?: cryptoError(SmsCryptoException.Code.WRONG_TYPE, "not a session response")
        val done = CertHandshake.complete(
            own(call),
            MemberCert.parse(call.bytes("cert")),
            CertHandshake.Pending.parse(call.bytes("pending")),
            response,
            anchors(call),
        )
        return mapOf(
            "session" to done.session.serialize(),
            "sid" to done.session.sid,
            "peer" to cert(done.peer),
        )
    }

    private fun upgradeAccept(call: MethodCall): Map<String, Any> {
        val busy = call.argument<List<Int>>("busySids")?.toSet() ?: emptySet()
        val session = Session.parse(call.bytes("session"))
        val accepted = Upgrade.accept(session, call.bytes("key"), random, busy)
        return mapOf(
            "answer" to sealed(accepted.answer, session),
            "upgraded" to accepted.upgraded.serialize(),
            "upgradedSid" to accepted.upgraded.sid,
        )
    }

    private fun encryptText(call: MethodCall): Map<String, Any> {
        val deleteAfterSeen = call.argument<Boolean>("deleteAfterSeen") == true
        val groupId = call.argument<ByteArray>("groupId")
        val ttl = call.argument<Number>("ttlSeconds")?.toLong()
        val payload = if (groupId == null) {
            Payload.text(call.string("text"), deleteAfterSeen, ttl)
        } else {
            Payload.groupText(groupId, call.string("text"), deleteAfterSeen, ttl)
        }
        return seal(Session.parse(call.bytes("session")), payload)
    }

    /** `{groupId, version, mode, name, members: [{phone, keyId}]}` */
    private fun encryptGroupInfo(call: MethodCall): Map<String, Any> {
        val info = call.argument<Map<String, Any?>>("info") ?: throw IllegalArgumentException("missing info")
        val members = (info["members"] as? List<*>)?.map { m ->
            val member = m as? Map<*, *> ?: throw IllegalArgumentException("bad member")
            Payload.GroupMember(
                member["phone"] as? String ?: throw IllegalArgumentException("member phone"),
                member["keyId"] as? ByteArray ?: throw IllegalArgumentException("member keyId"),
            )
        } ?: throw IllegalArgumentException("missing members")
        val payload = Payload.groupInfo(
            Payload.GroupInfo(
                groupId = info["groupId"] as? ByteArray ?: throw IllegalArgumentException("groupId"),
                version = (info["version"] as? Number)?.toLong() ?: throw IllegalArgumentException("version"),
                mode = (info["mode"] as? Number)?.toInt() ?: throw IllegalArgumentException("mode"),
                name = info["name"] as? String ?: throw IllegalArgumentException("name"),
                members = members,
            ),
        )
        return seal(Session.parse(call.bytes("session")), payload, control = true)
    }

    private fun encryptControl(call: MethodCall): Map<String, Any> {
        val control = call.string("control")
        val payload = if (control == "pqDone") {
            Payload.pqDone()
        } else {
            val refSid = call.argument<Int>("refSid") ?: throw IllegalArgumentException("missing refSid")
            val refCounter = call.argument<Number>("refCounter")?.toLong()
                ?: throw IllegalArgumentException("missing refCounter")
            when (control) {
                "seen" -> Payload.seen(refSid, refCounter)
                "delete" -> Payload.delete(refSid, refCounter)
                else -> throw IllegalArgumentException("unknown control")
            }
        }
        return seal(Session.parse(call.bytes("session")), payload, control = true)
    }

    private fun seal(session: Session, payload: ByteArray, control: Boolean = false): Map<String, Any> {
        return sealed(session.seal(payload, control), session)
    }

    /** [sealed] as `encryptText` returns it; [before] is the state that sealed it. */
    private fun sealed(sealed: Session.Sealed, before: Session): Map<String, Any> = mapOf(
        "session" to sealed.session.serialize(),
        "wire" to sealed.wire,
        "parts" to Wire.smsParts(sealed.wire),
        "sid" to before.sid,
        "counter" to before.sendCounter,
    )

    private fun decrypt(call: MethodCall): Map<String, Any> {
        val message = Wire.parse(call.string("text")) as? Packet.Message
            ?: cryptoError(SmsCryptoException.Code.WRONG_TYPE, "not a message")
        val opened = Session.parse(call.bytes("session")).open(message)
        val base = mapOf(
            "session" to opened.session.serialize(),
            "sid" to message.sid,
            "counter" to message.counter,
        )
        val payload = Payload.parse(opened.payload)
        // A receipt travels as a control packet and only a receipt does: the
        // type is authenticated, so a mismatch is a sender bug, never data.
        if ((payload is Payload.Text) == message.control) {
            cryptoError(SmsCryptoException.Code.BAD_PAYLOAD, "payload does not match the packet type")
        }
        return base + when (val p = payload) {
            is Payload.Text -> buildMap {
                put("kind", "text")
                put("text", p.text)
                put("deleteAfterSeen", p.deleteAfterSeen)
                p.groupId?.let { put("groupId", it) }
                p.ttlSeconds?.let { put("ttlSeconds", it) }
            }
            is Payload.GroupInfo -> mapOf(
                "kind" to "groupInfo",
                "groupId" to p.groupId,
                "version" to p.version,
                "mode" to p.mode,
                "name" to p.name,
                "members" to p.members.map { mapOf("phone" to it.phone, "keyId" to it.keyId) },
            )
            is Payload.Seen -> mapOf("kind" to "seen", "refSid" to p.sid, "refCounter" to p.upTo)
            is Payload.Delete -> mapOf("kind" to "delete", "refSid" to p.sid, "refCounter" to p.counter)
            is Payload.PqOffer -> mapOf("kind" to "pqOffer", "pqKey" to p.encapsulationKey)
            is Payload.PqDone -> mapOf("kind" to "pqDone")
            is Payload.PqAccept -> mapOf(
                "kind" to "pqAccept",
                "pqSid" to p.sid,
                "pqCiphertext" to p.ciphertext,
            )
        }
    }

    private fun openSealed(call: MethodCall): List<ByteArray?> {
        val own = own(call)
        val blobs = call.argument<List<ByteArray>>("blobs") ?: throw IllegalArgumentException("blobs")
        return blobs.map { blob ->
            try {
                SealedBox.open(own, blob)
            } catch (e: SmsCryptoException) {
                null
            }
        }
    }

    private fun openKeyFile(call: MethodCall): Map<String, Any?> {
        val opened = KeyFile.open(call.bytes("file"), call.string("password"), anchors(call))
        // Named by its certificate's key id, as the packets name it.
        return mapOf(
            "authorityId" to opened.authority.authorityId,
            "secret" to opened.identity.serialize(),
            "keyId" to opened.cert.keyId,
            "cert" to cert(opened.cert),
        )
    }

    private fun anchors(call: MethodCall): List<AuthorityPublic> =
        (call.argument<List<ByteArray>>("anchors") ?: emptyList()).map { AuthorityPublic.parse(it) }

    private fun own(call: MethodCall) = IdentityKeyPair.parse(call.bytes("secret"))

    private fun MethodCall.bytes(name: String): ByteArray =
        argument<ByteArray>(name) ?: throw IllegalArgumentException("missing $name")

    private fun MethodCall.string(name: String): String =
        argument<String>(name) ?: throw IllegalArgumentException("missing $name")

    private fun run(call: MethodCall, result: MethodChannel.Result, block: () -> Any?) {
        scope.launch {
            try {
                val started = SystemClock.elapsedRealtime()
                val value = withContext(Dispatchers.Default) { block() }
                val elapsed = SystemClock.elapsedRealtime() - started
                // Method name and duration only — never keys or text.
                if (elapsed >= 20) Log.i(TAG, "${call.method} took $elapsed ms")
                result.success(value)
            } catch (e: SmsCryptoException) {
                result.error(e.code.name, e.message, null)
            } catch (e: IllegalArgumentException) {
                result.error("BAD_ARGS", e.message, null)
            } catch (e: OutOfMemoryError) {
                // Argon2id's 64 MiB on a phone with a small heap.
                Log.e(TAG, "${call.method} ran out of memory")
                result.error("FAILED", "OutOfMemoryError", null)
            } catch (e: ClassCastException) {
                result.error("BAD_ARGS", "argument of the wrong type", null)
            } catch (e: Exception) {
                Log.e(TAG, "${call.method} failed: ${e.javaClass.simpleName}")
                result.error("FAILED", e.javaClass.simpleName, null)
            }
        }
    }
}
