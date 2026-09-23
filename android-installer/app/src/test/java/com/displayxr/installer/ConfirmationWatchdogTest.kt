package com.displayxr.installer

import com.displayxr.installer.ConfirmationWatchdog.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stall found on the K68, pinned as tests.
 *
 * After the runtime installed, the next row sat on "Installing — confirm on
 * screen" for an hour with no dialog anywhere. The state machine below is the
 * answer to "then what?": waiting for the owner is a state with a deadline.
 */
class ConfirmationWatchdogTest {

    private fun wd() = ConfirmationWatchdog(softTimeoutMs = 20_000, hardTimeoutMs = 300_000)

    @Test
    fun `nothing raised means nothing to report`() {
        val w = wd()
        assertEquals(State.IDLE, w.onTick(0))
        assertEquals(State.IDLE, w.onTick(10_000_000))
        assertFalse(w.shouldReraiseOnForeground())
    }

    @Test
    fun `an answer inside the soft timeout never stalls`() {
        val w = wd()
        w.onRaised(0)
        assertEquals(State.RAISED, w.onTick(19_999))
        w.onAnswered()
        assertEquals(State.ANSWERED, w.onTick(60_000))
    }

    /** The hour on one row, made impossible: 20 s and the owner is told. */
    @Test
    fun `no answer within the soft timeout stalls and offers a retry`() {
        val w = wd()
        w.onRaised(0)
        assertEquals(State.RAISED, w.onTick(19_999))
        assertEquals(State.STALLED, w.onTick(20_000))
        assertTrue(w.shouldReraiseOnForeground())
    }

    @Test
    fun `retry puts it back in flight and restarts the soft deadline`() {
        val w = wd()
        w.onRaised(0)
        w.onTick(20_000)
        w.onRetry(20_000)
        assertEquals(State.RAISED, w.state)
        assertEquals(State.RAISED, w.onTick(39_999))
        assertEquals(State.STALLED, w.onTick(40_000))
    }

    /** Retrying must not be able to keep one row alive forever. */
    @Test
    fun `the hard timeout fires despite repeated retries`() {
        val w = wd()
        w.onRaised(0)
        var t = 0L
        repeat(14) {
            t += 20_000
            w.onTick(t)
            w.onRetry(t)
        }
        assertEquals(State.RAISED, w.state)          // still going at t=280s
        assertEquals(State.GAVE_UP, w.onTick(300_000))
    }

    @Test
    fun `giving up is terminal and no longer asks to be re-raised`() {
        val w = wd()
        w.onRaised(0)
        assertEquals(State.GAVE_UP, w.onTick(300_000))
        assertFalse(w.shouldReraiseOnForeground())
        w.onRetry(300_001)
        assertEquals(State.GAVE_UP, w.state)
        w.onRaised(300_002)
        assertEquals(State.GAVE_UP, w.state)
    }

    @Test
    fun `an answer after a stall is still an answer`() {
        val w = wd()
        w.onRaised(0)
        assertEquals(State.STALLED, w.onTick(25_000))
        w.onAnswered()
        assertEquals(State.ANSWERED, w.onTick(26_000))
        assertFalse(w.shouldReraiseOnForeground())
    }

    /**
     * Re-raising on regaining the foreground is exactly one case: already
     * stalled. Doing it while merely in flight would fire every time the
     * confirmation dialog itself pauses and resumes this activity — a loop, not
     * a recovery.
     */
    @Test
    fun `foreground re-raise applies only to a stalled confirmation`() {
        val w = wd()
        w.onRaised(0)
        assertFalse(w.shouldReraiseOnForeground())
        w.onTick(20_000)
        assertTrue(w.shouldReraiseOnForeground())
    }

    @Test
    fun `retry is ignored unless it is stalled`() {
        val w = wd()
        w.onRaised(0)
        w.onRetry(5_000)
        assertEquals(State.RAISED, w.state)
        // the soft deadline was NOT restarted by that ignored retry
        assertEquals(State.STALLED, w.onTick(20_000))
    }
}
