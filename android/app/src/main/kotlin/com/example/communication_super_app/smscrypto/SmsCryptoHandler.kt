package com.example.communication_super_app.smscrypto

import android.os.SystemClock
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
 * - `encryptText {session, text}` → `{session, wire, parts}`
 * - `decrypt {session, text}` → `{session, text}`
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
                "decrypt" -> run(call, result) { decrypt(call) }
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
            is Packet.Message -> mapOf("type" to "message", "sid" to packet.sid, "counter" to packet.counter)
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

    private fun encryptText(call: MethodCall): Map<String, Any> {
        val sealed = Session.parse(call.bytes("session")).seal(Payload.text(call.string("text")))
        return mapOf(
            "session" to sealed.session.serialize(),
            "wire" to sealed.wire,
            "parts" to Wire.smsParts(sealed.wire),
        )
    }

    private fun decrypt(call: MethodCall): Map<String, Any> {
        val message = Wire.parse(call.string("text")) as? Packet.Message
            ?: cryptoError(SmsCryptoException.Code.WRONG_TYPE, "not a message")
        val opened = Session.parse(call.bytes("session")).open(message)
        return mapOf(
            "session" to opened.session.serialize(),
            "text" to Payload.parse(opened.payload).text,
        )
    }

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
            } catch (e: ClassCastException) {
                result.error("BAD_ARGS", "argument of the wrong type", null)
            } catch (e: Exception) {
                Log.e(TAG, "${call.method} failed: ${e.javaClass.simpleName}")
                result.error("FAILED", e.javaClass.simpleName, null)
            }
        }
    }
}
