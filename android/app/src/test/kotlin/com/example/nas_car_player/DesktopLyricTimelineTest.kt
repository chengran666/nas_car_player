package com.example.nas_car_player

import org.junit.Assert.*
import org.junit.Test

class DesktopLyricTimelineTest {
    private val timeline = DesktopLyricTimeline(listOf(
        DesktopLyricLine(1000, "first"), DesktopLyricLine(2500, "second"),
        DesktopLyricLine(2500, "translation"), DesktopLyricLine(5000, "third")))

    @Test fun boundariesAndSeeks() {
        assertEquals(-1, timeline.indexAt(0))
        assertEquals(0, timeline.indexAt(1000))
        assertEquals(2, timeline.indexAt(2500))
        assertEquals(3, timeline.indexAt(9999))
        assertEquals(0, timeline.indexAt(2000)) // Seek back must not keep a forward-only cursor.
        assertEquals(-1, DesktopLyricTimeline(emptyList()).indexAt(123))
        assertEquals(0, DesktopLyricTimeline(listOf(DesktopLyricLine(-500, "early"))).indexAt(0))
    }
    @Test fun schedulesNextBoundaryAtPlaybackSpeed() {
        assertEquals(500L, timeline.nextDelay(1500, 2f))
        assertEquals(2500L, timeline.nextDelay(2500, 1f))
        assertNull(timeline.nextDelay(5000, 1f))
        assertNull(timeline.nextDelay(0, 0f))
    }
    @Test fun clockFollowsSessionAndFreezesWhenPaused() {
        assertEquals(3000L, DesktopLyricTimeline.position(1000, 100, 2100, 1f, true))
        assertEquals(5000L, DesktopLyricTimeline.position(1000, 100, 2100, 2f, true))
        assertEquals(1000L, DesktopLyricTimeline.position(1000, 100, 2100, 1f, false))
        assertEquals(1000L, DesktopLyricTimeline.position(1000, 0, 2100, 1f, true))
        assertEquals(1000L, DesktopLyricTimeline.position(1000, 3000, 2100, 1f, true))
    }
    @Test fun lateLyricsUseCurrentPlayerClockRatherThanFetchStart() {
        val clock = DesktopPlaybackClock()
        // Lyrics took six seconds to fetch. Playback has already reached 6.2s.
        clock.update(6200, 10000, 10025, 5000, 1f, true)
        assertEquals(6225L, clock.position(5000))
        assertEquals(7225L, clock.position(6000))
        assertEquals(3, timeline.indexAt(clock.position(5000)))
    }
    @Test fun snapshotsHandlePauseSeekSpeedAndClockChanges() {
        val clock = DesktopPlaybackClock()
        clock.update(12000, 1000, 1100, 500, 1f, false)
        assertEquals(12000L, clock.position(5000))
        clock.update(2000, 6000, 6000, 5500, 2f, true)
        assertEquals(4000L, clock.position(6500))
        // A delayed old MediaSession clock cannot replace the player snapshot.
        assertEquals(5000L, clock.position(7000))
        clock.update(8000, 90000, 50000, 7000, 1f, true)
        assertEquals(9000L, clock.position(8000))
    }
    @Test fun staggeredRowsSkipBlankAndSameTimestampRows() {
        val rows = DesktopLyricTimeline(listOf(
            DesktopLyricLine(0, "original\n译文"), DesktopLyricLine(0, "duplicate timestamp"),
            DesktopLyricLine(2000, " "), DesktopLyricLine(3000, "next\n下一句")))
        assertEquals(3, rows.nextVisibleIndex(0))
        assertEquals(3, rows.nextVisibleIndex(1))
        assertNull(rows.nextVisibleIndex(3))
        assertNull(DesktopLyricTimeline(emptyList()).nextVisibleIndex(-1))
    }
}
