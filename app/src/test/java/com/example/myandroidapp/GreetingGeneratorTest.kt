package com.example.myandroidapp

import org.junit.Assert.assertEquals
import org.junit.Test

class GreetingGeneratorTest {
    private val generator = GreetingGenerator()

    @Test
    fun `generateGreeting returns correct message`() {
        val name = "Cursor"
        val expected = "Hello, Cursor!"
        assertEquals(expected, generator.generateGreeting(name))
    }

    @Test
    fun `generateGreeting handles empty name`() {
        val name = ""
        val expected = "Hello, !"
        assertEquals(expected, generator.generateGreeting(name))
    }
} 