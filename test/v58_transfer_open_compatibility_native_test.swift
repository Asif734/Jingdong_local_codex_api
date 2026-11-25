import Cocoa

/// Injected individual attributes only. No collector, live AX, screenshots,
/// customer data, windows or input events are used by this executable.
@main
struct TransferOpenCompatibilityNativeTests {
  final class Reader {
    var roles=[1:"AXWindow",2:"AXSplitGroup",3:"AXTextArea",4:"AXStaticText"]
    var frames=[1:CGRect(x:0,y:0,width:1000,height:800),
      2:CGRect(x:100,y:100,width:600,height:650),
      3:CGRect(x:112,y:600,width:576,height:100),
      4:CGRect(x:150,y:110,width:200,height:20)]
    var text=[3:["AXValue":""],4:["AXValue":"customer-v58"]]
    var children=[1:[2,99],2:[3,4],99:[100],100:[101]]
    var now:TimeInterval=0
    var deadline:TimeInterval=1.6
    var cost:TimeInterval=0
    var interrupted=false
    var interruptAfter:Int?
    var calls=[String]()
    var parentReads=[Int:Int]()
    var available:Bool { !interrupted && now<deadline }
    func tick(_ label:String)->Bool {
      guard available else {return false}
      calls.append(label);now+=cost
      if calls.count==interruptAfter {interrupted=true}
      return true
    }
    func string(_ id:Int,_ attribute:String)->String? {
      guard tick("\(id):\(attribute)") else {return nil}
      return attribute=="AXRole" ? roles[id]:text[id]?[attribute]
    }
    func frame(_ id:Int)->CGRect? {
      guard tick("\(id):AXPosition"),tick("\(id):AXSize") else {return nil}
      return frames[id]
    }
    func descendants(_ id:Int)->[Int]? {
      guard tick("\(id):AXChildren") else {return nil}
      parentReads[id,default:0]+=1;return children[id]
    }
    func refresh(_ references:[JDReplyStyleNodeReference<Int>])->[JDReplyStyleNodeValues]? {
      jdRefreshReplyStyleNodes(references,available:{self.available},
        readString:{self.string($0,$1)},readFrame:{self.frame($0)},
        readChildren:{self.descendants($0)},equal:==)
    }
    func newLease() {deadline=now+1.6;interrupted=false;interruptAfter=nil;calls.removeAll();parentReads.removeAll()}
  }

  static func references(_ reader:Reader)->[JDReplyStyleNodeReference<Int>] {
    (1...4).map { id in
      let parent=id==1 ? nil:(id==2 ? 1:2)
      return JDReplyStyleNodeReference(element:id,role:reader.roles[id]!,frame:reader.frames[id],
        structural:id<=3,parent:parent,parentChildren:parent.flatMap{reader.children[$0]})
    }
  }

  static func check(_ values:[JDReplyStyleNodeValues]?,reader:Reader,focused:Bool=true)->JDTransferActiveOpenCheck {
    jdTransferActiveOpenCheck(expected:"customer-v58",customer:values?.last?.value,
      composerValue:values?[2].value,focused:focused,modalBlocked:false,available:reader.available)
  }

