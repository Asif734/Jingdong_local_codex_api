import Cocoa

/// Synthetic values and an injected clock only. This executable does not
/// instantiate the collector, read AX/customer data, open JD, or post input.
@main
struct ResumableTransferOpenNativeTests {
  struct Clock {var now:TimeInterval=0}

  /// Exercise the production proof/boundary/click decisions across distinct
  /// leases. Each successful fresh read costs time; no old read can authorize
  /// the final lease's exact customer, focus or empty-composer requirement.
  struct Recovery {
    let expected="customer-v55"
    var proof=JDTransferOpenProof(requiredChangeFrom:"prior-customer")
    var checkpoint=true
    var clicks=0
    var reads=0
    mutating func step(clock:inout Clock,cost:TimeInterval=0.95,header:String?="customer-v55",
        selected:Bool=true,locatorCurrent:Bool=true,focused:Bool=true,composerEmpty:Bool=true,
        epochValid:Bool=true,interrupted:Bool=false)->String {
      let deadline=clock.now+1.6
      if let error=jdTransferOpenBoundary(epochValid:epochValid,interrupted:interrupted,budgetExpired:false) {
        proof=JDTransferOpenProof(requiredChangeFrom:"prior-customer");return error
      }
      let finalLease=proof.confirmedCustomer != nil
      reads+=1;clock.now+=cost
      if let error=jdTransferOpenBoundary(epochValid:epochValid,interrupted:interrupted,budgetExpired:clock.now>=deadline) {
        return error
      }
      if finalLease {
        guard let header else {
          proof=JDTransferOpenProof(requiredChangeFrom:"prior-customer");return "conversation_open_pending"
        }
        guard composerEmpty else {return "composer_not_empty"}
        guard focused else {return "conversation_open_pending"}
        guard selected,proof.complete(finalHeader:header,expected:expected,focused:focused,composerEmpty:composerEmpty) else {
          proof=JDTransferOpenProof(requiredChangeFrom:"prior-customer");return "conversation_open_pending"
        }
        checkpoint=false;return "opened"
      }
      if jdTransferOpenShouldClick(locatorCurrent:locatorCurrent,targetSelected:selected,active:header,expected:expected) {
        clicks+=1;checkpoint=true
        proof=JDTransferOpenProof(requiredChangeFrom:header)
        return "conversation_open_pending"
      }
      _=proof.observe(selected:selected,header:header,expected:expected)
      return "conversation_open_pending"
    }
  }

