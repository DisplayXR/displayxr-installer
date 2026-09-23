package com.displayxr.installer

/**
 * The pending-user-action state machine.
 *
 * ## Why this exists
 *
 * On the K68, the first run installed the runtime cleanly and then sat on
 * "Installing — confirm on screen" for an hour with **no dialog on screen**.
 * `usagestats` showed the runtime's own `PackageInstallerActivity` open and
 * close normally, and then no second one, ever. Force-stopping the app and
 * re-tapping INSTALL drove the remaining five packages straight through, so it
 * was neither a bad session nor a bad asset. Two candidates in the log: the
 * OEM's `CpuFreezerManagerServiceV2` freezing this app (`mFreezeType=3`, a
 * freeze check every ~30 s), and a `STATUS_PENDING_USER_ACTION` intent started
 * while the app was not foreground and silently dropped.
 *
 * The cause is not settled, and this does not depend on settling it. What was
 * indefensible is the UI contract: it claimed there was something on screen to
 * confirm when there was not, and offered no way out. So the rule here is that
 * "waiting for the owner" is a state with a **deadline**, not a resting place.
 *
 * Deliberately free of Android types and of any clock of its own — the caller
 * passes the time — so the whole thing is driven by JVM tests.
 */
class ConfirmationWatchdog(
    /** After this long with no answer, tell the owner and offer a retry. */
    private val softTimeoutMs: Long = 20_000,
    /**
     * After this long in total — retries included — give up, abandon the
     * session and let the run continue to the next package. An hour on one row
     * is what this number exists to make impossible.
     */
    private val hardTimeoutMs: Long = 300_000,
) {

    enum class State {
        /** Nothing raised yet. */
        IDLE,

        /** The confirmation intent was started; waiting for the owner. */
        RAISED,

        /** No answer within the soft timeout. The owner is told and offered a retry. */
        STALLED,

        /** Past the hard timeout. The caller abandons the session and moves on. */
        GAVE_UP,

        /** Android reported success or failure. Terminal. */
        ANSWERED,
    }

    var state: State = State.IDLE
        private set

    private var raisedAtMs = 0L
    private var firstRaisedAtMs = 0L

    /** The confirmation intent has just been started (or re-started). */
    fun onRaised(nowMs: Long) {
        if (state == State.ANSWERED || state == State.GAVE_UP) return
        if (state == State.IDLE) firstRaisedAtMs = nowMs
        raisedAtMs = nowMs
        state = State.RAISED
    }

    /**
     * The owner asked to try again. The soft deadline restarts; the hard one
     * does not, so retrying cannot keep a run alive forever.
     */
    fun onRetry(nowMs: Long) {
        if (state != State.STALLED) return
        raisedAtMs = nowMs
        state = State.RAISED
    }

    /** Android delivered a terminal status. */
    fun onAnswered() {
        state = State.ANSWERED
    }

    /** Advance time. Returns the current state. */
    fun onTick(nowMs: Long): State {
        if (state == State.IDLE || state == State.ANSWERED || state == State.GAVE_UP) return state
        if (nowMs - firstRaisedAtMs >= hardTimeoutMs) {
            state = State.GAVE_UP
            return state
        }
        if (state == State.RAISED && nowMs - raisedAtMs >= softTimeoutMs) {
            state = State.STALLED
        }
        return state
    }

    /**
     * Whether re-raising the intent unprompted is appropriate — i.e. on regaining
     * the foreground.
     *
     * Only when STALLED. Re-raising from [State.RAISED] would fire every time the
     * confirmation dialog itself pauses and resumes this activity, which is a
     * loop, not a recovery.
     */
    fun shouldReraiseOnForeground(): Boolean = state == State.STALLED
}
