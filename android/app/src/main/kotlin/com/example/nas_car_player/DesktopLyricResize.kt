package com.example.nas_car_player

import kotlin.math.roundToInt

data class DesktopLyricResize(val width: Int, val x: Int)

// Keep the left edge anchored until a wider window needs room at the screen edge.
fun desktopLyricResize(initialWidth: Int, initialX: Int, delta: Float,
                       screenWidth: Int, minimumWidth: Int): DesktopLyricResize {
    val screen = screenWidth.coerceAtLeast(1)
    val width = (initialWidth + delta).roundToInt()
        .coerceIn(minimumWidth.coerceIn(1, screen), screen)
    return DesktopLyricResize(width, initialX.coerceIn(0, screen - width))
}