  static func main() {
    let expected="customer-v55"
    precondition(jdTransferOpenBoundary(epochValid:true,interrupted:false,budgetExpired:true)=="conversation_open_pending")
    precondition(jdTransferOpenBoundary(epochValid:true,interrupted:true,budgetExpired:false)=="handoff_yielded_for_reply")
    precondition(jdTransferOpenBoundary(epochValid:false,interrupted:true,budgetExpired:true)=="automation_stopped")
    precondition(jdTransferOpenBoundary(epochValid:true,interrupted:false,budgetExpired:false)==nil)

    // This is the same cursor used by advanceTransferOpenProjection, with
    // injected successful slow node reads (four bounded AX-like subreads).
    // A partial last unit yields; completed earlier nodes are not restarted.
    var refreshClock=Clock(),cursor=JDCooperativeRefreshCursor<Int>()
    var attempts=[Int:Int](),leases=0
    let candidates=[10,20,30,40]
    while cursor.nextIndex<candidates.count {
      leases+=1;precondition(leases<=8)
      let deadline=refreshClock.now+1.6
      let status=cursor.advance(items:candidates,available:{refreshClock.now<deadline}) { candidate in
        attempts[candidate,default:0]+=1
        for _ in 0..<4 {
          guard refreshClock.now<deadline else {return nil}
          refreshClock.now+=0.2
        }
        guard refreshClock.now<deadline else {return nil}
        return candidate
      }
      if cursor.nextIndex<candidates.count {precondition(status == .pending)}
    }
    precondition(leases>1 && refreshClock.now>1.6 && cursor.values==candidates)
    precondition(attempts[10]==1 && cursor.nextIndex==4)
    var invalid=JDCooperativeRefreshCursor<Int>()
    precondition(invalid.advance(items:[1],available:{true},read:{_ in nil}) == .invalidated)

    // Already-active exact identity needs no row click. Three slow successful
    // stages exceed a former 1.6s total budget but finish across three leases.
    var clock=Clock(),active=Recovery()
    precondition(active.step(clock:&clock)=="conversation_open_pending")
    precondition(active.step(clock:&clock)=="conversation_open_pending")
    precondition(active.checkpoint && active.proof.confirmedCustomer==expected)
    precondition(active.step(clock:&clock)=="opened")
    precondition(clock.now>1.6 && active.reads==3 && active.clicks==0 && !active.checkpoint)

    // A long native queue wait consumes no fresh slice budget. A fresh lease
    // begins at the actual injected start and still completes normally.
    var queuedClock=Clock(now:120),queued=Recovery()
    precondition(queued.step(clock:&queuedClock)=="conversation_open_pending")
    precondition(queued.proof.confirmedCustomer==nil)
    precondition(queued.step(clock:&queuedClock)=="conversation_open_pending")
    precondition(queued.step(clock:&queuedClock)=="opened")

    // A known target is clicked once from another selected conversation.
    // Timeout, a reply yield, and missing AX never cause a duplicate click
    // while the target remains selected, and never remove its checkpoint.
    var resumeClock=Clock(),resume=Recovery()
    precondition(resume.step(clock:&resumeClock,header:"prior-customer",selected:false)=="conversation_open_pending")
    precondition(resume.clicks==1 && resume.checkpoint)
    precondition(resume.step(clock:&resumeClock,cost:1.7)=="conversation_open_pending")
    precondition(resume.step(clock:&resumeClock,interrupted:true)=="handoff_yielded_for_reply")
    precondition(resume.step(clock:&resumeClock,header:nil)=="conversation_open_pending")
    precondition(resume.step(clock:&resumeClock)=="conversation_open_pending")
    precondition(resume.step(clock:&resumeClock)=="conversation_open_pending")
    precondition(resume.step(clock:&resumeClock,focused:false)=="conversation_open_pending")
    precondition(resume.clicks==1 && resume.checkpoint)
    precondition(resume.step(clock:&resumeClock)=="opened")
    precondition(resume.clicks==1 && !resume.checkpoint)

    // Nil or a concrete different header at final verification cannot reuse
    // the earlier correct header. Recovery needs a new matching pair.
    var staleClock=Clock(),stale=Recovery()
    _=stale.step(clock:&staleClock);_=stale.step(clock:&staleClock)
    precondition(stale.step(clock:&staleClock,header:nil)=="conversation_open_pending")
    precondition(stale.checkpoint && stale.proof.confirmedCustomer==nil)
    _=stale.step(clock:&staleClock);_=stale.step(clock:&staleClock)
    precondition(stale.step(clock:&staleClock,header:"customer-v550")=="conversation_open_pending")
    precondition(stale.checkpoint && stale.proof.confirmedCustomer==nil)
    _=stale.step(clock:&staleClock);_=stale.step(clock:&staleClock)
    precondition(stale.step(clock:&staleClock,composerEmpty:false)=="composer_not_empty")
    precondition(stale.checkpoint)

    // A changed selection rejects even a lagging, still-correct AX header at
    // final verification. Both stability samples must then be acquired anew.
    var selectionClock=Clock(),selection=Recovery()
    _=selection.step(clock:&selectionClock);_=selection.step(clock:&selectionClock)
    precondition(selection.step(clock:&selectionClock,selected:false)=="conversation_open_pending")
    precondition(selection.checkpoint && selection.proof.confirmedCustomer==nil && selection.clicks==0)
    _=selection.step(clock:&selectionClock);_=selection.step(clock:&selectionClock)
    precondition(selection.step(clock:&selectionClock)=="opened")

    // When another chat was actually served, a newly validated target row may
    // legitimately be clicked again. Expired locators and blank AX cannot.
    precondition(jdTransferOpenShouldClick(locatorCurrent:true,targetSelected:false,active:"another-customer",expected:expected))
    precondition(!jdTransferOpenShouldClick(locatorCurrent:true,targetSelected:true,active:"another-customer",expected:expected))
    precondition(!jdTransferOpenShouldClick(locatorCurrent:false,targetSelected:false,active:"another-customer",expected:expected))
    precondition(!jdTransferOpenShouldClick(locatorCurrent:true,targetSelected:false,active:nil,expected:expected))
    precondition(!jdTransferOpenShouldClick(locatorCurrent:true,targetSelected:false,active:expected,expected:expected))

    var proof=JDTransferOpenProof()
    precondition(proof.observe(selected:true,header:expected,expected:expected) == .pending)
    precondition(proof.observe(selected:true,header:"customer-v550",expected:expected) == .differentCustomer)
    precondition(proof.confirmedCustomer==nil && proof.checkpointRetained)
    precondition(proof.observe(selected:true,header:expected,expected:expected) == .pending)
    precondition(proof.observe(selected:true,header:expected,expected:expected) == .confirmed(expected))
    precondition(!proof.complete(finalHeader:nil,expected:expected,focused:true,composerEmpty:true))
    precondition(!proof.complete(finalHeader:"customer-v550",expected:expected,focused:true,composerEmpty:true))
    precondition(!proof.complete(finalHeader:expected,expected:expected,focused:false,composerEmpty:true))
    precondition(!proof.complete(finalHeader:expected,expected:expected,focused:true,composerEmpty:false))
    precondition(proof.checkpointRetained)
    precondition(proof.complete(finalHeader:expected,expected:expected,focused:true,composerEmpty:true))
    precondition(!proof.checkpointRetained)

    var stoppedClock=Clock(),stopped=Recovery()
    precondition(stopped.step(clock:&stoppedClock,header:"another-customer",selected:false,epochValid:false)=="automation_stopped")
    precondition(stopped.reads==0 && stopped.clicks==0 && stopped.checkpoint)
    print("v55 resumable transfer-open synthetic checks passed")
  }
}
