import Foundation

@main
struct HoldingSendNativeTests {
  static func make(holdMs: Int64 = 102_000, red: Bool = true,
                   receiptId: String? = "old", epoch: Int? = 7) -> JDHoldingClickGate? {
    JDHoldingClickGate(customer: "jd_exact", attemptId: receiptId, epoch: epoch,
      requireRedClock: red, notBeforeMs: holdMs, queuedAt: 20, queuedWallMs: 100_000,
      deadline: 26)
  }

  static func main() {
    // Preparing early may not become a physical click before the red deadline.
    let gate = make()!
    var clicks = 0
    precondition(gate.commit(now: 21.999, runCurrent: true, dispatch: { clicks += 1 }) == "holding_click_not_due")
    precondition(clicks == 0)
    precondition(gate.commit(now: 22.000, runCurrent: true, dispatch: { clicks += 1 }) == nil)
    precondition(clicks == 1)
    precondition(!gate.requestYield(customer: "jd_exact", attemptId: "old", epoch: 7))
    precondition(gate.commit(now: 22.5, runCurrent: true, dispatch: { clicks += 1 }) != nil)
    precondition(clicks == 1)

    // A wider five-second or unbounded UI hold is not a supported fallback.
    precondition(make(holdMs: 105_000) == nil)
    precondition(make(red: false) == nil)
    precondition(make(receiptId: nil) == nil)
    precondition(make(receiptId: "") == nil)
    precondition(make(epoch: nil) == nil)

    let stopped = make()!
    precondition(stopped.commit(now: 22.1, runCurrent: false, dispatch: { clicks += 1 }) == "automation_stopped")
    let expired = make()!
    precondition(expired.commit(now: 26, runCurrent: true, dispatch: { clicks += 1 }) == "send_preclick_budget_exceeded")

    let yielding = make()!
    precondition(!yielding.requestYield(customer: "jd_other", attemptId: "old", epoch: 7))
    precondition(!yielding.requestYield(customer: "jd_exact", attemptId: "new", epoch: 7))
    precondition(!yielding.requestYield(customer: "jd_exact", attemptId: "old", epoch: 8))
    var now: TimeInterval = 21.25
    var slept = 0
    let interrupted = yielding.waitUntilDue(now: { now }, runCurrent: { true }, pause: { interval in
      precondition(interval > 0 && interval <= 0.025)
      slept += 1
      now += interval
      if slept == 2 { precondition(yielding.requestYield(customer: "jd_exact", attemptId: "old", epoch: 7)) }
    })
    precondition(interrupted == "holding_yielded_to_formal" && slept == 2 && now < 22)
    precondition(yielding.commit(now: 22.2, runCurrent: true, dispatch: { clicks += 1 }) == "holding_yielded_to_formal")
    precondition(clicks == 1)

    let waiting = make()!
    now = 21.9
    precondition(waiting.waitUntilDue(now: { now }, runCurrent: { true }, pause: { now += $0 }) == nil)
    precondition(now == 22 && clicks == 1) // The final AX check runs after the wait.
    print("PASS: timed holding stays bounded, scoped yield wins before click only")
  }
}
