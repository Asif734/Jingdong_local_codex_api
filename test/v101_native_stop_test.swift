import Foundation

func verifyNativeStopCancellation() {
  let runtime=JDNativeWorkRegistry(maxConcurrent:2)
  let entered=DispatchSemaphore(value:0), release=DispatchSemaphore(value:0)
  let lock=NSLock();var replies:[String]=[];var staleWork=false;var staleWrite=false
  func reply(_ value:String) {lock.lock();replies.append(value);lock.unlock()}
  runtime.enqueue(cancel:{reply("cancel1")}) { finish in
    entered.signal();release.wait()
    try? runtime.withCurrent {staleWrite=true}
    finish {reply("late")}
  }
  runtime.enqueue(cancel:{reply("cancel2")}) { finish in
    entered.signal();release.wait();finish {reply("late")}
  }
  precondition(entered.wait(timeout:.now()+2) == .success)
  precondition(entered.wait(timeout:.now()+2) == .success)
  runtime.enqueue(cancel:{reply("cancel3")}) { finish in
    staleWork=true;finish {reply("queued")}
  }
  var asyncCurrent:(()->Bool)?
  let captured=DispatchSemaphore(value:0)
  let asyncRuntime=JDNativeWorkRegistry(maxConcurrent:1)
  asyncRuntime.enqueue(cancel:{}) { _ in
    asyncCurrent=asyncRuntime.currentValidity();captured.signal()
  }
  precondition(captured.wait(timeout:.now()+2) == .success)
  precondition(asyncCurrent?()==true)
  _=asyncRuntime.setEpoch(1,running:false)
  _=asyncRuntime.setEpoch(2,running:true)
  precondition(asyncCurrent?()==false,"Async speech callbacks stay bound to their enqueue generation")
  var resourceCancelled=false
  let resource=runtime.registerResourceCancellation {resourceCancelled=true}!
  var visionCancelled=0
  let registration=runtime.registerVision(cancel:{visionCancelled += 1})!
  precondition(runtime.registerVision(cancel:{}) != nil)
  precondition(runtime.registerVision(cancel:{}) == nil,"Vision admission is bounded without waiting")
  let count=runtime.setEpoch(10,running:false)
  precondition(count == 3)
  precondition(replies.sorted()==["cancel1","cancel2","cancel3"])
  precondition(visionCancelled == 1)
  precondition(resourceCancelled,"Stop cancels active frame generators too")
  runtime.unregisterResourceCancellation(resource)
  runtime.unregisterVision(registration)
  _=runtime.setEpoch(11,running:true)
  release.signal();release.signal()
  let fresh=DispatchSemaphore(value:0)
  runtime.enqueue(cancel:{reply("unexpected")}) { finish in finish {reply("fresh");fresh.signal()} }
  precondition(fresh.wait(timeout:.now()+2) == .success)
  precondition(!staleWork)
  precondition(!staleWrite,"Old work cannot publish files after a new generation starts")
  precondition(replies.sorted()==["cancel1","cancel2","cancel3","fresh"])
  print("Native Stop cancellation: running and queued exactly once, late result rejected, fresh generation admitted, bounded Vision")
}
verifyNativeStopCancellation()
