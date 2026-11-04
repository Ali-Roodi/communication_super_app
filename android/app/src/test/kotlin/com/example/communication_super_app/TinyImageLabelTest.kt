package com.example.communication_super_app

import org.junit.Assert.assertEquals
import org.junit.Test

/** The Kotlin half of `TinyImage.isWire`; tiny_image_test.dart uses the same bodies. */
class TinyImageLabelTest {
    @Test
    fun aPictureReadsAsItsWord() {
        assertEquals("تصویر", TemplateWire.displayText("[#I1:8x2:b]qlU"))
        assertEquals("تصویر", TemplateWire.displayText("[#I1:16x8:r]8QA"))
    }

    @Test
    fun aNewerVersionStaysText() {
        assertEquals("[#I2:8x2:b]qlU", TemplateWire.displayText("[#I2:8x2:b]qlU"))
    }

    @Test
    fun ordinaryTextIsLeftAlone() {
        assertEquals("[#I think so", TemplateWire.displayText("[#I think so"))
    }
}
