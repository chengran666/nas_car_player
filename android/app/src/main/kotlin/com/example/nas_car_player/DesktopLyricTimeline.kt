package com.example.nas_car_player

data class DesktopLyricLine(val timeMs: Long, val text: String)

// Shared by MediaSession callbacks and scheduled lyric boundaries, including seeks.
class DesktopLyricTimeline(val lines: List<DesktopLyricLine>) {
    fun indexAt(positionMs: Long): Int {
        var low = 0
        var high = lines.size
        while (low < high) {
            val mid = (low + high) ushr 1
            if (lines[mid].timeMs <= positionMs) low = mid + 1 else high = mid
        }
        return low - 1
    }

    fun nextDelay(positionMs: Long, speed: Float): Long? {
        if (speed <= 0f) return null
        val next = indexAt(positionMs) + 1
        if (next >= lines.size) return null
        return ((lines[next].timeMs - positionMs) / speed).toLong().coerceAtLeast(16L)
    }

    fun nextVisibleIndex(index: Int): Int? = ((index + 1).coerceAtLeast(0) until lines.size)
        .firstOrNull { lines[it].text.isNotBlank() && (index < 0 || lines[it].timeMs > lines[index].timeMs) }

    companion object {
        fun position(base: Long, updatedAt: Long, now: Long, speed: Float, playing: Boolean): Long {
            val elapsed = if (playing && updatedAt > 0) (now - updatedAt).coerceAtLeast(0) else 0
            return (base + (elapsed * speed).toLong()).coerceAtLeast(0)
        }
    }
}

/** Player snapshots arrive on lyric/state changes, never on a polling timer.
 * Transport delay is applied once, then Android's monotonic clock owns progress. */
class DesktopPlaybackClock {
    private var base = 0L
    private var updatedAt = 0L
    var speed = 1f
        private set
    var advancing = false
        private set
    var initialized = false
        private set

    fun update(position: Long, sampledAt: Long, wallNow: Long, monotonicNow: Long,
               playbackSpeed: Float, playing: Boolean) {
        speed = playbackSpeed.coerceAtLeast(0f)
        advancing = playing
        val transit = if (sampledAt > 0 && playing) (wallNow - sampledAt).coerceIn(0L, 5000L) else 0L
        base = (position + (transit * speed).toLong()).coerceAtLeast(0L)
        updatedAt = monotonicNow
        initialized = true
    }

    fun position(now: Long): Long = DesktopLyricTimeline.position(base, updatedAt, now, speed, advancing)
}
