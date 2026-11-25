// Appended to AccessibilityBridge.swift by native_identity_test.dart to test its real private helpers.
private final class JDNativeTestBool {
  private let lock=NSLock()
  private var value:Bool
  init(_ value:Bool) {self.value=value}
  func set(_ newValue:Bool) {lock.lock();value=newValue;lock.unlock()}
  func get()->Bool {lock.lock();defer {lock.unlock()};return value}
}
extension QianniuAXCollector {
  static func auditIdentityAcceptance() throws {
    verifySidebarSelection()
    let dummy=AXUIElementCreateSystemWide()
    func node(_ path:String,_ role:String,_ text:String?,_ frame:CGRect,actions:[String]=[])->AXNode {
      AXNode(element:dummy,path:path,role:role,subrole:nil,identifier:nil,title:text,
        description:nil,value:nil,help:nil,frame:frame,actions:actions,children:[])
    }
    let text=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
    let regex=try NSRegularExpression(pattern:#"^(\S+) role=(\S+) frame=(-|[-\d.]+,[-\d.]+ [-\d.]+x[-\d.]+)"#)
    var nodes=[AXNode]()
    for line in text.components(separatedBy:"\n") {
      guard let m=regex.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)) else {continue}
      func part(_ i:Int)->String {String(line[Range(m.range(at:i),in:line)!])}
      func label(_ key:String)->String? {
        guard let tail=line.components(separatedBy:key+"=\"").dropFirst().first else {return nil}
        return tail.components(separatedBy:"\"").first
      }
      let fields=part(3).replacingOccurrences(of:",",with:" ").replacingOccurrences(of:"x",with:" ").split(separator:" ").compactMap {Double($0)}
      let f=fields.count==4 ? CGRect(x:fields[0],y:fields[1],width:fields[2],height:fields[3]):nil
      nodes.append(AXNode(element:dummy,path:part(1),role:part(2),subrole:nil,identifier:label("id"),title:label("title"),description:label("desc"),value:label("value"),help:label("help"),frame:f,actions:[],children:[]))
    }
    let collector=QianniuAXCollector(), expected="jd_fixture41"
    let content=String(repeating:"a",count:64)
    let frameOne=jdCaptureEvidenceID(customer:expected,contentHash:content,historyCutoff:nil,automationSessionId:"run-one")
    precondition(frameOne.count==64)
    precondition(frameOne==jdCaptureEvidenceID(customer:expected,contentHash:content,historyCutoff:nil,automationSessionId:"run-one"),"Identical pixels in one run keep bounded native dedup")
    precondition(frameOne != jdCaptureEvidenceID(customer:expected,contentHash:content,historyCutoff:nil,automationSessionId:"run-two"),"A new run must capture a new immutable frame, not retime yesterday's manifest")
    precondition(frameOne != jdCaptureEvidenceID(customer:"other",contentHash:content,historyCutoff:nil,automationSessionId:"run-one"))
    precondition(frameOne != jdCaptureEvidenceID(customer:expected,contentHash:content,historyCutoff:"100",automationSessionId:"run-one"))
    let legacy=SHA256.hash(data:Data((expected+"|"+content+"|current").utf8)).map{String(format:"%02x",$0)}.joined()
    precondition(jdCaptureEvidenceID(customer:expected,contentHash:content,historyCutoff:nil,automationSessionId:nil)==legacy,"Optional nil preserves legacy transport compatibility")
    precondition(!exactCustomerIdentityMatches("jd_é", "jd_e\u{301}"),"AX identity must not fold distinct raw Unicode sequences")
    precondition(collector.activeCustomerIdentity(nodes:nodes)==expected,"sanitized recorded JD AX tree must still resolve")
    precondition(collector.activeCustomerMatches(expected,nodes:nodes))
    let withGenericTitle = nodes.map { n in n.value==expected ? AXNode(element:n.element,path:n.path,role:n.role,subrole:n.subrole,identifier:n.identifier,title:"客户ID",description:n.description,value:n.value,help:n.help,frame:n.frame,actions:n.actions,children:n.children):n }
    precondition(collector.activeCustomerIdentity(nodes:withGenericTitle)==expected,"AXValue wins over an unrelated accessibility title")