  static func main() {
    let optional=Reader(),baseline=references(optional)
    let values=optional.refresh(baseline)!
    precondition(values.count==4 && values[0].title==nil && values[0].description==nil && values[0].value==nil)
    precondition(values[2].value=="" && check(values,reader:optional) == .ready("customer-v58"))
    precondition(optional.parentReads==[1:1,2:1])
    // No batch reader exists in this loop, and a grandparent/sibling subtree
    // is never recursively read merely to verify the required direct parent.
    precondition(optional.calls.contains("3:AXValue") && optional.calls.contains("4:AXRole"))
    precondition(!optional.calls.contains(where:{$0.hasPrefix("99:") || $0.hasPrefix("100:")}))

    let missingRole=Reader(),missingRefs=references(missingRole)
    missingRole.roles.removeValue(forKey:3)
    precondition(missingRole.refresh(missingRefs)==nil)
    let changedRole=Reader(),roleRefs=references(changedRole)
    changedRole.roles[4]="AXButton"
    precondition(changedRole.refresh(roleRefs)==nil)
    let changedFrame=Reader(),frameRefs=references(changedFrame)
    changedFrame.frames[3]=changedFrame.frames[3]!.offsetBy(dx:0,dy:10)
    precondition(changedFrame.refresh(frameRefs)==nil)
    // A full fresh reception fallback supplies a new structural baseline.
    changedFrame.newLease()
    precondition(changedFrame.refresh(references(changedFrame)) != nil)

    let missingOptional=Reader()
    missingOptional.text[3]=[:]
    let readable=missingOptional.refresh(references(missingOptional))!
    precondition(readable[2].value==nil)
    precondition(check(readable,reader:missingOptional) == .pending("composer_ax_unavailable"))
    let draft=Reader();draft.text[3]?["AXValue"]="operator draft"
    precondition(check(draft.refresh(references(draft)),reader:draft) == .blocked("composer_not_empty"))
    let different=Reader();different.text[4]?["AXValue"]="customer-v580"
    precondition(check(different.refresh(references(different)),reader:different) == .differentCustomer)
    precondition(check(values,reader:optional,focused:false) == .pending("reception_focus_required"))
    precondition(jdTransferActiveOpenCheck(expected:"customer-v58",customer:"customer-v58",composerValue:"",
      focused:true,modalBlocked:true,available:true) == .pending("reception_focus_blocked"))

    let movedParent=Reader(),parentRefs=references(movedParent)
    movedParent.children[2]=[3,40]
    precondition(movedParent.refresh(parentRefs)==nil)
    movedParent.newLease()
    // Retained direct-parent context must reject the same detached header on
    // resume; a focus yield cannot silently erase this membership requirement.
    precondition(movedParent.refresh(parentRefs)==nil)
    let missingParent=Reader(),missingParentRefs=references(missingParent)
    missingParent.children.removeValue(forKey:2)
    precondition(missingParent.refresh(missingParentRefs)==nil)

    let yielded=Reader(),yieldRefs=references(yielded)
    yielded.interruptAfter=1
    precondition(yielded.refresh(yieldRefs)==nil && yielded.calls==["1:AXRole"])
    yielded.newLease()
    precondition(check(yielded.refresh(yieldRefs),reader:yielded) == .ready("customer-v58"))

    // Real production refreshes with injected slow per-attribute reads. Each
    // pass is ~0.9s; two would exceed the slice. Active admission needs one
    // fresh pass per lease, and a focus wait resumes with new current values.
    let slow=Reader(),slowRefs=references(slow)
    slow.cost=0.03
    let first=slow.refresh(slowRefs)!
    let firstCost=slow.now
    precondition(firstCost>0.8 && firstCost*2>1.6 && firstCost<1.6)
    precondition(check(first,reader:slow,focused:false) == .pending("reception_focus_required"))
    slow.newLease()
    let resumed=slow.refresh(slowRefs)!
    precondition(check(resumed,reader:slow) == .ready("customer-v58"))
    precondition(slow.now>1.6 && !slow.calls.contains(where:{$0.hasPrefix("99:")}))
    slow.newLease();slow.text[4]?["AXValue"]="another-customer"
    precondition(check(slow.refresh(slowRefs),reader:slow) == .differentCustomer)

    // Actual row switches keep the established selected-row/identity proof;
    // an already-selected target is never physically clicked a second time.
    precondition(!jdTransferOpenShouldClick(locatorCurrent:true,targetSelected:true,active:nil,expected:"customer-v58"))
    precondition(jdTransferOpenShouldClick(locatorCurrent:true,targetSelected:false,active:"other",expected:"customer-v58"))
    var selection=JDTransferOpenProof(requiredChangeFrom:"other")
    precondition(selection.observe(selected:false,header:"customer-v58",expected:"customer-v58") == .pending)
    precondition(selection.observe(selected:true,header:"customer-v58",expected:"customer-v58") == .pending)
    precondition(selection.observe(selected:true,header:"customer-v58",expected:"customer-v58") == .confirmed("customer-v58"))
    precondition(selection.complete(finalHeader:"customer-v58",expected:"customer-v58",focused:true,composerEmpty:true))
    print("v58 transfer-open reply-compatible injected checks passed")
  }
}
