package ir.hamrasan.keybank

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNull

/**
 * Pins the issuing side to the app. The triples are the ones in
 * `test/unit/activation_code_test.dart` (computed by the original
 * `Activation.java`); the pairs below them were checked on real phones.
 * The organization codes are pinned to the same values in the app's test —
 * the two BLAKE3 implementations agreeing is what makes them a check.
 */
class ActivationTest {
    private val triples = listOf(
        Triple("9774d56d682e549c", "10e9fa", "ba57b3b74f"),
        Triple("a1b2c3d4e5f60718", "5cd04a", "875e3c4ba5"),
        Triple("0000000000000000", "65a992", "57a1ce9d4c"),
        Triple("ffffffffffffffff", "806736", "a5808f8364"),
        Triple("3f6c1e0b9a27d845", "33b957", "0c310a2277"),
    )

    private val inter = Activation.Target.INTER_ORGANIZATION
    private val org = Activation.Target.ORGANIZATION

    @Test
    fun matchesTheAppReference() {
        for ((androidId, device, activation) in triples) {
            assertEquals(device, Activation.deviceCodeFor(androidId), androidId)
            assertEquals(activation, Activation.activationCodeFor(device, inter), device)
        }
    }

    @Test
    fun codesAcceptedByRealPhones() {
        assertEquals("9c4a48e93a", Activation.activationCodeFor("b60966", inter))
        assertEquals("585982eaf4", Activation.activationCodeFor("4ccd9c", inter))
        assertEquals("6510c93974", Activation.activationCodeFor("4f339b", inter))
        assertEquals("9297dea3b4", Activation.activationCodeFor("ef10c7", inter))
    }

    @Test
    fun organizationCodesMatchTheApp() {
        assertEquals("2e68ceefcf", Activation.activationCodeFor("10e9fa", org))
        assertEquals("16e4d9c787", Activation.activationCodeFor("5cd04a", org))
        assertEquals("3496a31e3a", Activation.activationCodeFor("65a992", org))
        assertEquals("b0c1e7c455", Activation.activationCodeFor("806736", org))
        assertEquals("a3d4ec8c14", Activation.activationCodeFor("33b957", org))
        assertEquals("f87be27c18", Activation.activationCodeFor("b60966", org))
    }

    @Test
    fun theTwoEditionsNeverShareACode() {
        for ((_, device, _) in triples) {
            assertNotEquals(Activation.activationCodeFor(device, inter), Activation.activationCodeFor(device, org), device)
        }
    }

    @Test
    fun deviceCodeIsReadForgivingly() {
        assertEquals("4f339b", Activation.normalizeDeviceCode("4F339B"))
        assertEquals("4f339b", Activation.normalizeDeviceCode(" 4f3-39b "))
        assertEquals("4f339b", Activation.normalizeDeviceCode("۴f۳۳۹b"))
        assertEquals("4f339b", Activation.normalizeDeviceCode("٤f٣٣٩b"))
        assertEquals("4f339b", Activation.normalizeDeviceCode("‎4f3‌39b"))
    }

    @Test
    fun anythingElseIsNotADeviceCode() {
        assertNull(Activation.normalizeDeviceCode(""))
        assertNull(Activation.normalizeDeviceCode("4f339"))
        assertNull(Activation.normalizeDeviceCode("4f339b0"))
        assertNull(Activation.normalizeDeviceCode("4f339g"))
        assertFailsWith<IllegalArgumentException> { Activation.activationCodeFor("4F339B", inter) }
    }

    @Test
    fun displayGroupsTheCode() {
        assertEquals("6510c-93974", Activation.display("6510c93974"))
    }
}