    for other in ["jd_fixture4l","JD_fixture41","ｊｄ_fixture41","jd_fixture4I"] {
      precondition(!collector.activeCustomerMatches(other,nodes:nodes))
    }
    func replace(_ source:[AXNode],id:String,with replacement:String)->[AXNode] {
      source.map { n in n.text==id ? AXNode(element:n.element,path:n.path,role:n.role,subrole:n.subrole,identifier:n.identifier,title:replacement,description:replacement,value:replacement,help:n.help,frame:n.frame,actions:n.actions,children:n.children):n }
    }
    let headerPath="app/0/18/0/16/13"
    let extra=node(headerPath+"/status",kAXStaticTextRole as String,"咨询中",CGRect(x:380,y:132,width:25,height:18))
    precondition(collector.activeCustomerIdentity(nodes:nodes+[extra])==expected)
    let unrelated=node(headerPath+"/another",kAXStaticTextRole as String,"jd_other",CGRect(x:408,y:112,width:100,height:18))
    precondition(collector.activeCustomerIdentity(nodes:nodes+[unrelated])==nil,"two possible full identities must not be chosen by position or expectation")
    let truncated=replace(nodes,id:expected,with:"jd_41a…")
    let row=node("app/0/sidebar/row",kAXGroupRole as String,"jd_41aeec_OTHER",CGRect(x:64,y:200,width:280,height:60),actions:[kAXPressAction as String])
    precondition(collector.activeCustomerIdentity(nodes:truncated+[row])==nil)
    precondition(!collector.activeCustomerMatches(expected,nodes:truncated+[row]))
    let different=replace(nodes,id:expected,with:"jd_41aeec_OTHER")
    let prefix=node(headerPath+"/prefix",kAXStaticTextRole as String,"jd_41ae…",CGRect(x:408,y:112,width:140,height:18))
    precondition(collector.activeCustomerIdentity(nodes:different+[prefix])=="jd_41aeec_OTHER")
    precondition(!collector.activeCustomerMatches(expected,nodes:different+[prefix]))
    let noName=nodes.filter { $0.text != expected }
    precondition(collector.activeCustomerIdentity(nodes:noName+[row])==nil)
    var gate=JDRowConfirmationGate();gate.requiredChangeFrom=expected
    precondition(gate.observe(selected:true,header:expected,expected:nil)==nil)
    precondition(gate.observe(selected:true,header:expected,expected:nil)==nil)
    precondition(gate.observe(selected:true,header:"jd_other",expected:nil)==nil)
    precondition(gate.observe(selected:true,header:"jd_other",expected:nil)=="jd_other")
    precondition(jdTranscriptContentBottom(composerTop:582,scrollBottom:nil,toolbarTops:[551,555])==551,"AX font/emoji controls must not enter the transcript")
    precondition(jdTranscriptContentBottom(composerTop:582,scrollBottom:510,toolbarTops:[551])==510)
    func accountPixels(changed:Bool=false,suffix:Bool=false,green:Bool=false,red:Bool=false)->CGImage {
      let width=600,height=700
      var bytes=[UInt8](repeating:255,count:width*height*4)
      for y in 256..<265 { for x in 110..<230 {
        let i=(y*width+x)*4;bytes[i]=0;bytes[i+1]=0;bytes[i+2]=0
      }}
      if changed {let i=(258*width+140)*4;bytes[i]=255;bytes[i+1]=255;bytes[i+2]=255}
      if suffix {for y in 256..<265 {for x in 290..<318 {let i=(y*width+x)*4;bytes[i]=0;bytes[i+1]=0;bytes[i+2]=0}}}
      if green || red {for y in 242..<250 {for x in 103..<111 {let i=(y*width+x)*4;bytes[i]=red ? 220:0;bytes[i+1]=red ? 30:190;bytes[i+2]=red ? 30:150}}}
      let provider=CGDataProvider(data:Data(bytes) as CFData)!
      return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    let accountLine=TransferTextLine(text:"格志打印机小华",confidence:1,frame:CGRect(x:100,y:250,width:150,height:20))
    let dialogBounds=CGRect(x:0,y:0,width:600,height:700)
    let originalPanel=TransferDialogSnapshot(windowID:99,bounds:dialogBounds,image:accountPixels(),lines:[accountLine])
    let unchangedPanel=TransferDialogSnapshot(windowID:99,bounds:dialogBounds,image:accountPixels(),lines:[])
    let changedPanel=TransferDialogSnapshot(windowID:99,bounds:dialogBounds,image:accountPixels(changed:true),lines:[])
    precondition(transferNamesUnchanged(originalPanel,unchangedPanel))
    precondition(!transferNamesUnchanged(originalPanel,changedPanel),"Even one changed name-glyph pixel invalidates OCR reuse")
    let reopenedBounds=CGRect(x:300,y:200,width:600,height:700)
    let reopenedPanel=TransferDialogSnapshot(windowID:100,bounds:reopenedBounds,image:accountPixels(green:true),lines:[])
    precondition(!transferNamesUnchanged(originalPanel,reopenedPanel),"An unscoped old modal must never supply names")
    let scopedNames=JDTransferNameCache(customer:expected,pid:123,epoch:7,seenAt:100,snapshot:originalPanel)
    let reusedNames=scopedNames.reusing(reopenedPanel,customer:expected,pid:123,epoch:7,now:101)!
    precondition(reusedNames.windowID==100 && reusedNames.bounds==reopenedBounds)
    precondition(transferAccountCandidates(in:reusedNames).first!.isActive,"A resumed inspection must read green pixels from the new image")
    precondition(reusedNames.globalPoint(for:CGPoint(x:175,y:260))==CGPoint(x:475,y:460),"New window geometry, never old click coordinates")
    let redPanel=TransferDialogSnapshot(windowID:101,bounds:reopenedBounds,image:accountPixels(red:true),lines:[])
    let redNames=scopedNames.reusing(redPanel,customer:expected,pid:123,epoch:7,now:102)!
    precondition(!transferAccountCandidates(in:redNames).first!.isActive,"A cached name must never carry yesterday's online status")
    let appendedName=TransferDialogSnapshot(windowID:102,bounds:reopenedBounds,image:accountPixels(suffix:true),lines:[])
    precondition(scopedNames.reusing(appendedName,customer:expected,pid:123,epoch:7,now:103)==nil,"An added suffix outside the old OCR box invalidates the full name band")
    precondition(scopedNames.reusing(reopenedPanel,customer:"other",pid:123,epoch:7,now:101)==nil)
    precondition(scopedNames.reusing(reopenedPanel,customer:expected,pid:124,epoch:7,now:101)==nil)
    precondition(scopedNames.reusing(reopenedPanel,customer:expected,pid:123,epoch:8,now:101)==nil)
    precondition(scopedNames.reusing(reopenedPanel,customer:expected,pid:123,epoch:7,now:161)==nil)
    precondition(scopedNames.reusing(reopenedPanel,customer:expected,pid:123,epoch:7,now:99)==nil)
    let resized=TransferDialogSnapshot(windowID:103,bounds:CGRect(x:0,y:0,width:610,height:700),image:accountPixels(),lines:[])
    precondition(scopedNames.reusing(resized,customer:expected,pid:123,epoch:7,now:101)==nil)
    print("PASS: exact fresh transfer-name pixels, scoped resumed modal, appended-name rejection and fresh status/geometry")
    // The same helper registers real transfer work before queue.async. A
    // ready reply pulse therefore cancels both running and not-yet-run work.
    collector.setAutomationEpoch(77,running:true)
    let queuedInspection=collector.beginTransferWork(77)
    precondition(collector.requestTransferInspectionYield(automationEpoch:77))
    precondition(queuedInspection.isInterrupted,"A queued inspection cannot miss the reply-priority pulse")
    var queuedCancellation=0
    precondition(queuedInspection.registerCancellation {queuedCancellation+=1}==nil)
    precondition(queuedCancellation==1,"Vision registered after a pulse is cancelled before perform")
    collector.endTransferWork(queuedInspection)
    let resumedInspection=collector.beginTransferWork(77)
    precondition(!resumedInspection.isInterrupted,"Reply priority is a pulse, not a permanent transfer block")
    var oldCancellation=0,newCancellation=0
    let oldCancelId=resumedInspection.registerCancellation {oldCancellation+=1}!
    let newCancelId=resumedInspection.registerCancellation {newCancellation+=1}!
    resumedInspection.clearCancellation(oldCancelId)
    precondition(!collector.requestTransferInspectionYield(automationEpoch:76))
    precondition(!resumedInspection.isInterrupted,"Old-run priority cannot cancel current work")
    precondition(collector.requestTransferInspectionYield(automationEpoch:77))
    precondition(oldCancellation==0 && newCancellation==1,"Only the active native Vision request is cancelled")
    resumedInspection.clearCancellation(newCancelId)
    collector.endTransferWork(resumedInspection)
    let stoppingInspection=collector.beginTransferWork(77)
    var stoppedCancellation=0
    _=stoppingInspection.registerCancellation {stoppedCancellation+=1}
    collector.setAutomationEpoch(78,running:true)
    precondition(stoppingInspection.isInterrupted && stoppedCancellation==1,"Stop/new run cancels old Vision immediately")
    let currentInspection=collector.beginTransferWork(78)
    collector.endTransferWork(stoppingInspection)
    precondition(collector.requestTransferInspectionYield(automationEpoch:78) && currentInspection.isInterrupted,
      "Finishing an old inspection cannot remove the new run's control")
    collector.endTransferWork(currentInspection)
    collector.setAutomationEpoch(78,running:false)
    precondition(jdNewTransferModalID(before:[1,2],after:[1,2,3])==3)
    precondition(jdNewTransferModalID(before:[1,2],after:[1,2,3,4])==nil,"Ambiguous new windows cannot become cleanup targets")
    precondition(jdNewTransferModalID(before:[1,2],after:[1,2])==nil)
    precondition(jdTransferModalOwnsForeground(ownedID:3,frontID:3,ownerPID:123,frontPID:123))
    precondition(!jdTransferModalOwnsForeground(ownedID:3,frontID:4,ownerPID:123,frontPID:123),"Never Escape a chat or another JD window")
    precondition(!jdTransferModalOwnsForeground(ownedID:3,frontID:3,ownerPID:123,frontPID:124))
    precondition(!jdTransferModalOwnsForeground(ownedID:nil,frontID:3,ownerPID:123,frontPID:123))
    var cleanupModal:CGWindowID?=3
    precondition(jdConsumeTransferModalOwnership(&cleanupModal,expected:3)==3 && cleanupModal==nil)
    precondition(jdConsumeTransferModalOwnership(&cleanupModal,expected:3)==nil,
      "Native error cleanup followed by Dart cancellation cannot dispatch two closes")
    cleanupModal=4
    precondition(jdConsumeTransferModalOwnership(&cleanupModal,expected:3)==nil && cleanupModal==4,
      "An old cleanup cannot consume a newer modal's ownership")
    let delayedOCR=JDTransferWorkControl()
    let performStarted=DispatchSemaphore(value:0),releasePerform=DispatchSemaphore(value:0),waiterFinished=DispatchSemaphore(value:0)
    let recognitionCompleted=JDNativeTestBool(true)
    DispatchQueue.global(qos:.userInitiated).async {
      let completed=jdRunInterruptibleTransferRecognition(control:delayedOCR,deadline:nil) {
        performStarted.signal()
        // Deliberately ignore cancellation, as an old Vision request can.
        releasePerform.wait()
      }
      recognitionCompleted.set(completed)
      waiterFinished.signal()
    }
    precondition(performStarted.wait(timeout:.now()+1) == .success)
    delayedOCR.interrupt()
    let yieldedBeforeOCRFinished=waiterFinished.wait(timeout:.now()+0.5) == .success
    precondition(yieldedBeforeOCRFinished,"A late OCR must not keep the AX/UI queue after reply priority")
    precondition(!recognitionCompleted.get())
    let waitingForSlot=JDTransferWorkControl()
    let secondWaiting=DispatchSemaphore(value:0),secondReturned=DispatchSemaphore(value:0)
    let duplicatePerformed=JDNativeTestBool(false)
    DispatchQueue.global(qos:.userInitiated).async {
      secondWaiting.signal()
      _=jdRunInterruptibleTransferRecognition(control:waitingForSlot,deadline:nil) {duplicatePerformed.set(true)}
      secondReturned.signal()
    }
    precondition(secondWaiting.wait(timeout:.now()+1) == .success)
    waitingForSlot.interrupt()
    let cancelledWhileSlotOccupied=secondReturned.wait(timeout:.now()+0.5) == .success
    releasePerform.signal()
    precondition(cancelledWhileSlotOccupied && !duplicatePerformed.get(),"A hung old OCR cannot accumulate another queued image/job")
    print("PASS: queued/running transfer cancellation, reply-priority pulse, safe resume and epoch isolation without live UI")
    // AX-supplied staff names must remain literal, including l/I/1 and spaces.
    let axLine=TransferTextLine(text:"Team agent_I1",confidence:1,frame:CGRect(x:100,y:250,width:150,height:20),source:"accessibility")
    precondition(transferAccountName(from:"Teamagent_I1",line:axLine,imageWidth:600)=="Team agent_I1")
    let axPanel=TransferDialogSnapshot(windowID:99,bounds:dialogBounds,image:accountPixels(),lines:[axLine])
    precondition(JDTransferNameCache(customer:expected,pid:123,epoch:7,seenAt:100,snapshot:axPanel)
      .reusing(reopenedPanel,customer:expected,pid:123,epoch:7,now:101)==nil,"AX elements and identities must be read fresh from each owned modal")
    let staffGroup=node("transfer/list",kAXGroupRole as String,nil,CGRect(x:10,y:100,width:500,height:300))
    let staffRow=node("transfer/list/row",kAXRowRole as String,nil,CGRect(x:30,y:150,width:450,height:30))
    let staffName=node("transfer/list/row/name",kAXStaticTextRole as String,"agent_I1",CGRect(x:100,y:155,width:100,height:20))
    let staffOnline=node("transfer/list/row/status",kAXStaticTextRole as String,"在线",CGRect(x:80,y:155,width:15,height:20))
    let staffAction=node("transfer/list/row/action",kAXButtonRole as String,"转接",CGRect(x:300,y:155,width:40,height:20),actions:[kAXPressAction as String])
    let staffAX=jdAXTransferAccounts([staffGroup,staffRow,staffName,staffOnline,staffAction],below:120)
    precondition(staffAX.count==1 && staffAX[0].name=="agent_I1" && staffAX[0].online==true && staffAX[0].action != nil)
    let noStatus=jdAXTransferAccounts([staffGroup,staffRow,staffName],below:120)
    precondition(noStatus.count==1 && noStatus[0].online==nil,"A readable AX name is not proof of online status")
    precondition(!TransferAccountCandidate(name:"agent_I1",frame:.zero,greenPixelEvidence:0,redPixelEvidence:0,identitySource:"accessibility",axOnline:true).isActive,"Even an AX-online name still requires the verified green marker")
    precondition(!TransferAccountCandidate(name:"agent_I1",frame:.zero,greenPixelEvidence:8,redPixelEvidence:0,identitySource:"accessibility",axOnline:false).isActive)
    precondition(TransferAccountCandidate(name:"agent_I1",frame:.zero,greenPixelEvidence:8,redPixelEvidence:0).isActive)
    precondition(!TransferAccountCandidate(name:"agent_I1",frame:.zero,greenPixelEvidence:8,redPixelEvidence:5).isActive)
    print("PASS: AX-first literal staff identities and green-only transfer gating")
    var transferOcrCalls=0
    let axIdentity=resolveTransferDialogLabels(ax:(labels:[axLine],diagnostics:["identitySource":"accessibility"])) {
      transferOcrCalls+=1;return []
    }
    precondition(transferOcrCalls==0 && axIdentity.labels[0].text=="Team agent_I1","An available AX staff identity must never invoke OCR")
    let fallback=resolveTransferDialogLabels(ax:(labels:[],diagnostics:["ocrFallbackReason":"ax_staff_rows_not_exposed"])) {
      transferOcrCalls+=1;return [TransferTextLine(text:"agent_ocr",confidence:1,frame:axLine.frame)]
    }
    precondition(transferOcrCalls==1 && fallback.diagnostics["identitySource"] as? String=="ocr")
    let actionFallback=resolveTransferDialogLabels(ax:(labels:[axLine],diagnostics:["identitySource":"accessibility"]),requireAction:true) {
      transferOcrCalls+=1;return [TransferTextLine(text:"WRONG OCR NAME",confidence:1,frame:axLine.frame),TransferTextLine(text:"转接",confidence:1,frame:axLine.frame)]
    }
    precondition(actionFallback.labels.contains(where:{$0.text=="Team agent_I1"}) && !actionFallback.labels.contains(where:{$0.text=="WRONG OCR NAME"}),"Action-only OCR must never overwrite a readable AX staff name")
    print("PASS: staff-dialog-only OCR fallback, with AX identities preserved")
    func badgeImage(y:Int,red:Bool=false)->CGImage {
      let width=600,height=700
      var bytes=[UInt8](repeating:255,count:width*height*4)
      for row in y..<(y+8) { for x in 106..<114 {
        let i=(row*width+x)*4;bytes[i]=red ? 220:0;bytes[i+1]=red ? 30:190;bytes[i+2]=red ? 30:150
      }}
      return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
        provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    let badgeLine=TransferTextLine(text:"离线测试客服",confidence:1,frame:CGRect(x:130,y:200,width:180,height:20))
    precondition(transferBadgePixelEvidence(line:badgeLine,image:badgeImage(y:210)).green>=3)
    precondition(transferBadgePixelEvidence(line:badgeLine,image:badgeImage(y:210,red:true)).red>=3)
    precondition(transferBadgePixelEvidence(line:badgeLine,image:badgeImage(y:470)).green==0,"An offline staff row must not borrow a green badge from the vertically mirrored row")
    let badgeColors:[[UInt8]]=[
      [0,190,150,255],[220,30,30,255],[140,175,200,255],[140,174,199,255],
      [140,175,201,255],[170,135,150,255],[169,134,149,255],[255,255,255,255],
      [0,105,130,255],[0,104,129,255],[140,255,241,255]]
    let paletteWidth=badgeColors.count*8
    var palettePixels=[UInt8](repeating:255,count:paletteWidth*8*4)
    for (column,color) in badgeColors.enumerated() {for y in 0..<8 {for x in (column*8)..<(column*8+8) {
      for channel in 0..<4 {palettePixels[(y*paletteWidth+x)*4+channel]=color[channel]}
    }}}
    let palette=CGImage(width:paletteWidth,height:8,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:paletteWidth*4,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
      provider:CGDataProvider(data:Data(palettePixels) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let decoded=JDTransferPixelBuffer(palette)!
    let legacyBitmap=NSBitmapImageRep(cgImage:palette)
    for column in badgeColors.indices {
      var oldGreen=0,oldRed=0
      for y in 0..<8 {for x in (column*8)..<(column*8+8) {
        let color=legacyBitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
        let red=Int(color.redComponent*255),green=Int(color.greenComponent*255),blue=Int(color.blueComponent*255)
        if green>=105 && red<=140 && blue<=240 && green>=red+35 && green+25>=blue {oldGreen+=1}
        if red>=170 && green<=145 && blue<=150 && red>=green+35 {oldRed+=1}
      }}
      let fresh=decoded.badgeEvidence(in:CGRect(x:column*8,y:0,width:8,height:8))
      precondition(fresh.green==oldGreen && fresh.red==oldRed,"RGBA fast path preserves the exact online/offline thresholds")
    }
    print("PASS: row-local staff badge evidence rejects mirrored-row green pixels")
    // Missing AXValue cannot provide either of the two positive empty reads.
    let receptionFrame=CGRect(x:20,y:30,width:1200,height:800)
    precondition(jdReceptionWindowMatches(expected:receptionFrame,frontmost:receptionFrame))
    precondition(!jdReceptionWindowMatches(expected:receptionFrame,frontmost:CGRect(x:300,y:200,width:500,height:400)))
    precondition(!jdReceptionWindowMatches(expected:receptionFrame,frontmost:nil))
    precondition(!jdReceptionWindowMatches(expected:.zero,frontmost:.zero))
    var shortClock:TimeInterval=10
    let shortActivation=jdPrepareSendForeground(expectedPID:123,running:{true},foreground:{nil},activate:{},
      deadline:10.1,now:{shortClock},pause:{shortClock+=0.05})
    precondition(shortActivation=="send_preclick_budget_exceeded" && shortClock<10.2)
    precondition(jdSendComposerReading(nil) == .unreadable)
    precondition(jdSendComposerReading(nil) != .empty)
    precondition(jdSendComposerReading("  ") == .empty)
    precondition(jdSendComposerReading("reply") == .text("reply"))
    func ownership(_ active:String?=expected,_ enabled:Bool?=true,_ value:String?="",
        _ focused:Bool=true,_ source:String?="格志测试客服",_ blocked:Bool=false)->String? {
      jdCurrentReceptionOwnershipBlock(expected:expected,active:active,enabled:enabled,
        composerValue:value,focused:focused,sourceAccount:source,blocked:blocked)
    }
    precondition(ownership()==nil)
    precondition(ownership(nil)=="ownership_customer_unconfirmed")
    precondition(ownership("jd_fixture4l")=="ownership_customer_unconfirmed")
    precondition(ownership(expected,nil)=="ownership_enabled_unconfirmed")
    precondition(ownership(expected,false)=="customer_not_receiving")
    precondition(ownership(expected,true,nil)=="ownership_composer_unreadable")
    precondition(ownership(expected,true,"draft")=="composer_not_empty")
    precondition(ownership(expected,true,"",false)=="ownership_reception_not_focused")
    precondition(ownership(expected,true,"",true,nil)=="ownership_source_account_unconfirmed")
    precondition(ownership(expected,true,"",true,"当前客服账号")=="ownership_source_account_unconfirmed")
    precondition(ownership(expected,true,"",true,"source")=="ownership_source_account_unconfirmed")
    precondition(ownership(expected,true,"",true,"格志测试客服",true)=="customer_not_receiving")
    print("PASS: current ownership requires positive exact AX identity, enabled, empty value, reception focus and actual source account")
    precondition(jdSendPreclickDeadline(queuedAt:10,queuedWallMs:1000,requestedMs:900)==10)
    precondition(jdSendPreclickDeadline(queuedAt:10,queuedWallMs:1000,requestedMs:3000)==12)
    precondition(jdSendPreclickDeadline(queuedAt:10,queuedWallMs:1000,requestedMs:30000)==16)
    let unknownCollector=QianniuAXCollector()
    unknownCollector.unknownInsertedReply=(pid:123,customer:expected,text:"still pending after click")
    let unknownRecovery=unknownCollector.recoverOwnUnsentReply(nodes:nodes,pid:123,
      readValue:{_ in "still pending after click"},clearValue:{_ in preconditionFailure("clicked unknown text must never be cleared by pre-click recovery")})
    precondition(unknownRecovery == "not_owned" && unknownCollector.unknownInsertedReply?.text == "still pending after click")
    let journalRoot=FileManager.default.temporaryDirectory.appendingPathComponent("jd_v29_transfer_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:journalRoot,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:journalRoot)}
    let journal=journalRoot.appendingPathComponent("attempt-1.json")
    precondition(collector.writeTransferReceipt(journal.path,attemptId:"attempt-1",customer:expected,target:"agent_I1",state:"prepared",clicked:false))
    precondition(collector.writeTransferReceipt(journal.path,attemptId:"attempt-1",customer:expected,target:"agent_I1",state:"click_intent",clicked:true))
    let clickIntentJSON=try JSONSerialization.jsonObject(with:Data(contentsOf:journal)) as! [String:Any]
    precondition(clickIntentJSON["state"] as? String == "click_intent" && clickIntentJSON["transferClicked"] as? Bool == true)
    precondition(clickIntentJSON["customer"] as? String == expected && clickIntentJSON["targetAccount"] as? String == "agent_I1")
    precondition(!collector.writeTransferReceipt(journal.path,attemptId:"different-attempt",customer:expected,target:"agent_I1",state:"prepared",clicked:false))
    let sendJournal=journalRoot.appendingPathComponent("send-1.json")
    let clickTime=Int64(Date().timeIntervalSince1970*1000)-100
    precondition(collector.writeDeliveryReceipt(sendJournal.path,attemptId:"send-1",customer:expected,state:"clicked",sendClickedAtMs:clickTime))
    for phase in ["submitted","unknown","rejected","late_rejection_uncertain"] {
      precondition(collector.writeDeliveryReceipt(sendJournal.path,attemptId:"send-1",customer:expected,state:phase))
      let saved=try JSONSerialization.jsonObject(with:Data(contentsOf:sendJournal)) as! [String:Any]
      precondition((saved["sendClickedAtMs"] as? NSNumber)?.int64Value==clickTime,
        "Every receipt replacement, including late watchers, must preserve the real native click boundary")
    }
    print("PASS: unreadable composer confirmation, shared pre-click budget, clicked-input preservation and durable transfer journal")
    // A legal tall modal must not give an offline row its neighbor's green
    // marker or the neighbor's inline action.
    var tallPixels=[UInt8](repeating:255,count:800*2200*4)
    for y in 510..<518 {for x in 140..<148 {let i=(y*800+x)*4;tallPixels[i]=0;tallPixels[i+1]=190;tallPixels[i+2]=150}}
    let tallImage=CGImage(width:800,height:2200,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:800*4,
      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
      provider:CGDataProvider(data:Data(tallPixels) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let offlineName=TransferTextLine(text:"格志打印机甲",confidence:1,frame:CGRect(x:250,y:400,width:200,height:40))
    let onlineName=TransferTextLine(text:"格志打印机乙",confidence:1,frame:CGRect(x:250,y:480,width:200,height:40))
    let tallPanel=TransferDialogSnapshot(windowID:199,bounds:CGRect(x:0,y:0,width:400,height:1100),image:tallImage,
      lines:[TransferTextLine(text:"默认咨询组",confidence:1,frame:CGRect(x:100,y:300,width:200,height:30)),offlineName,onlineName])
    let literalPanel=TransferDialogSnapshot(windowID:199,bounds:tallPanel.bounds,image:tallImage,lines:[
      TransferTextLine(text:"AgentI",confidence:1,frame:offlineName.frame,source:"accessibility"),
      TransferTextLine(text:"agenti",confidence:1,frame:onlineName.frame,source:"accessibility")])
    precondition(transferAccountCandidates(in:literalPanel).count==2,"Distinct literal AX staff IDs must not be merged by case folding")
    let tallCandidates=transferAccountCandidates(in:tallPanel)
    precondition(tallCandidates.count==2)
    let offline=tallCandidates.first(where:{$0.name=="格志打印机甲"})!
    let online=tallCandidates.first(where:{$0.name=="格志打印机乙"})!
    precondition(offline.greenPixelEvidence==0 && !offline.isActive && online.isActive)
    let neighborAction=CGRect(x:500,y:480,width:60,height:40)
    precondition(!jdTransferActionBelongsToRow(action:neighborAction,candidate:offline))
    precondition(jdTransferActionBelongsToRow(action:neighborAction,candidate:online))
    print("PASS: tall transfer modal rejects adjacent-row green markers and adjacent-row transfer actions")
    let children=(1...80).map { AXUIElementCreateApplication(pid_t(1000000+$0)) }
    var tick:TimeInterval=0;var roleQueries=0
    let finished=collector.walk(dummy,path:"budget-root",depth:0,maxDepth:5,maxNodes:100,timeBudget:0.01,
      now:{tick},nodeReader:{element,path,allowed in
        guard allowed() else {return nil}
        let childList=CFEqual(element,dummy) ? children:[]
        return AXNode(element:element,path:path,role:"AXGroup",subrole:nil,identifier:nil,title:nil,description:nil,value:nil,help:nil,frame:nil,actions:[],children:childList)
      },roleReader:{_ in roleQueries+=1;tick+=0.002;return "AXGroup"},visit:{_,_ in})
    precondition(!finished && roleQueries<=6,"deadline stops further child role reads rather than finishing all 80")
    var fieldReads=0;tick=0
    let nodeFinished=collector.walk(dummy,path:"attribute-budget",depth:0,maxDepth:5,maxNodes:100,timeBudget:0.01,
      now:{tick},nodeReader:{_,_,allowed in
        for _ in 0..<13 {guard allowed() else {return nil};fieldReads+=1;tick+=0.002}
        return nil
      },roleReader:{_ in "AXGroup"},visit:{_,_ in})
    precondition(!nodeFinished && fieldReads<=6,"the same deadline also gates each attribute within a node")
    var boundedRoleReads=0
    let nodeCap=collector.walk(dummy,path:"node-cap",depth:0,maxDepth:5,maxNodes:1,
      nodeReader:{element,path,_ in AXNode(element:element,path:path,role:"AXGroup",subrole:nil,identifier:nil,title:nil,description:nil,value:nil,help:nil,frame:nil,actions:[],children:children)},
      roleReader:{_ in boundedRoleReads+=1;return "AXGroup"},visit:{_,_ in})
    precondition(!nodeCap && boundedRoleReads==0,"a reached node cap must not issue extra role lookups")
    print("PASS: AX child-loop, per-attribute and node-count budgets with injected readers; no live AX calls.")
    let window=CGRect(x:0,y:30,width:1440,height:813)
    let frames=[CGRect(x:65,y:256,width:278,height:60),CGRect(x:65,y:316,width:278,height:60),CGRect(x:65,y:376,width:278,height:60)]
    precondition(jdRowClickPoint(frames[1],in:window)==CGPoint(x:204,y:346))
    var unequal=frames;unequal[2].size.height=72
    precondition(jdRowClickPoint(unequal[0],in:window)==CGPoint(x:204,y:286),"an unrelated row height cannot veto the valid target")
    var gaps=frames;gaps[1].origin.y+=16
    precondition(jdRowClickPoint(gaps[1],in:window)==CGPoint(x:204,y:362),"click the actual frame, not an inferred row pitch")
    let reordered=[CGRect(x:65,y:256,width:278,height:60),CGRect(x:65,y:316,width:278,height:60),CGRect(x:65,y:376,width:278,height:60),CGRect(x:65,y:436,width:278,height:60)]
    let shapeA=(0..<2560).map { UInt8($0>=200 && $0<260 ? 1:0) }
    let shapeB=(0..<2560).map { UInt8($0>=1000 && $0<1060 ? 1:0) }
    let moved=jdUniqueRowShapeIndex(shapeA,[shapeB,shapeB,shapeA,shapeB])
    precondition(moved==2)
    precondition(jdRowClickPoint(reordered[moved!],in:window)==CGPoint(x:204,y:406),"a new top row must use the target's refreshed rectangle")
    precondition(jdUniqueRowShapeIndex(shapeA,[shapeA,shapeA])==nil,"ambiguous row continuity must still reject")
    precondition(jdRowClickPoint(nil,in:window)==nil)
    precondition(jdRowClickPoint(frames[0],in:nil)==nil)
    precondition(jdRowClickPoint(CGRect(x:65,y:800,width:278,height:60),in:window)==nil)
    precondition(jdRowClickPoint(CGRect(x:65,y:256,width:0,height:60),in:window)==nil)
    precondition(jdRowClickPoint(CGRect(x:65,y:256,width:278,height:0),in:window)==nil)
    precondition(jdRowClickPoint(CGRect(x:CGFloat.nan,y:256,width:278,height:60),in:window)==nil)
    precondition(jdRowClickPoint(CGRect(x:65,y:CGFloat.infinity,width:278,height:60),in:window)==nil)
    print("PASS: direct target AX frame; nonuniform heights and gaps; reordered target; invalid/off-window geometry; ambiguous locator rejection.")
    let shape=Array(repeating:UInt8(1),count:2560)
    let a=collector.rememberRow(row,window:row,pid:0,fingerprint:"same",shape:shape,canonical:"jd_A")
    let b=collector.rememberRow(row,window:row,pid:0,fingerprint:"same",shape:shape,canonical:"jd_B")
    precondition(a.key != b.key && a.token != b.token,"one visual observation key cannot be reassigned to a distinct AX identity")
    print("PASS: sanitized recorded JD AX fixture; exact l/I/1, case and width distinctions; status label ignored; ambiguous headers rejected; truncated prefix denied; sidebar cannot override header; stable selected/header change; canonical row-key conflict isolated.")
    // This is the production helper used by BOTH already-active success
    // branches: the correct header while Automation owns focus still needs
    // reception activation before the opener may report success.
    var openNow:TimeInterval=0,openFocused=false,openActivations=0,openRunning=true,openIdentity=true
    let openReady=jdPrepareOpenReception(allowActivation:true,deadline:2.5,
      running:{openRunning},identityMatches:{openIdentity},focused:{openFocused},
      activationIsSafe:{true},activate:{openActivations += 1},now:{openNow},
      pause:{openNow += 0.04;if openNow>=0.24 {openFocused=true}})
    precondition(openReady==nil && openActivations==1 && openFocused && openNow>=0.24)
    openNow=0;openFocused=false;openActivations=0
    let passiveOpen=jdPrepareOpenReception(allowActivation:false,deadline:2.5,
      running:{true},identityMatches:{true},focused:{false},activationIsSafe:{false},
      activate:{openActivations += 1},now:{openNow},pause:{openNow += 0.04})
    precondition(passiveOpen==nil && openActivations==0 && openNow==0)
    let modalOpen=jdPrepareOpenReception(allowActivation:true,deadline:2.5,
      running:{true},identityMatches:{true},focused:{false},activationIsSafe:{false},
      activate:{openActivations += 1},now:{openNow},pause:{openNow += 0.04})
    precondition(modalOpen=="open_reception_blocked" && openActivations==0)
    let stalledOpen=jdPrepareOpenReception(allowActivation:true,deadline:0.3,
      running:{true},identityMatches:{true},focused:{false},activationIsSafe:{true},
      activate:{openActivations += 1},now:{openNow},pause:{openNow += 0.04})
    precondition(stalledOpen=="conversation_open_timeout" && openNow<0.35 && openActivations==1)
    openNow=0;openRunning=true;openActivations=0
    let stoppedOpen=jdPrepareOpenReception(allowActivation:true,deadline:2.5,
      running:{openRunning},identityMatches:{true},focused:{false},activationIsSafe:{true},
      activate:{openActivations += 1},now:{openNow},pause:{openNow += 0.04;openRunning=false})
    precondition(stoppedOpen=="automation_stopped" && openActivations==1)
    openNow=0;openFocused=false;openIdentity=true
    let changedOpen=jdPrepareOpenReception(allowActivation:true,deadline:2.5,
      running:{true},identityMatches:{openIdentity},focused:{openFocused},activationIsSafe:{true},
      activate:{},now:{openNow},pause:{openNow += 0.04;openFocused=true;openIdentity=false})
    precondition(changedOpen=="conversation_changed")
    print("PASS: already-active reception contract activates safe focus, bounds waiting, preserves passive/modal/Stop/identity guards")
    // Exercise actual production foreground waiting without touching macOS UI.
    var clock:TimeInterval=0, foreground:pid_t?=999, activationCount=0, isRunning=true
    let focused = jdPrepareSendForeground(expectedPID:123, running:{isRunning}, foreground:{foreground},
      activate:{activationCount += 1}, now:{clock}, pause:{clock += 0.05; if clock >= 0.30 {foreground=123}})
    precondition(focused == nil && clock >= 0.30 && activationCount == 1,
      "activation delayed beyond the old 150ms must settle and permit sending")
    clock=0;foreground=999;activationCount=0
    let denied = jdPrepareSendForeground(expectedPID:123,running:{isRunning},foreground:{foreground},
      activate:{activationCount += 1},now:{clock},pause:{clock += 0.05})
    precondition(denied == "send_not_frontmost" && clock < 0.7 && activationCount == 1)
    clock=0;foreground=999
    let stopped = jdPrepareSendForeground(expectedPID:123,running:{isRunning},foreground:{foreground},
      activate:{},now:{clock},pause:{clock += 0.05;isRunning=false})
    precondition(stopped == "automation_stopped" && clock < 0.1)
    precondition(!jdMayClearInsertedReply(expected:expected,active:expected,inserted:"reply",current:"reply",clicked:true))
    precondition(!jdMayClearInsertedReply(expected:expected,active:"wrong",inserted:"reply",current:"reply",clicked:false))
    precondition(!jdMayClearInsertedReply(expected:expected,active:expected,inserted:"reply",current:"manual edit",clicked:false))
    var composerValue="reply", clearCount=0
    collector.unsentInsertedReply=(pid:123,customer:expected,text:"reply")
    let recovered=collector.recoverOwnUnsentReply(nodes:nodes,pid:123,
      readValue:{_ in composerValue}, clearValue:{_ in clearCount += 1;composerValue="";return true})
    precondition(recovered == "own_text_cleared" && clearCount == 1 && composerValue.isEmpty)
    composerValue="manual draft"
    collector.unsentInsertedReply=(pid:123,customer:expected,text:"reply")
    let manual=collector.recoverOwnUnsentReply(nodes:nodes,pid:123,
      readValue:{_ in composerValue},clearValue:{_ in preconditionFailure("never clear human edits")})
    precondition(manual == "text_changed_preserved" && composerValue == "manual draft")
    var snapshotClock=0.0
    var refreshReads=0
    let restored: (String,Bool)? = jdRefreshSendSnapshot(initial:nil,expected:expected,
      canRefresh:{true},identity:{$0.0},ready:{$0.1},
      read:{refreshReads += 1;return (expected,true)},now:{snapshotClock},pause:{snapshotClock += 0.05})
    precondition(restored?.0 == expected && refreshReads == 1)
    let wrong: (String,Bool)? = jdRefreshSendSnapshot(initial:("different_customer",false),expected:expected,
      canRefresh:{true},identity:{$0.0},ready:{$0.1},
      read:{preconditionFailure("wrong exact identity must never be refreshed into a match")},now:{snapshotClock},pause:{snapshotClock += 0.05})
    precondition(wrong?.0 == "different_customer")
    refreshReads=0;snapshotClock=0
    let missing: (String,Bool)? = jdRefreshSendSnapshot(initial:nil,expected:expected,
      canRefresh:{true},identity:{$0.0},ready:{$0.1},read:{refreshReads += 1;return nil},
      now:{snapshotClock},pause:{snapshotClock += 0.05})
    precondition(missing == nil && refreshReads <= 8 && snapshotClock <= 0.4)
    let snapshotStopped: (String,Bool)? = jdRefreshSendSnapshot(initial:nil,expected:expected,
      canRefresh:{false},identity:{$0.0},ready:{$0.1},read:{preconditionFailure("post-click/stopped refresh forbidden")},
      now:{snapshotClock},pause:{snapshotClock += 0.05})
    precondition(snapshotStopped == nil)

    let fixtureRoot=URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().deletingLastPathComponent()
    func recordedMedia(_ path:String)throws->CGImage {
      let url=fixtureRoot.appendingPathComponent(path)
      return NSBitmapImageRep(data:try Data(contentsOf:url))!.cgImage!
    }
    func contentPixels(_ changed:Int)->CGImage {
      var pixels=[UInt8](repeating:255,count:100*120*4)
      func dot(_ x:Int,_ y:Int,_ level:UInt8) {
        let i=(y*100+x)*4
        pixels[i]=level;pixels[i+1]=level;pixels[i+2]=level
      }
      dot(40,50,20)
      if changed==1 {dot(5,50,0)}       // sidebar clock/indicator
      if changed==2 {dot(95,50,0)}      // right tool panel
      if changed==3 {dot(40,110,0)}     // composer/caret
      if changed==4 {dot(45,50,0)}      // new transcript pixel
      let provider=CGDataProvider(data:Data(pixels) as CFData)!
      return CGImage(width:100,height:120,bitsPerComponent:8,bitsPerPixel:32,
        bytesPerRow:400,space:CGColorSpaceCreateDeviceRGB(),
        bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
        provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    }
    let transcriptRegion=["left":0.2,"right":0.8,"top":0.2,"bottom":0.8]
    let contentHash=jdChatContentSHA256(image:contentPixels(0),region:transcriptRegion)!
    precondition(contentHash.count==64)
    for outside in [1,2,3] {
      precondition(jdChatContentSHA256(image:contentPixels(outside),region:transcriptRegion)==contentHash,
        "Changes outside the verified transcript cannot create a content discovery")
    }
    precondition(jdChatContentSHA256(image:contentPixels(4),region:transcriptRegion) != contentHash,
      "Incoming transcript changes must be observable without a red marker")
    precondition(jdChatContentSHA256(image:contentPixels(0),region:["left":0.8,"right":0.2,"top":0.2,"bottom":0.8])==nil)
    let recordedProvenance=try JSONSerialization.jsonObject(with:Data(contentsOf:
      fixtureRoot.appendingPathComponent("v34_discovery/provenance.json"))) as! [String:Any]
    var recordedHashes=[String]()
    for frame in recordedProvenance["frames"] as! [[String:Any]] {
      let image=try recordedMedia("v34_discovery/\(frame["name"] as! String).png")
      let hash=jdChatContentSHA256(image:image,region:frame["chatRegion"] as! [String:Double])!
      recordedHashes.append(hash)
      precondition(jdCaptureEvidenceID(customer:frame["customer"] as! String,contentHash:hash,
        historyCutoff:nil,automationSessionId:frame["automationSessionId"] as? String)==frame["sourceEvidenceId"] as! String,
        "Exposing the chat hash must preserve existing recorded evidence IDs")
      let r=frame["expectedVideoRegion"] as! [String:Double]
      let card=image.cropping(to:CGRect(x:r["x"]!*Double(image.width),y:r["y"]!*Double(image.height),
        width:r["width"]!*Double(image.width),height:r["height"]!*Double(image.height)).integral)!
      precondition(looksLikeVideoThumbnail(card),"Both actual unloaded and loaded customer video cards retain explicit play evidence")
    }
    precondition(Set(recordedHashes).count==2,"Loading the video cover changes the actual transcript pixels")
    print("PASS: transcript-only content hashes ignore sidebar/tools/composer; real recorded video transition preserves capture identity and playback evidence")
    let grayVideos=try ["v33_media/gray-video-1.png","v33_media/gray-video-2.png"].map(recordedMedia)
    for image in grayVideos {
      precondition(mediaForegroundFraction(image)<0.025,"Recorded unloaded card stays visually sparse")
      precondition(looksLikeVideoThumbnail(image),"Gray JD video requires both ring and triangle, not high global contrast")
    }
    let upperPlay=try recordedMedia("v30_media/upper-play-video.png")
    let secondPlay=try recordedMedia("v30/second_video_crop.png")
    let printerPhoto=try recordedMedia("v30_media/printer-photo-no-play.png")
    precondition(looksLikeVideoThumbnail(upperPlay))
    precondition(looksLikeVideoThumbnail(secondPlay))
    precondition(!looksLikeVideoThumbnail(printerPhoto))
    for paper in ["v35_media/paper-image-1.png","v35_media/paper-image-2.png"] {
      let paperImage=try recordedMedia(paper)
      precondition(!looksLikeVideoThumbnail(paperImage),
        "Recorded static paper diagram and printed Chinese text must not create video duties")
    }
    // Two own sender headers delimit their bodies even if Vision splits a
    // customer name and its time into separate boxes. A similarly named
    // customer is never accepted as the active customer's timestamp.
    let anchorChat=["left":0.23,"right":0.75,"top":0.20,"bottom":0.80]
    func anchor(_ text:String,_ x:Double,_ y:Double)->[String:Any] {
      ["text":text,"x":x,"y":y,"height":0.012,"confidence":0.95]
    }
    let cardBands=jdIncomingMediaBands(observations:[
      anchor("buyer7",0.26,0.30),anchor("17:08:01",0.37,0.30),
      anchor("17:08:08 格志打印机小耿",0.61,0.49),
      anchor("buyer71 17:08:14",0.26,0.55),
      anchor("buyer7 17:08:20",0.26,0.62)
    ],customer:"buyer7",chatRegion:anchorChat)
    precondition(cardBands.count==2 && abs(cardBands[0].lowerBound-0.312)<0.0001 &&
      cardBands[0].upperBound==0.49 && cardBands[1].upperBound==0.80,
      "Timestamp bands must exclude the next sender and preserve the last full card")
    let topClipped=try recordedMedia("v35_media/top-clipped-attendance-video.png")
    precondition(looksLikeVideoThumbnail(topClipped),"The real clipped attendance video keeps its explicit ring/triangle proof")
    let orphanFrame=try recordedMedia("v35_media/unbound-video-frame.png")
    let orphanRegion=["left":0.24027777777777778,"right":0.7479166666666667,
      "top":0.20418204182041821,"bottom":0.7921279212792128]
    let proposals=jdUnboundMediaRegions(image:orphanFrame,chatRegion:orphanRegion)
    precondition(proposals.count==1 && proposals[0]["proof"] as? String == "explicit_play_overlay",
      "A real video survives a missing sender header and later customer text")
    let p=proposals[0]
    let proposed=orphanFrame.cropping(to:CGRect(x:p["x"] as! Double*Double(orphanFrame.width),
      y:p["y"] as! Double*Double(orphanFrame.height),width:p["width"] as! Double*Double(orphanFrame.width),
      height:p["height"] as! Double*Double(orphanFrame.height)).integral)!
    precondition(proposed.width>=310 && proposed.height>=310,
      "The proposal covers the visible card, not merely the LCD rectangle")
    let orphanCover=try recordedMedia("v35_media/unbound-video-cover.jpg")
    let visible=mediaWithoutChatBorder(proposed)
    let fragment=jdMatchingVideoCoverFragment(visible:visible,cover:orphanCover)
    precondition(fragment != nil && mediaStructuralSimilarity(visible,fragment!)>0.96,
      "The real partial card can recover its same-stem original by strict contiguous cover pixels")
    precondition(jdMatchingVideoCoverFragment(visible:visible,cover:printerPhoto)==nil,
      "A different video/photo cannot bind merely because it is cached nearby")
    let clippedCacheRoot=FileManager.default.temporaryDirectory.appendingPathComponent("jd_clipped_video_\(UUID().uuidString)")
    let clippedImages=clippedCacheRoot.appendingPathComponent("chat_owned/images")
    let clippedVideos=clippedCacheRoot.appendingPathComponent("chat_owned/videos")
    for folder in [clippedImages,clippedVideos] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
    defer {try? FileManager.default.removeItem(at:clippedCacheRoot)}
    let ownedCover=clippedImages.appendingPathComponent("owned.jpg"),ownedVideo=clippedVideos.appendingPathComponent("owned.mp4")
    try FileManager.default.copyItem(at:fixtureRoot.appendingPathComponent("v35_media/unbound-video-cover.jpg"),to:ownedCover)
    try FileManager.default.copyItem(at:fixtureRoot.appendingPathComponent("v35_media/unbound-video-original.mp4"),to:ownedVideo)
    let clippedCaptureAt=Date(timeIntervalSince1970:1793865717.893)
    for file in [ownedCover,ownedVideo] {try FileManager.default.setAttributes([.modificationDate:clippedCaptureAt.addingTimeInterval(-73)],ofItemAtPath:file.path)}
    let recoveredCover=matchingRecentJDCachedImage(visibleImage:proposed,expectedAt:clippedCaptureAt,
      now:clippedCaptureAt,videoThumbnailsOnly:true,includeUnlinkedVideoCovers:true,cacheRoot:clippedCacheRoot)
    precondition(recoveredCover?.url.resolvingSymlinksInPath()==ownedCover.resolvingSymlinksInPath() &&
      verifiedCompanionVideo(thumbnail:recoveredCover!.url)?.resolvingSymlinksInPath()==ownedVideo.resolvingSymlinksInPath(),
      "The actual f750 crop recovers the exact same-chat video original, not an unrelated cached image")
    let tiedCover=clippedImages.appendingPathComponent("tied.jpg"),tiedVideo=clippedVideos.appendingPathComponent("tied.mp4")
    try FileManager.default.copyItem(at:ownedCover,to:tiedCover)
    try Data("different-video-original".utf8).write(to:tiedVideo)
    for file in [tiedCover,tiedVideo] {try FileManager.default.setAttributes([.modificationDate:clippedCaptureAt.addingTimeInterval(-70)],ofItemAtPath:file.path)}
    precondition(matchingRecentJDCachedImage(visibleImage:proposed,expectedAt:clippedCaptureAt,
      now:clippedCaptureAt,videoThumbnailsOnly:true,includeUnlinkedVideoCovers:true,cacheRoot:clippedCacheRoot)==nil,
      "Visually tied covers with different same-stem originals must remain unresolved")
    precondition(jdUnboundMediaRegions(image:orphanFrame,chatRegion:["left":0.8,"right":0.2,"top":0.2,"bottom":0.8]).isEmpty)
    let collapsedTransfer=try recordedMedia("v35_media/collapsed-transfer.png")
    let modalBounds=CGRect(x:100,y:100,width:Double(collapsedTransfer.width)/2,height:Double(collapsedTransfer.height)/2)
    let groupLine=TransferTextLine(text:"默认咨询组 (0/35)",confidence:1,frame:CGRect(x:108,y:298,width:230,height:26))
    let collapsed=TransferDialogSnapshot(windowID:7,bounds:modalBounds,image:collapsedTransfer,lines:[groupLine])
    let disclosure=jdTransferGroupDisclosure(collapsed)
    precondition(disclosure.state == .collapsed && disclosure.point != nil,
      "Actual collapsed group requires a fresh right-arrow glyph before a group click")
    let closeGlyph=jdTransferCloseGlyph(image:collapsedTransfer)
    precondition(closeGlyph != nil && abs(closeGlyph!.x-899)<5 && abs(closeGlyph!.y-57)<5,
      "Cleanup finds the modal's actual X, without sending Escape to the reception")
    func disclosureMask(_ expanded:Bool)->([UInt8],Int,Int) {
      let w=expanded ? 15:9,h=expanded ? 9:15
      var result=[UInt8](repeating:0,count:w*h)
      if expanded {for x in 0..<w {let y=min(x,w-1-x);result[y*w+x]=1}}
      else {for y in 0..<h {let x=min(y,h-1-y);result[y*w+x]=1}}
      return (result,w,h)
    }
    let right=disclosureMask(false),down=disclosureMask(true)
    precondition(jdTransferChevronState(right.0,width:right.1,height:right.2) == .collapsed)
    precondition(jdTransferChevronState(down.0,width:down.1,height:down.2) == .expanded)
    precondition(jdTransferChevronState([UInt8](repeating:0,count:100),width:10,height:10) == .unknown)
    print("PASS: recorded paper false-video negatives, clipped-card discovery and strict cover fragment; one-shot modal cleanup and fresh group disclosure")
    func grayControl(_ kind:Int)->CGImage {
      let c=CGContext(data:nil,width:320,height:400,bitsPerComponent:8,bytesPerRow:1280,
        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.setFillColor(CGColor(gray:233.0/255,alpha:1));c.fill(CGRect(x:0,y:0,width:320,height:400))
      c.setStrokeColor(CGColor(gray:1,alpha:1));c.setFillColor(CGColor(gray:1,alpha:1));c.setLineWidth(4)
      let ring=CGRect(x:130,y:170,width:60,height:60)
      if kind==1 || kind==3 {c.strokeEllipse(in:ring)}
      if kind==2 {c.fillEllipse(in:ring)}
      if kind==3 || kind==4 {
        c.beginPath();c.move(to:CGPoint(x:150,y:185));c.addLine(to:CGPoint(x:150,y:215));c.addLine(to:CGPoint(x:175,y:200));c.closePath();c.fillPath()
      }
      return c.makeImage()!
    }
    for kind in [0,1,2,4] {
      precondition(!looksLikeVideoThumbnail(grayControl(kind)),"Gray blank/ring/disk/triangle alone is not a received video")
    }
    precondition(looksLikeVideoThumbnail(grayControl(3)))
    let evidenceRoot=FileManager.default.temporaryDirectory.appendingPathComponent("jd_gray_video_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:evidenceRoot,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:evidenceRoot)}
    let inspector=QianniuOCRInspector()
    for (index,image) in grayVideos.enumerated() {
      let imageData=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!
      let digest=SHA256.hash(data:imageData).map{String(format:"%02x",$0)}.joined()
      let id=SHA256.hash(data:Data("gray-video-\(index)".utf8)).map{String(format:"%02x",$0)}.joined()
      let manifest=evidenceRoot.appendingPathComponent(id+".json")
      try imageData.write(to:evidenceRoot.appendingPathComponent(id+".png"))
      try JSONSerialization.data(withJSONObject:["customer":expected,"evidenceId":id,"pngSHA256":digest,
        "capturedAtMs":0,"windowId":0,"windowBounds":["x":0,"y":0,"width":image.width,"height":image.height],
        "chatRegion":["left":0.0,"right":1.0,"top":0.0,"bottom":1.0]]).write(to:manifest)
      var classified:[String:Any]?
      inspector.cropEvidence(manifestPath:manifest.path,expectedCustomer:expected,destinationDirectory:nil,
        region:CGRect(x:0,y:0,width:1,height:1)) {classified=$0 as? [String:Any]}
      let waitUntil=Date().addingTimeInterval(5)
      while classified==nil && Date()<waitUntil {_ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.01))}
      precondition(classified?["kind"] as? String == "video","Actual frozen crop path must retain sparse video as pending original")
      precondition(classified?["playbackOverlayDetected"] as? Bool == true)
      precondition(classified?["video"] == nil,"A play card without its original cannot pretend frames were acquired")
      precondition(classified?["captureSource"] as? String == "frozen-window-crop")
    }
    print("PASS: recorded gray play cards survive frozen crop; blank/ring/disk/photo controls rejected; original remains explicitly unavailable")

    let mediaRoot=FileManager.default.temporaryDirectory.appendingPathComponent("jd_video_proof_\(UUID().uuidString)")
    defer {try? FileManager.default.removeItem(at:mediaRoot)}
    let images=mediaRoot.appendingPathComponent("chat_a/images")
    let videos=mediaRoot.appendingPathComponent("chat_a/videos")
    let otherChat=mediaRoot.appendingPathComponent("chat_b/videos")
    for folder in [images,videos,otherChat] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
    func ffmpeg(_ args:[String]) throws {
      let process=Process();process.executableURL=URL(fileURLWithPath:"/opt/homebrew/bin/ffmpeg")
      process.arguments=["-hide_banner","-loglevel","error","-y"]+args
      try process.run();process.waitUntilExit();precondition(process.terminationStatus==0)
    }
    let actual=videos.appendingPathComponent("different_video_name.mp4")
    try ffmpeg(["-f","lavfi","-i","testsrc2=size=160x120:rate=5","-t","1","-c:v","libx264","-pix_fmt","yuv420p",actual.path])
    let other=videos.appendingPathComponent("unrelated.mp4")
    try ffmpeg(["-f","lavfi","-i","testsrc=size=160x120:rate=5","-t","1","-c:v","libx264","-pix_fmt","yuv420p",other.path])
    let generator=AVAssetImageGenerator(asset:AVURLAsset(url:actual));generator.appliesPreferredTrackTransform=true
    let poster=try generator.copyCGImage(at:.zero,actualTime:nil)
    let cover=images.appendingPathComponent("cover_name.png")
    try NSBitmapImageRep(cgImage:poster).representation(using:.png,properties:[:])!.write(to:cover)
    precondition(verifiedCompanionVideo(thumbnail:cover)==nil)
    let visualSource=verifiedVisualVideoCompanion(thumbnail:cover)
    precondition(visualSource?.resolvingSymlinksInPath().standardizedFileURL==actual.resolvingSymlinksInPath().standardizedFileURL,"Unlinked cover must match unique original pixels")
    try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1)],ofItemAtPath:actual.path)
    let olderVisualSource=verifiedVisualVideoCompanion(thumbnail:cover)
    precondition(olderVisualSource?.resolvingSymlinksInPath().standardizedFileURL==actual.resolvingSymlinksInPath().standardizedFileURL,"File age cannot invalidate a unique same-chat original with verified matching video pixels")
    let movedVideo=otherChat.appendingPathComponent(actual.lastPathComponent)
    try FileManager.default.moveItem(at:actual,to:movedVideo)
    precondition(verifiedVisualVideoCompanion(thumbnail:cover)==nil,"Never search another chat for an original")
    try FileManager.default.moveItem(at:movedVideo,to:actual)
    let ambiguous=videos.appendingPathComponent("ambiguous.mp4")
    try ffmpeg(["-i",actual.path,"-c","copy","-metadata","title=different-source",ambiguous.path])
    precondition(verifiedVisualVideoCompanion(thumbnail:cover)==nil,"Same poster with different original bytes is ambiguous")

    let guardFile=mediaRoot.appendingPathComponent("media_guard.json")
    try JSONSerialization.data(withJSONObject:["customer":expected,"revision":2]).write(to:guardFile,options:.atomic)
    precondition(jdSendMediaContextCurrent(path:guardFile.path,customer:expected,revision:2))
    precondition(!jdSendMediaContextCurrent(path:guardFile.path,customer:expected,revision:1))
    precondition(!jdSendMediaContextCurrent(path:guardFile.path,customer:"different_customer",revision:2))
    precondition(!jdSendMediaContextCurrent(path:nil,customer:expected,revision:2))
    precondition(jdSendMediaContextCurrent(path:nil,customer:expected,revision:nil))
    print("PASS: unnamed video/cover pixel binding; unrelated video exclusion; cross-chat exclusion; ambiguous original rejection.")
    print("PASS: delayed foreground activation; bounded denial; Stop before insertion; exact own draft recovery; manual edits and post-click uncertainty preserved.")
    print("Offline synthetic/recorded nodes only; no AX reads, app launch, clicking, typing or customer sends.")
  }
}
@main struct IdentityAcceptance {static func main() throws {try QianniuAXCollector.auditIdentityAcceptance()}}
