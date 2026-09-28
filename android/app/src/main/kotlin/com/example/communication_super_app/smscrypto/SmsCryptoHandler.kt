package com.example.communication_super_app.smscrypto

import android.os.SystemClock
import com.example.communication_super_app.smscrypto.keybank.AuthorityPublic
import com.example.communication_super_app.smscrypto.keybank.Canon
import com.example.communication_super_app.smscrypto.keybank.Directory
import com.example.communication_super_app.smscrypto.keybank.KeyFile
import com.example.communication_super_app.smscrypto.keybank.KeyGroup
import com.example.communication_super_app.smscrypto.keybank.SignedDirectory
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
 * - `generateIdentity` → `{secret, public, keyId}`
 * - `identityFromSeed {seed}` → `{secret, public, keyId}` — deterministic
 * - `publicIdentity {secret}` → `{public, keyId}`
 * - `checkPublic {public}` → `{keyId}` — validates a key before it is stored
 * - `inspect {text}` → `null` for anything that is not one of our packets,
 *   else `{type: message|init|response, sid, counter? , senderKid?, recipientKid?}`
 * - `initiate {secret, peer, busySids}` → `{pending, sid, wire, parts}`
 * - `respond {secret, peer, text}` → `{session, sid, wire, parts}`
 * - `complete {secret, peer, pending, text}` → `{session, sid}`
 * - `ownInitWins {ownKid, peerKid}` → Boolean — crossed INITs
 * - `encryptText {session, text, deleteAfterSeen?}` → `{session, wire, parts, sid, counter}`
 * - `encryptControl {session, control: seen|delete, refSid, refCounter}` → same
 * - `decrypt {session, text}` → `{session, sid, counter, kind: text|seen|delete,
 *   text?, deleteAfterSeen?, refSid?, refCounter?}` — `sid`/`counter` name
 *   the message itself (what a later seen/delete refers to)
 *
 * Sealed records (`SealedBox` — what Kotlin writes for the hidden phonebook):
 * - `openSealed {secret, blobs}` → List of Uint8List?, one per blob, null
 *   for a blob that does not open with this key
 *
 * Key bank (`keybank/`):
 * - `canonicalPhone {phone}` → String? — the spelling keys are derived from
 * - `deriveGroup {name, passphrase}` → `{group, groupId}` — Argon2id, ~1 s
 * - `groupMember {group, phone}` → `{secret, public, keyId}`
 * - `openKeyFile {file, password, anchors}` → `{signed, directory, member?}`
 * - `verifyDirectory {signed, anchors}` → directory
 * - `authorityId {public}` → Uint8List
 *
 * A directory is `{authorityId, directoryId, serial, name, members: [{name,
 * phones, public, keyId}]}`; `member` is `{index, secret, public, keyId}`.
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
                "identityFromSeed" -> run(call, result) {
                    identity(IdentityKeyPair.fromSeed(call.bytes("seed")))
                }
                "publicIdentity" -> run(call, result) {
                    val public = IdentityKeyPair.parse(call.bytes("secret")).public
                    mapOf("public" to public.encoded, "keyId" to public.keyId)
                }
                "checkPublic" -> run(call, result) {
                    mapOf("keyId" to PublicIdentity.parse(call.bytes("public")).keyId)
                }
                "inspect" -> run(call, result) { inspect(call.string("text")) }
                "initiate" -> run(call, result) { initiate(call) }
                "respond" -> run(call, result) { respond(call) }
                "complete" -> run(call, result) { complete(call) }
                "ownInitWins" -> run(call, result) {
                    Handshake.ownInitWins(call.bytes("ownKid"), call.bytes("peerKid"))
                }
                "encryptText" -> run(call, result) { encryptText(call) }
                "encryptControl" -> run(call, result) { encryptControl(call) }
                "decrypt" -> run(call, result) { decrypt(call) }
                "openSealed" -> run(call, result) { openSealed(call) }
                "canonicalPhone" -> run(call, result) { Canon.phone(call.string("phone")) }
                "deriveGroup" -> run(call, result) {
                    val group = KeyGroup.derive(call.string("name"), call.string("passphrase"))
                    mapOf("group" to group.serialize(), "groupId" to group.groupId)
                }
                "groupMember" -> run(call, result) {
                    identity(KeyGroup.parse(call.bytes("group")).member(call.string("phone")))
                }
                "openKeyFile" -> run(call, result) { openKeyFile(call) }
                "verifyDirectory" -> run(call, result) {
                    directory(SignedDirectory.decode(call.bytes("signed")).verify(anchors(call)))
                }
                "authorityId" -> run(call, result) { AuthorityPublic.parse(call.bytes("public")).authorityId }
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
            is Packet.Init -> mapOf(
                "type" to "init",
                "sid" to packet.sid,
                "senderKid" to packet.senderKid,
                "recipientKid" to packet.recipientKid,
            )
            is Packet.Response -> mapOf(
                "type" to "response",
                "sid" to packet.sid,
                "senderKid" to packet.senderKid,
                "recipientKid" to packet.recipientKid,
            )
        }
    }

    private fun initiate(call: MethodCall): Map<String, Any> {
        val busy = call.argument<List<Int>>("busySids")?.toSet() ?: emptySet()
        val started = Handshake.initiate(own(call), peer(call), random, busy)
        return mapOf(
            "pending" to started.pending.serialize(),
            "sid" to started.pending.sid,
            "wire" to started.wire,
            "parts" to Wire.smsParts(started.wire),
        )
    }

    private fun respond(call: MethodCall): Map<String, Any> {
        val init = Wire.parse(call.string("text")) as? Packet.Init
            ?: cryptoError(SmsCryptoException.Code.WRONG_TYPE, "not a session request")
        val answered = Handshake.respond(own(call), peer(call), init, random)
        return mapOf(
            "session" to answered.session.serialize(),
            "sid" to answered.session.sid,
            "wire" to answered.wire,
            "parts" to Wire.smsParts(answered.wire),
        )
    }

    private fun complete(call: MethodCall): Map<String, Any> {
        val response = Wire.parse(call.string("text")) as? Packet.Response
            ?: cryptoError(SmsCryptoException.Code.WRONG_TYPE, "not a session response")
        val session = Handshake.complete(
            own(call),
            peer(call),
            Handshake.Pending.parse(call.bytes("pending")),
            response,
        )
        return mapOf("session" to session.serialize(), "sid" to session.sid)
    }

    private fun encryptText(call: MethodCall): Map<String, Any> = seal(
        Session.parse(call.bytes("session")),
        Payload.text(call.string("text"), call.argument<Boolean>("deleteAfterSeen") == true),
    )

    private fun encryptControl(call: MethodCall): Map<String, Any> {
        val refSid = call.argument<Int>("refSid") ?: throw IllegalArgumentException("missing refSid")
        val refCounter = call.argument<Number>("refCounter")?.toLong()
            ?: throw IllegalArgumentException("missing refCounter")
        val payload = when (call.string("control")) {
            "seen" -> Payload.seen(refSid, refCounter)
            "delete" -> Payload.delete(refSid, refCounter)
            else -> throw IllegalArgumentException("unknown control")
        }
        return seal(Session.parse(call.bytes("session")), payload, control = true)
    }

    private fun seal(session: Session, payload: ByteArray, control: Boolean = false): Map<String, Any> {
        val sealed = session.seal(payload, control)
        return mapOf(
            "session" to sealed.session.serialize(),
            "wire" to sealed.wire,
            "parts" to Wire.smsParts(sealed.wire),
            "sid" to session.sid,
            "counter" to session.sendCounter,
        )
    }

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
            is Payload.Text -> mapOf("kind" to "text", "text" to p.text, "deleteAfterSeen" to p.deleteAfterSeen)
            is Payload.Seen -> mapOf("kind" to "seen", "refSid" to p.sid, "refCounter" to p.upTo)
            is Payload.Delete -> mapOf("kind" to "delete", "refSid" to p.sid, "refCounter" to p.counter)
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
        val member = opened.identity?.let {
            identity(it) + ("index" to opened.memberIndex)
        }
        return mapOf(
            "signed" to opened.signed.encode(),
            "directory" to directory(opened.directory),
            "member" to member,
        )
    }

    private fun directory(d: Directory): Map<String, Any> = mapOf(
        "authorityId" to d.authorityId,
        "directoryId" to d.directoryId,
        "serial" to d.serial,
        "name" to d.name,
        "members" to d.members.map { m ->
            mapOf(
                "name" to m.name,
                "phones" to m.phones,
                "public" to m.identity.encoded,
                "keyId" to m.identity.keyId,
            )
        },
    )

    private fun anchors(call: MethodCall): List<AuthorityPublic> =
        (call.argument<List<ByteArray>>("anchors") ?: emptyList()).map { AuthorityPublic.parse(it) }

    private fun own(call: MethodCall) = IdentityKeyPair.parse(call.bytes("secret"))

    private fun peer(call: MethodCall) = PublicIdentity.parse(call.bytes("peer"))

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
