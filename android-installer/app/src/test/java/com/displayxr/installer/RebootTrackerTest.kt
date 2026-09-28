package com.displayxr.installer

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The reboot reminder must outlive a relaunch and die only with a real reboot. */
class RebootTrackerTest {

    @Test
    fun `same boot count is still pending, a new one is not`() {
        assertTrue(RebootTracker.stillPending(BootId(7, 1_000), BootId(7, 1_500)))
        assertFalse(RebootTracker.stillPending(BootId(7, 1_000), BootId(8, 1_000)))
    }

    @Test
    fun `boot count wins over a drifting epoch`() {
        assertTrue(RebootTracker.stillPending(BootId(7, 0), BootId(7, 10_000_000)))
    }

    @Test
    fun `without boot counts, epochs decide within the tolerance`() {
        assertTrue(RebootTracker.stillPending(BootId(null, 1_000_000), BootId(null, 1_020_000)))
        assertFalse(RebootTracker.stillPending(BootId(null, 1_000_000), BootId(null, 5_000_000)))
    }

    @Test
    fun `when nothing can be compared the reminder stays`() {
        assertTrue(RebootTracker.stillPending(BootId(null, null), BootId(3, 100)))
        assertTrue(RebootTracker.stillPending(BootId(3, null), BootId(null, 100)))
    }
}
