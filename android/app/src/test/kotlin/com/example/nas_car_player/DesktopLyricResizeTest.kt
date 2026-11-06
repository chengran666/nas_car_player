package com.example.nas_car_player

import org.junit.Assert.*
import org.junit.Test

class DesktopLyricResizeTest {
    @Test fun draggingPreservesLeftEdgeUntilExpansionNeedsRoom() {
        assertEquals(DesktopLyricResize(1200, 300), desktopLyricResize(1000, 300, 200f, 1920, 576))
        assertEquals(DesktopLyricResize(1800, 120), desktopLyricResize(1000, 300, 800f, 1920, 576))
        assertEquals(DesktopLyricResize(1920, 0), desktopLyricResize(1000, 300, 9999f, 1920, 576))
    }
    @Test fun shrinkingStopsAtMinimumAndRetainsTheAnchor() {
        assertEquals(DesktopLyricResize(800, 300), desktopLyricResize(1000, 300, -200f, 1920, 576))
        assertEquals(DesktopLyricResize(576, 300), desktopLyricResize(1000, 300, -9999f, 1920, 576))
        // Dragging back within the same gesture restores the original left position.
        assertEquals(DesktopLyricResize(1000, 300), desktopLyricResize(1000, 300, 0f, 1920, 576))
    }
    @Test fun smallScreensAndOutOfBoundsPositionsStayOnScreen() {
        assertEquals(DesktopLyricResize(320, 0), desktopLyricResize(200, 500, 10f, 320, 400))
        assertEquals(DesktopLyricResize(210, 0), desktopLyricResize(200, -20, 10f, 320, 100))
        assertEquals(DesktopLyricResize(210, 110), desktopLyricResize(200, 500, 10f, 320, 100))
    }
}
